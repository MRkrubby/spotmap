import Foundation
import CoreLocation
import CloudKit
import Combine

/// Repository that manages spots, caching and backend selection.
///
/// Design goals:
/// - Never crash when CloudKit is not configured (no entitlements / no iCloud account).
/// - Avoid endless loading: cancel stale refresh tasks + add a timeout.
/// - Avoid spamming the backend: throttle/skip refresh when the center barely moved.
@MainActor
final class SpotRepository: ObservableObject {

    enum Backend: String, CaseIterable {
        case local
        case cloudKit

        var title: String {
            switch self {
            case .local: return "Lokaal (op dit toestel)"
            case .cloudKit: return "iCloud (CloudKit) – delen"
            }
        }
    }

    @Published private(set) var spots: [Spot] = []
    @Published private(set) var isLoading = false
    @Published var lastErrorMessage: String?
    @Published private(set) var backend: Backend

    private var service: any SpotService
    private let cache: SpotCache

    private var refreshTask: Task<Void, Never>?
    private var lastRefreshCenter: CLLocation?
    private var lastRefreshAt: Date?

    // Tunables
    private let minMoveToRefreshMeters: CLLocationDistance = 700
    private let minTimeBetweenRefresh: TimeInterval = 1.0
    private let refreshTimeoutSeconds: Double = 10

    init(backend: Backend = SpotRepository.loadBackendPreference()) {
        self.backend = backend
        self.cache = SpotCache(key: "SpotCache.v1.\(backend.rawValue)")
        self.service = SpotRepository.makeService(for: backend)
        Task { [weak self] in
            guard let self else { return }
            let cached = await cache.load()
            await MainActor.run {
                self.spots = cached
            }
        }
    }

    // MARK: - Backend switching

    func setBackend(_ backend: Backend, currentCenter: CLLocation) {
        guard backend != self.backend else { return }

        // Swap service first (so refresh uses the new backend).
        self.service = SpotRepository.makeService(for: backend)

        self.backend = backend
        SpotRepository.saveBackendPreference(backend)

        // Switch cache namespace so we don't mix local vs cloud snapshots.
        self.cache.setKey("SpotCache.v1.\(backend.rawValue)")
        Task { [weak self] in
            guard let self else { return }
            let cached = await cache.load()
            await MainActor.run {
                self.spots = cached
            }
        }

        refreshNearby(center: currentCenter, force: true)
    }

    // MARK: - Refresh

    /// Refresh spots near a map center.
    ///
    /// - Parameter force: ignore movement/time heuristics.
    func refreshNearby(
        center: CLLocation,
        radiusMeters: Double = 25_000,
        limit: Int = 200,
        force: Bool = false
    ) {
        // Skip frequent refreshes if the center barely moved and we refreshed recently.
        if !force, shouldSkipRefresh(center: center) {
            return
        }

        lastRefreshCenter = center
        lastRefreshAt = Date()

        // Cancel any in-flight refresh.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self._refreshNearby(center: center, radiusMeters: radiusMeters, limit: limit)
        }
    }

    private func shouldSkipRefresh(center: CLLocation) -> Bool {
        if let last = lastRefreshCenter {
            let moved = center.distance(from: last)
            if moved < minMoveToRefreshMeters {
                if let at = lastRefreshAt, Date().timeIntervalSince(at) < minTimeBetweenRefresh {
                    return true
                }
            }
        }
        return false
    }

    private func _refreshNearby(center: CLLocation, radiusMeters: Double, limit: Int) async {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await withTimeout(seconds: refreshTimeoutSeconds) {
                try await self.service.fetchNearby(center: center, radiusMeters: radiusMeters, limit: limit)
            }

            // If cancelled mid-flight, don't update UI.
            try Task.checkCancellation()

            spots = fetched
            cache.save(fetched)
        } catch is CancellationError {
            // Expected when the user pans/zooms quickly.
        } catch let error as TimeoutError {
            lastErrorMessage = error.localizedDescription
        } catch {
            lastErrorMessage = humanReadable(error: error)
        }
    }

    // MARK: - CRUD

    func addSpot(title: String, note: String, coordinate: CLLocationCoordinate2D, photoData: Data?) async {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        let previousSpots = spots

        let spot = Spot(
            id: CKRecord.ID(recordName: LocalSpotService.makeRecordNameIfNeeded(forBackend: backend)),
            title: title,
            note: note,
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )

        do {
            let saved = try await withTimeout(seconds: refreshTimeoutSeconds) {
                try await self.service.save(spot: spot)
            }
            spots.insert(saved, at: 0)
            cache.save(spots)
        } catch is CancellationError {
            // Ignore cancellations from fast user interactions.
        } catch let error as TimeoutError {
            lastErrorMessage = error.localizedDescription
        } catch {
            spots = previousSpots
            cache.save(previousSpots)
            lastErrorMessage = humanReadable(error: error)
        }
    }

    func spot(withRecordName recordName: String) -> Spot? {
        spots.first { $0.id.recordName == recordName }
    }

    /// For deep links: fetch a spot if it's not currently cached.
    func fetchSpotIfNeeded(recordName: String) async -> Spot? {
        if let spot = spot(withRecordName: recordName) {
            return spot
        }

        do {
            let spot = try await withTimeout(seconds: refreshTimeoutSeconds) {
                try await self.service.fetchSpot(by: CKRecord.ID(recordName: recordName))
            }
            spots.insert(spot, at: 0)
            cache.save(spots)
            return spot
        } catch is CancellationError {
            // Ignore cancellations from fast user interactions.
            return nil
        } catch let error as TimeoutError {
            lastErrorMessage = error.localizedDescription
            return nil
        } catch {
            lastErrorMessage = humanReadable(error: error)
            return nil
        }
    }

    func deleteSpot(_ spot: Spot) async {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        let previousSpots = spots

        do {
            try await withTimeout(seconds: refreshTimeoutSeconds) {
                try await self.service.deleteSpot(by: spot.id)
            }
            spots.removeAll { $0.id.recordName == spot.id.recordName }
            cache.save(spots)
        } catch is CancellationError {
            // Ignore cancellations from fast user interactions.
        } catch let error as TimeoutError {
            lastErrorMessage = error.localizedDescription
        } catch {
            spots = previousSpots
            cache.save(previousSpots)
            lastErrorMessage = humanReadable(error: error)
        }
    }

    // MARK: - Error mapping

    private func humanReadable(error: Error) -> String {
        AppErrorMapper.message(for: error)
    }
}

private extension SpotRepository {
    static func makeService(for backend: Backend) -> any SpotService {
        switch backend {
        case .local:
            return LocalSpotService()
        case .cloudKit:
            return CloudKitSpotService()
        }
    }
}

// MARK: - Cache

private final class SpotCache {
    private var key: String
    private let photoStore = SpotPhotoStore.shared
    private let queue = DispatchQueue(label: "spotmap.spot-cache", qos: .utility)
    private var fileURL: URL

    init(key: String) {
        self.key = key
        self.fileURL = Self.cacheURL(for: key)
    }

    func setKey(_ newKey: String) {
        self.key = newKey
        self.fileURL = Self.cacheURL(for: newKey)
    }

    func load() async -> [Spot] {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL, photoStore] in
                let cacheSpots = Self.loadCacheSpots(from: fileURL)
                let spots = cacheSpots.map { $0.toSpot(photoStore: photoStore) }
                continuation.resume(returning: spots)
            }
        }
    }

    func save(_ spots: [Spot]) {
        queue.async { [fileURL, photoStore] in
            let previous = Self.loadCacheSpots(from: fileURL)
            let cache = spots.map { CacheSpot($0, photoStore: photoStore) }
            guard let data = try? JSONEncoder().encode(cache) else { return }
            do {
                try Self.ensureDirectoryExists(for: fileURL)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                return
            }
            Self.removeOrphanedPhotos(previous: previous, current: cache, photoStore: photoStore)
        }
    }

    private static func loadCacheSpots(from fileURL: URL) -> [CacheSpot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CacheSpot].self, from: data)) ?? []
    }

    private static func removeOrphanedPhotos(
        previous: [CacheSpot],
        current: [CacheSpot],
        photoStore: SpotPhotoStore
    ) {
        let currentFiles = Set(current.compactMap(\.photoFilename))
        let previousFiles = Set(previous.compactMap(\.photoFilename))
        let orphaned = previousFiles.subtracting(currentFiles)
        orphaned.forEach { photoStore.deletePhoto(filename: $0) }
    }

    private static func cacheURL(for key: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotmap", isDirectory: true)
        let sanitizedKey = key.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(sanitizedKey).json")
    }

    private static func ensureDirectoryExists(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            self.recordName = spot.id.recordName
            self.title = spot.title
            self.note = spot.note
            self.lat = spot.latitude
            self.lon = spot.longitude
            self.createdAt = spot.createdAt
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

// MARK: - Backend preference

private extension SpotRepository {
    /// UserDefaults key must be usable from non-main contexts.
    nonisolated static let backendPreferenceKey = "SpotRepository.backend"

    nonisolated static func loadBackendPreference() -> Backend {
        if let raw = UserDefaults.standard.string(forKey: backendPreferenceKey),
           let b = Backend(rawValue: raw) {
            return b
        }
        return .local
    }

    nonisolated static func saveBackendPreference(_ backend: Backend) {
        UserDefaults.standard.set(backend.rawValue, forKey: backendPreferenceKey)
    }
}


// MARK: - CarPlay helper
@MainActor
extension SpotRepository {
    /// Best-effort center for refresh when running outside the main map UI.
    /// Uses a lightweight CLLocationManager one-shot reading if available.
    func locationForBestEffortRefresh() -> CLLocation? {
        let mgr = CLLocationManager()
        return mgr.location
    }
}
