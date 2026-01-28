import Foundation
import CloudKit
import CoreLocation

/// Local (offline) implementation of `SpotService`.
///
/// This keeps the app usable without CloudKit setup and also acts as a safe fallback
/// when CloudKit is unavailable.
final class LocalSpotService: SpotService {
    private let key = "LocalSpots.v1"
    private let photoStore = SpotPhotoStore.shared

    static func makeRecordNameIfNeeded(forBackend backend: SpotRepository.Backend) -> String {
        switch backend {
        case .local:
            return "local-\(UUID().uuidString)"
        case .cloudKit:
            return UUID().uuidString
        }
    }

    func save(spot: Spot) async throws -> Spot {
        var all = load()
        all.removeAll { $0.id.recordName == spot.id.recordName }
        all.insert(spot, at: 0)
        persist(all)
        return spot
    }

    func fetchSpot(by id: CKRecord.ID) async throws -> Spot {
        let spots = await MainActor.run { load() }
        if let s = spots.first(where: { $0.id.recordName == id.recordName }) {
            return s
        }
        throw CKError(.unknownItem)
    }

    func fetchNearby(center: CLLocation, radiusMeters: Double, limit: Int) async throws -> [Spot] {
        let all = await MainActor.run { load() }
        let filtered = all
            .map { ($0, $0.location.distance(from: center)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.createdAt > rhs.0.createdAt }
                return lhs.1 < rhs.1
            }
            .prefix(limit)
            .map { $0.0 }
        return Array(filtered)
    }

    func deleteSpot(by id: CKRecord.ID) async throws {
        await MainActor.run {
            var all = load()
            all.removeAll { $0.id.recordName == id.recordName }
            persist(all)
        }
    }

    // MARK: - Storage

    @MainActor private func load() -> [Spot] {
        loadCacheSpots().map { $0.toSpot(photoStore: photoStore) }
    }

    @MainActor private func persist(_ spots: [Spot]) {
        let previous = loadCacheSpots()
        let enc = spots.map { CacheSpot($0, photoStore: photoStore) }
        guard let data = try? JSONEncoder().encode(enc) else { return }
        UserDefaults.standard.set(data, forKey: key)
        removeOrphanedPhotos(previous: previous, current: enc)
    }

    @MainActor private func loadCacheSpots() -> [CacheSpot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CacheSpot].self, from: data)) ?? []
    }

    private func removeOrphanedPhotos(previous: [CacheSpot], current: [CacheSpot]) {
        let currentFiles = Set(current.compactMap(\.photoFilename))
        let previousFiles = Set(previous.compactMap(\.photoFilename))
        let orphaned = previousFiles.subtracting(currentFiles)
        orphaned.forEach { photoStore.deletePhoto(filename: $0) }
    }

    private struct CacheSpot: Codable {
        let recordName: String
        let title: String
        let note: String
        let lat: Double
        let lon: Double
        let createdAt: Date
        let photoFilename: String?

        init(_ spot: Spot, photoStore: SpotPhotoStore) {
            recordName = spot.id.recordName
            title = spot.title
            note = spot.note
            lat = spot.latitude
            lon = spot.longitude
            createdAt = spot.createdAt
            if let photoData = spot.photoData {
                let filename = photoStore.filename(for: recordName)
                photoStore.savePhotoData(photoData, filename: filename)
                photoFilename = filename
            } else {
                photoFilename = nil
            }
        }

        func toSpot(photoStore: SpotPhotoStore) -> Spot {
            var spot = Spot(
                id: CKRecord.ID(recordName: recordName),
                title: title,
                note: note,
                location: CLLocation(latitude: lat, longitude: lon),
                createdAt: createdAt
            )
            if let photoFilename {
                spot.photoData = photoStore.loadPhotoData(filename: photoFilename)
            }
            return spot
        }
    }
}
