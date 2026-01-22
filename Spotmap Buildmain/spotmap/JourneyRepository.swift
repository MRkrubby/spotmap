import Foundation
import CoreLocation
import Combine

/// Stores and records journeys (trip logging).
///
/// This is intentionally **local-first** (UserDefaults) so it works out of the box.
/// Cloud sync can be layered on later, but this keeps the core UX fast and reliable.
final class JourneyRepository: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var journeys: [JourneyRecord] = []
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var currentSpeedMps: Double = 0
    @Published private(set) var currentDistanceMeters: Double = 0
    @Published private(set) var currentMaxSpeedMps: Double = 0
    @Published private(set) var currentAvgSpeedMps: Double = 0
    @Published var lastErrorMessage: String?

    private let store = JourneyStore()
    private let manager = CLLocationManager()

    private var points: [JourneyPoint] = []
    private var lastAcceptedLocation: CLLocation?
    private var lastAverageSampleAt: Date?

    // Tunables for accuracy/perf
    private let minDistanceBetweenPoints: CLLocationDistance = 7
    private let minTimeBetweenPoints: TimeInterval = 2
    private let maxAcceptableAccuracy: CLLocationAccuracy = 65

    override init() {
        super.init()
        journeys = store.load()

        // CLLocationManager delegate callbacks are delivered on the main run loop by default
        // when created on the main thread (which is the case in SwiftUI apps).
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Public API

    func requestPermissionsIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func start() {
        lastErrorMessage = nil
        requestPermissionsIfNeeded()

        isRecording = true
        startedAt = Date()
        points.removeAll(keepingCapacity: true)
        lastAcceptedLocation = nil
        currentSpeedMps = 0
        currentDistanceMeters = 0
        currentMaxSpeedMps = 0
        currentAvgSpeedMps = 0
        lastAverageSampleAt = Date()

        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        manager.stopUpdatingLocation()

        let end = Date()
        guard let start = startedAt, points.count >= 2 else {
            startedAt = nil
            points.removeAll()
            return
        }

        let avg = computeAverageSpeedMps(distanceMeters: currentDistanceMeters, start: start, end: end)
        let record = JourneyRecord.make(
            from: points,
            startedAt: start,
            endedAt: end,
            distanceMeters: currentDistanceMeters,
            maxSpeedMps: currentMaxSpeedMps,
            avgSpeedMps: avg
        )

        store.add(record)
        journeys = store.load()

        ExploreStore.shared.ingest(record)

        startedAt = nil
        points.removeAll()
        lastAcceptedLocation = nil
        currentSpeedMps = 0
        currentDistanceMeters = 0
        currentMaxSpeedMps = 0
        currentAvgSpeedMps = 0
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func delete(_ record: JourneyRecord) {
        store.delete(record)
        journeys = store.load()
    }

    func currentPolyline() -> [CLLocationCoordinate2D] {
        points.map { $0.coordinate }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            lastErrorMessage = "Locatie staat uit. Zet Locatie aan in Instellingen om journeys te loggen."
            if isRecording { stop() }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastErrorMessage = error.localizedDescription
        if isRecording { stop() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        guard let loc = locations.last else { return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= maxAcceptableAccuracy else { return }
        guard loc.timestamp.timeIntervalSinceNow > -10 else { return }

        currentSpeedMps = max(0, loc.speed)
        currentMaxSpeedMps = max(currentMaxSpeedMps, currentSpeedMps)

        if let last = lastAcceptedLocation {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            let dd = loc.distance(from: last)
            if dt < minTimeBetweenPoints && dd < minDistanceBetweenPoints {
                // too dense; skip
                updateAverageIfNeeded(now: loc.timestamp)
                return
            }
            if dd > 0.5 {
                currentDistanceMeters += dd
            }
        }

        points.append(JourneyPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, ts: loc.timestamp, speedMps: currentSpeedMps))
        lastAcceptedLocation = loc
        updateAverageIfNeeded(now: loc.timestamp)
    }

    // MARK: - Derived metrics

    private func updateAverageIfNeeded(now: Date) {
        guard let start = startedAt else { return }
        // update avg at most every 1s to keep UI smooth but not expensive
        if let last = lastAverageSampleAt, now.timeIntervalSince(last) < 1 { return }
        lastAverageSampleAt = now
        currentAvgSpeedMps = computeAverageSpeedMps(distanceMeters: currentDistanceMeters, start: start, end: now)
    }

    private func computeAverageSpeedMps(distanceMeters: Double, start: Date, end: Date) -> Double {
        let t = end.timeIntervalSince(start)
        guard t > 0 else { return 0 }
        return distanceMeters / t
    }
}

// MARK: - Storage

private struct JourneyStore {
    private let key = "Journeys.v1"

    func load() -> [JourneyRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([JourneyRecord].self, from: data)) ?? []
    }

    func add(_ record: JourneyRecord) {
        var all = load()
        all.insert(record, at: 0)
        persist(all)
    }

    func delete(_ record: JourneyRecord) {
        var all = load()
        all.removeAll { $0.id == record.id }
        persist(all)
    }

    private func persist(_ all: [JourneyRecord]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}


// MARK: - Explore / achievements store

@MainActor
final class ExploreStore: ObservableObject {
    static let shared = ExploreStore()

    @Published private(set) var visitedTiles: Set<String> = []
    @Published private(set) var visitedCities: Set<String> = []   // "country|locality"

    private let tilesKey = "ExploreTiles.v1"
    private let citiesKey = "ExploreCities.v1"
    private let zoom = 10

    private init() {
        visitedTiles = Self.loadSet(key: tilesKey)
        visitedCities = Self.loadSet(key: citiesKey)
    }

    func ingest(_ journey: JourneyRecord) {
        let points = journey.decodedPoints()
        guard points.count >= 2 else { return }

        // Tiles
        var tiles = visitedTiles
        for p in points {
            tiles.insert(Self.tileId(lat: p.lat, lon: p.lon, zoom: zoom))
        }
        visitedTiles = tiles
        Self.saveSet(tiles, key: tilesKey)

        // Cities (sample start + end only, async)
        Task {
            await self.ingestCities(start: points.first!.coordinate, end: points.last!.coordinate)
        }
    }

    private func ingestCities(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) async {
        let geocoder = CLGeocoder()

        let startKey: String? = await withCheckedContinuation { cont in
            geocoder.reverseGeocodeLocation(CLLocation(latitude: start.latitude, longitude: start.longitude)) { places, _ in
                cont.resume(returning: Self.cityKey(from: places?.first))
            }
        }

        let endKey: String? = await withCheckedContinuation { cont in
            geocoder.reverseGeocodeLocation(CLLocation(latitude: end.latitude, longitude: end.longitude)) { places, _ in
                cont.resume(returning: Self.cityKey(from: places?.first))
            }
        }

        await MainActor.run {
            var set = visitedCities
            if let startKey { set.insert(startKey) }
            if let endKey { set.insert(endKey) }
            visitedCities = set
            Self.saveSet(set, key: citiesKey)
        }
    }

    nonisolated private static func cityKey(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        let country = placemark.isoCountryCode ?? placemark.country ?? "??"
        let locality = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? "Onbekend"
        return "\(country)|\(locality)"
    }

    func totalDistanceKm(from journeys: [JourneyRecord]) -> Double {
        journeys.reduce(0.0) { $0 + ($1.distanceMeters / 1000.0) }
    }

    func level(for totalKm: Double) -> Int {
        // Level up every 100 km
        max(1, Int(totalKm / 100.0) + 1)
    }

    func progressToNextLevel(for totalKm: Double) -> Double {
        let currentLevel = level(for: totalKm)
        let start = Double(currentLevel - 1) * 100.0
        let end = Double(currentLevel) * 100.0
        if end <= start { return 0 }
        return min(1, max(0, (totalKm - start) / (end - start)))
    }

    func citiesByCountry() -> [String: Int] {
        var dict: [String: Set<String>] = [:]
        for entry in visitedCities {
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            dict[parts[0], default: []].insert(parts[1])
        }
        return dict.mapValues { $0.count }
    }

    // MARK: Tiles math

    static func tileId(lat: Double, lon: Double, zoom: Int) -> String {
        let x = lon2tileX(lon, zoom)
        let y = lat2tileY(lat, zoom)
        return "\(zoom)/\(x)/\(y)"
    }

    static func lon2tileX(_ lon: Double, _ z: Int) -> Int {
        Int(floor((lon + 180.0) / 360.0 * Double(1 << z)))
    }

    static func lat2tileY(_ lat: Double, _ z: Int) -> Int {
        let latRad = lat * Double.pi / 180.0
        let n = Double(1 << z)
        let y = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0 * n
        return Int(floor(y))
    }

    static func tileBounds(zoom: Int, x: Int, y: Int) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        func tile2lon(_ x: Int, _ z: Int) -> Double {
            Double(x) / Double(1 << z) * 360.0 - 180.0
        }
        func tile2lat(_ y: Int, _ z: Int) -> Double {
            let n = Double.pi - (2.0 * Double.pi * Double(y) / Double(1 << z))
            return 180.0 / Double.pi * atan(0.5 * (exp(n) - exp(-n)))
        }
        let minLon = tile2lon(x, zoom)
        let maxLon = tile2lon(x + 1, zoom)
        let maxLat = tile2lat(y, zoom)
        let minLat = tile2lat(y + 1, zoom)
        return (minLat, minLon, maxLat, maxLon)
    }

    // MARK: Persistence helpers

    private static func loadSet(key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private static func saveSet(_ set: Set<String>, key: String) {
        let arr = Array(set)
        guard let data = try? JSONEncoder().encode(arr) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
