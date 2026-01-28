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
        let currentFiles = Set(current.compactMap(\.photoIdentifier))
        let previousFiles = Set(previous.compactMap(\.photoIdentifier))
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
        let photoIdentifier: String?

        init(_ spot: Spot, photoStore: SpotPhotoStore) {
            recordName = spot.id.recordName
            title = spot.title
            note = spot.note
            lat = spot.latitude
            lon = spot.longitude
            createdAt = spot.createdAt
            if let photoData = spot.photoData {
                let filename = photoStore.uniqueFilename(for: recordName)
                photoStore.savePhotoData(photoData, filename: filename)
                photoIdentifier = filename
            } else if let photoAssetURL = spot.photoAssetURL {
                photoIdentifier = photoAssetURL.lastPathComponent
            } else {
                photoIdentifier = nil
            }
        }

        func toSpot(photoStore: SpotPhotoStore) -> Spot {
            let assetURL = photoIdentifier.map { photoStore.url(for: $0) }
            let spot = Spot(
                id: CKRecord.ID(recordName: recordName),
                title: title,
                note: note,
                location: CLLocation(latitude: lat, longitude: lon),
                createdAt: createdAt,
                photoAssetURL: assetURL
            )
            return spot
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recordName = try container.decode(String.self, forKey: .recordName)
            title = try container.decode(String.self, forKey: .title)
            note = try container.decode(String.self, forKey: .note)
            lat = try container.decode(Double.self, forKey: .lat)
            lon = try container.decode(Double.self, forKey: .lon)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            if let identifier = try container.decodeIfPresent(String.self, forKey: .photoIdentifier) {
                photoIdentifier = identifier
            } else {
                photoIdentifier = try container.decodeIfPresent(String.self, forKey: .photoFilename)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(recordName, forKey: .recordName)
            try container.encode(title, forKey: .title)
            try container.encode(note, forKey: .note)
            try container.encode(lat, forKey: .lat)
            try container.encode(lon, forKey: .lon)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(photoIdentifier, forKey: .photoIdentifier)
        }

        private enum CodingKeys: String, CodingKey {
            case recordName
            case title
            case note
            case lat
            case lon
            case createdAt
            case photoIdentifier
            case photoFilename
        }
    }
}
