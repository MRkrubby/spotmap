import Foundation
import CloudKit
import CoreLocation

/// Local (offline) implementation of `SpotService`.
///
/// This keeps the app usable without CloudKit setup and also acts as a safe fallback
/// when CloudKit is unavailable.
final class LocalSpotService: SpotService {
    private let key = "LocalSpots.v1"

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
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CacheSpot].self, from: data))?.map { $0.toSpot() } ?? []
    }

    @MainActor private func persist(_ spots: [Spot]) {
        let enc = spots.map(CacheSpot.init)
        guard let data = try? JSONEncoder().encode(enc) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private struct CacheSpot: Codable {
        let recordName: String
        let title: String
        let note: String
        let lat: Double
        let lon: Double
        let createdAt: Date
        let photoData: Data?

        init(_ spot: Spot) {
            recordName = spot.id.recordName
            title = spot.title
            note = spot.note
            lat = spot.latitude
            lon = spot.longitude
            createdAt = spot.createdAt
            photoData = spot.photoData
        }

        func toSpot() -> Spot {
            var spot = Spot(
                id: CKRecord.ID(recordName: recordName),
                title: title,
                note: note,
                location: CLLocation(latitude: lat, longitude: lon),
                createdAt: createdAt
            )
            spot.photoData = photoData
            return spot
        }
    }
}
