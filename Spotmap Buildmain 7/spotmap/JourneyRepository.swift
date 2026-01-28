import Foundation
import CoreLocation
import Combine

/// Stores and records journeys (trip logging).
///
/// This is intentionally **local-first** (file-backed JSON) so it works out of the box.
/// Cloud sync can be layered on later, but this keeps the core UX fast and reliable.
@MainActor
final class JourneyRepository: NSObject, ObservableObject, CLLocationManagerDelegate {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    @Published private(set) var journeys: [JourneyRecord] = []
    /// `true` when tracking is enabled (not a "drive mode" – this is the default behavior).
    @Published private(set) var isRecording: Bool = false

    /// Start timestamp for the *current moving segment*.
    @Published private(set) var startedAt: Date?

    /// Start timestamp for the *current app session* (polyline you see on the Home map).
    @Published private(set) var sessionStartedAt: Date?

    /// Stationary state (used for auto-segmentation + UI).
    @Published private(set) var isStationary: Bool = false
    @Published private(set) var stationarySince: Date?
    @Published private(set) var stationaryDuration: TimeInterval = 0
    @Published private(set) var currentSpeedMps: Double = 0
    @Published private(set) var currentDistanceMeters: Double = 0
    @Published private(set) var sessionDistanceMeters: Double = 0
    @Published private(set) var currentMaxSpeedMps: Double = 0
    @Published private(set) var currentAvgSpeedMps: Double = 0
    @Published var lastErrorMessage: String?

    private let store = JourneyStore()
    private let manager = CLLocationManager()

    // Settings
    private let trackingEnabledKey = "Tracking.enabled"
    private let exploreEnabledKey = "Explore.enabled"

    // Points for the current moving segment (used to create a JourneyRecord)
    private var segmentPoints: [JourneyPoint] = []
    private var segmentLastAcceptedLocation: CLLocation?

    // Points for the current app session (shown on the Home map as "where you drove since start")
    private var sessionPoints: [JourneyPoint] = []
    private var sessionLastAcceptedLocation: CLLocation?

    private var segmentIsActive: Bool = false
    private var lastAverageSampleAt: Date?

    // Keeps background delivery more reliable on newer iOS.
    private var backgroundActivitySession: AnyObject?

    // Tunables for accuracy/perf
    private let minDistanceBetweenPoints: CLLocationDistance = 7
    private let minTimeBetweenPoints: TimeInterval = 2
    private let maxAcceptableAccuracy: CLLocationAccuracy = 65

    // Auto segmentation
    private let stationarySpeedThresholdMps: Double = 1.0       // ~3.6 km/h
    private let stationaryEndAfterSeconds: TimeInterval = 90      // end a segment after being stopped this long
    private let minSegmentDistanceMeters: Double = 30             // don't save tiny "journeys"

    override init() {
        super.init()
        Task { [weak self] in
            guard let self else { return }
            let cached = await store.load()
            self.journeys = cached
        }

        // CLLocationManager delegate callbacks are delivered on the main run loop by default
        // when created on the main thread (which is the case in SwiftUI apps).
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true

        // Auto-start tracking by default.
        // (User can disable in Settings → Tracking.)
        ensureTrackingRunning()
    }

    // MARK: - Public API

    /// Whether tracking is enabled (persisted).
    var trackingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: trackingEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: trackingEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: trackingEnabledKey)
            newValue ? ensureTrackingRunning() : stopTracking()
        }
    }

    func ensureTrackingRunning() {
        guard trackingEnabled else { return }
        guard !isRecording else { return }
        startTracking()
    }

    func setTrackingEnabled(_ enabled: Bool) {
        trackingEnabled = enabled
    }

    // Legacy API used by older UI pieces (kept for compatibility)
    func start() { setTrackingEnabled(true) }
    func stop() { setTrackingEnabled(false) }
    func toggle() { setTrackingEnabled(!trackingEnabled) }

    func requestPermissionsIfNeeded() {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Ask for Always so we can keep tracking when the screen is off / app in background.
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    private func startTracking() {
        lastErrorMessage = nil
        requestPermissionsIfNeeded()

        isRecording = true
        if sessionStartedAt == nil { sessionStartedAt = Date() }

        // Reset live UI metrics
        currentSpeedMps = 0
        currentDistanceMeters = 0
        sessionDistanceMeters = 0
        currentMaxSpeedMps = 0
        currentAvgSpeedMps = 0
        lastAverageSampleAt = Date()

        // Reset points
        segmentPoints.removeAll(keepingCapacity: true)
        sessionPoints.removeAll(keepingCapacity: true)
        segmentLastAcceptedLocation = nil
        sessionLastAcceptedLocation = nil
        segmentIsActive = false
        startedAt = nil

        // Stationary
        isStationary = false
        stationarySince = nil
        stationaryDuration = 0

        // Extra reliability for background delivery on newer iOS.
        if #available(iOS 17.0, *) {
            backgroundActivitySession = CLBackgroundActivitySession()
        }

        manager.startUpdatingLocation()
    }

    /// Stops *all* tracking (used when the user disables tracking in Settings).
    private func stopTracking() {
        guard isRecording else { return }

        // Finalize any active segment before shutting down.
        finalizeSegmentIfNeeded(endedAt: Date())

        isRecording = false
        manager.stopUpdatingLocation()

        if #available(iOS 17.0, *) {
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        }
        backgroundActivitySession = nil

        startedAt = nil
        segmentPoints.removeAll()
        sessionPoints.removeAll()
        segmentLastAcceptedLocation = nil
        sessionLastAcceptedLocation = nil
        segmentIsActive = false
        currentSpeedMps = 0
        currentDistanceMeters = 0
        sessionDistanceMeters = 0
        currentMaxSpeedMps = 0
        currentAvgSpeedMps = 0
        isStationary = false
        stationarySince = nil
        stationaryDuration = 0
    }

    func delete(_ record: JourneyRecord) {
        Task { [weak self] in
            guard let self else { return }
            let updated = await store.delete(record)
            self.journeys = updated
        }
    }

    func currentPolyline() -> [CLLocationCoordinate2D] {
        // For legacy UI components we return the session polyline ("since app start").
        sessionPoints.map { $0.coordinate }
    }

    func sessionPolyline() -> [CLLocationCoordinate2D] {
        sessionPoints.map { $0.coordinate }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self._handleAuthorization(status)
        }
    }

    @MainActor
    private func _handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .denied, .restricted:
            lastErrorMessage = "Locatie staat uit. Zet Locatie aan in Instellingen om journeys te loggen."
            if isRecording { stopTracking() }
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self._handleFail(error)
        }
    }

    @MainActor
    private func _handleFail(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        if isRecording { stopTracking() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self._handleLocations(locations)
        }
    }

    @MainActor
    private func _handleLocations(_ locations: [CLLocation]) {
        guard isRecording else { return }
        guard let loc = locations.last else { return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= maxAcceptableAccuracy else { return }
        guard loc.timestamp.timeIntervalSinceNow > -10 else { return }

        currentSpeedMps = max(0, loc.speed)
        currentMaxSpeedMps = max(currentMaxSpeedMps, currentSpeedMps)

        // Session accept / filtering (density)
        if let last = sessionLastAcceptedLocation {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            let dd = loc.distance(from: last)
            if dt < minTimeBetweenPoints && dd < minDistanceBetweenPoints {
                updateAverageIfNeeded(now: loc.timestamp)
                return
            }
            if dd > 0.5 {
                sessionDistanceMeters += dd
            }
        }

        // Add to session points (always)
        sessionPoints.append(JourneyPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, ts: loc.timestamp, speedMps: currentSpeedMps))
        sessionLastAcceptedLocation = loc

        // Optional: Reveal fog-of-war even when the screen is off (based on Explore toggle).
        if UserDefaults.standard.bool(forKey: exploreEnabledKey) {
            FogOfWarStore.shared.reveal(location: loc)
        }

        // Stationary detection
        let moving = loc.speed >= stationarySpeedThresholdMps
        if moving {
            isStationary = false
            stationarySince = nil
            stationaryDuration = 0

            // Begin a segment when we start moving.
            if !segmentIsActive {
                beginSegment(at: loc)
            }
        } else {
            if stationarySince == nil { stationarySince = loc.timestamp }
            isStationary = true
            if let since = stationarySince {
                stationaryDuration = loc.timestamp.timeIntervalSince(since)
            }
        }

        // Segment logging (only when segment is active)
        if segmentIsActive {
            if let last = segmentLastAcceptedLocation {
                let dt = loc.timestamp.timeIntervalSince(last.timestamp)
                let dd = loc.distance(from: last)
                if dt >= minTimeBetweenPoints || dd >= minDistanceBetweenPoints {
                    if dd > 0.5 { currentDistanceMeters += dd }
                    segmentPoints.append(JourneyPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, ts: loc.timestamp, speedMps: currentSpeedMps))
                    segmentLastAcceptedLocation = loc
                }
            } else {
                segmentPoints.append(JourneyPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, ts: loc.timestamp, speedMps: currentSpeedMps))
                segmentLastAcceptedLocation = loc
            }

            // Auto-end segment when we're stopped long enough.
            if isStationary && stationaryDuration >= stationaryEndAfterSeconds {
                finalizeSegmentIfNeeded(endedAt: loc.timestamp)
            }
        }

        updateAverageIfNeeded(now: loc.timestamp)
    }

    private func beginSegment(at loc: CLLocation) {
        segmentIsActive = true
        startedAt = loc.timestamp
        currentDistanceMeters = 0
        currentMaxSpeedMps = max(0, loc.speed)
        currentAvgSpeedMps = 0
        segmentPoints.removeAll(keepingCapacity: true)
        segmentLastAcceptedLocation = loc
        segmentPoints.append(JourneyPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, ts: loc.timestamp, speedMps: max(0, loc.speed)))
        lastAverageSampleAt = loc.timestamp
    }

    private func finalizeSegmentIfNeeded(endedAt: Date) {
        guard segmentIsActive else { return }
        segmentIsActive = false

        let end = endedAt
        guard let start = startedAt, segmentPoints.count >= 2, currentDistanceMeters >= minSegmentDistanceMeters else {
            // Reset segment state but do not persist.
            startedAt = nil
            segmentPoints.removeAll()
            segmentLastAcceptedLocation = nil
            currentDistanceMeters = 0
            currentAvgSpeedMps = 0
            stationarySince = nil
            stationaryDuration = 0
            return
        }

        let avg = computeAverageSpeedMps(distanceMeters: currentDistanceMeters, start: start, end: end)
        let record = JourneyRecord.make(
            from: segmentPoints,
            startedAt: start,
            endedAt: end,
            distanceMeters: currentDistanceMeters,
            maxSpeedMps: currentMaxSpeedMps,
            avgSpeedMps: avg
        )

        Task { [weak self] in
            guard let self else { return }
            let updated = await store.add(record)
            self.journeys = updated
        }
        ExploreStore.shared.ingest(record)

        // Reset segment-only UI metrics
        startedAt = nil
        segmentPoints.removeAll()
        segmentLastAcceptedLocation = nil
        currentDistanceMeters = 0
        currentAvgSpeedMps = 0
        currentMaxSpeedMps = 0
        stationarySince = nil
        stationaryDuration = 0
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

private final class JourneyStore {
    private let queue = DispatchQueue(label: "spotmap.journey-store", qos: .utility)
    private let fileURL: URL

    init() {
        self.fileURL = Self.storeURL()
    }

    func load() async -> [JourneyRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL] in
                let records = Self.loadRecords(from: fileURL)
                continuation.resume(returning: records)
            }
        }
    }

    func add(_ record: JourneyRecord) async -> [JourneyRecord] {
        await mutate { all in
            var updated = all
            updated.insert(record, at: 0)
            return updated
        }
    }

    func delete(_ record: JourneyRecord) async -> [JourneyRecord] {
        await mutate { all in
            all.filter { $0.id != record.id }
        }
    }

    private func mutate(_ transform: @escaping ([JourneyRecord]) -> [JourneyRecord]) async -> [JourneyRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [fileURL] in
                let existing = Self.loadRecords(from: fileURL)
                let updated = transform(existing)
                Self.persist(updated, to: fileURL)
                continuation.resume(returning: updated)
            }
        }
    }

    private static func loadRecords(from fileURL: URL) -> [JourneyRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([JourneyRecord].self, from: data)) ?? []
    }

    private static func persist(_ all: [JourneyRecord], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        do {
            try ensureDirectoryExists(for: fileURL)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    private static func storeURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotmap", isDirectory: true)
        return directory.appendingPathComponent("Journeys.v1.json")
    }

    private static func ensureDirectoryExists(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}


// MARK: - Explore / achievements store

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
        Task { @MainActor in
            visitedTiles = tiles
        }
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
