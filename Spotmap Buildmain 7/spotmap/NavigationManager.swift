import Foundation
import MapKit
import CoreLocation
import Combine

/// In-app navigation manager.
///
/// Xcode 26 / Swift 6 strict concurrency note:
/// `ObservableObject` requires a nonisolated `objectWillChange`. When the class is `@MainActor`,
/// the synthesized publisher can be considered actor-isolated and cause:
/// "Type 'X' does not conform to protocol 'ObservableObject'".
/// Providing our own nonisolated publisher resolves that.
@MainActor
final class NavigationManager: NSObject, ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    // MARK: - Public state

    @Published private(set) var destinationName: String? = nil
    @Published private(set) var destination: MKMapItem? = nil
    @Published private(set) var route: MKRoute? = nil

    @Published private(set) var isCalculating: Bool = false
    @Published private(set) var isPreviewing: Bool = false
    @Published private(set) var isNavigating: Bool = false

    // Used by SpotMapView to present the preview sheet.
    @Published var isShowingPreviewSheet: Bool = false

    // Used to force a recenter request in MKMapView wrapper.
    @Published var recenterToken: UUID = UUID()

    // UI values
    @Published private(set) var instruction: String = ""
    @Published private(set) var remainingDistanceMeters: Double = 0
    @Published private(set) var remainingTimeSeconds: TimeInterval = 0
    @Published private(set) var distanceToNextManeuverMeters: Double = 0
    @Published private(set) var offRouteMeters: Double = 0

    // MARK: - Tunables

    private let rerouteThresholdMeters: Double = 35
    private let stepAdvanceThresholdMeters: Double = 25

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation? = nil

    private var currentStepIndex: Int = 0

    // Polyline cache for quick progress calculation
    private var polylinePoints: [MKMapPoint] = []
    private var polylineCumDist: [Double] = [] // meters, same count as points
    private var stepEndAlongDistances: [Double] = [] // meters along route

    private var activeDirections: MKDirections? = nil
    private var calculateTask: Task<Void, Never>? = nil

    override init() {
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = true

        // Start updates early so we have a "current location" when the user taps navigate.
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    // MARK: - Public actions

    func requestRecenter() {
        recenterToken = UUID()
    }

    /// Prepare route preview to a destination.
    func previewNavigation(to item: MKMapItem, name: String? = nil) {
        destination = item
        destinationName = name ?? item.name
        isPreviewing = true
        isShowingPreviewSheet = true

        calculateRoute(to: item)
    }

    /// Cancels the preview sheet & clears the preview route.
    func cancelPreview() {
        isShowingPreviewSheet = false
        isPreviewing = false
        isNavigating = false
        clearRoute(keepDestination: true)
    }

    /// Start turn-by-turn like guidance inside the app.
    func startNavigation() {
        guard route != nil else { return }
        isPreviewing = false
        isShowingPreviewSheet = false
        isNavigating = true

        // Reset step index to the first meaningful step.
        currentStepIndex = firstNonEmptyStepIndex()
        updateInstruction()

        // Recenter map to begin.
        requestRecenter()

        // Immediately refresh derived values.
        if let loc = lastLocation {
            updateProgress(with: loc)
        }
    }

    func stopNavigation() {
        isNavigating = false
        isPreviewing = false
        isShowingPreviewSheet = false
        clearRoute(keepDestination: true)
    }

    /// Clears any preview/navigation state, including the destination.
    func clearAll() {
        isNavigating = false
        isPreviewing = false
        isShowingPreviewSheet = false
        clearRoute(keepDestination: false)
    }

    // MARK: - Routing

    private func calculateRoute(to item: MKMapItem) {
        calculateTask?.cancel()
        calculateTask = nil

        activeDirections?.cancel()
        activeDirections = nil

        isCalculating = true

        let currentCoordinate = lastLocation?.coordinate

        calculateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCalculating = false }

            // Build request
            let request = MKDirections.Request()
            if let c = currentCoordinate {
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: c))
            } else {
                request.source = MKMapItem.forCurrentLocation()
            }
            request.destination = item
            request.transportType = .automobile
            request.requestsAlternateRoutes = false

            let directions = MKDirections(request: request)
            self.activeDirections = directions

            do {
                let response = try await directions.calculate()
                guard !Task.isCancelled else { return }

                if let best = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) {
                    self.applyRoute(best)
                } else {
                    self.clearRoute(keepDestination: true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.clearRoute(keepDestination: true)
            }

        }
    }

    private func applyRoute(_ newRoute: MKRoute) {
        route = newRoute
        currentStepIndex = firstNonEmptyStepIndex()

        preparePolylineCache(for: newRoute)
        updateInstruction()

        // refresh
        if let loc = lastLocation {
            updateProgress(with: loc)
        } else {
            clearDerivedUI()
        }
    }

    private func clearRoute(keepDestination: Bool) {
        route = nil
        isCalculating = false

        polylinePoints = []
        polylineCumDist = []
        stepEndAlongDistances = []

        currentStepIndex = 0
        clearDerivedUI()

        if !keepDestination {
            destination = nil
            destinationName = nil
        }
    }

    private func clearDerivedUI() {
        instruction = ""
        remainingDistanceMeters = 0
        remainingTimeSeconds = 0
        distanceToNextManeuverMeters = 0
        offRouteMeters = 0
    }

    // MARK: - Progress

    private func updateProgress(with loc: CLLocation) {
        guard let r = route, !polylinePoints.isEmpty else {
            clearDerivedUI()
            return
        }

        // Closest point to route + along-route distance.
        let (distanceToRoute, alongMeters) = closestInfo(to: loc.coordinate, points: polylinePoints, cumDist: polylineCumDist)
        offRouteMeters = distanceToRoute

        let remaining = max(0, r.distance - alongMeters)
        remainingDistanceMeters = remaining

        // Speed can be -1 when invalid.
        let rawSpeed = max(0, loc.speed)
        let assumedSpeed = rawSpeed >= 2 ? rawSpeed : 8 // ~28.8 km/h when slow/standing
        remainingTimeSeconds = remaining / max(1, assumedSpeed)

        // Advance steps if needed.
        if !stepEndAlongDistances.isEmpty {
            let idx = min(max(currentStepIndex, 0), stepEndAlongDistances.count - 1)
            let nextEnd = stepEndAlongDistances[idx]
            let distToEnd = max(0, nextEnd - alongMeters)
            distanceToNextManeuverMeters = distToEnd

            if distToEnd <= stepAdvanceThresholdMeters {
                advanceStepIfPossible()
            }
        } else {
            distanceToNextManeuverMeters = 0
        }

        // Reroute if off-route while navigating.
        if isNavigating, distanceToRoute >= rerouteThresholdMeters, let dest = destination {
            calculateRoute(to: dest)
        }
    }

    private func advanceStepIfPossible() {
        guard let r = route else { return }

        var next = currentStepIndex + 1
        while next < r.steps.count {
            // Skip empty steps (often first/last are "" and represent start/end).
            if !r.steps[next].instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentStepIndex = next
                updateInstruction()
                return
            }
            next += 1
        }
    }

    private func updateInstruction() {
        guard let r = route, !r.steps.isEmpty else {
            instruction = ""
            return
        }

        let idx = min(max(currentStepIndex, 0), r.steps.count - 1)
        let step = r.steps[idx]

        let instr = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instr.isEmpty {
            instruction = instr
        } else if let notice = step.notice {
            instruction = notice
        } else {
            instruction = "Volg de route"
        }
    }

    private func firstNonEmptyStepIndex() -> Int {
        guard let r = route else { return 0 }
        for (i, s) in r.steps.enumerated() {
            if !s.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return i
            }
        }
        return 0
    }

    private func preparePolylineCache(for r: MKRoute) {
        let poly = r.polyline
        let count = poly.pointCount

        guard count >= 2 else {
            polylinePoints = []
            polylineCumDist = []
            stepEndAlongDistances = []
            return
        }

        // 1) Route polyline points  (Xcode 26+: use points() instead of getPoints)
        let pts: [MKMapPoint] = {
            let ptr = poly.points()
            let buf = UnsafeBufferPointer(start: ptr, count: count)
            return Array(buf)
        }()
        polylinePoints = pts

        // 2) Cumulative distances (meters) (use MKMapPoint.distance(to:))
        var cum = Array(repeating: 0.0, count: count)
        var running = 0.0
        for i in 1..<count {
            running += pts[i - 1].distance(to: pts[i])
            cum[i] = running
        }
        polylineCumDist = cum

        // 3) Step end distances along the *route polyline*
        let steps = r.steps
        stepEndAlongDistances = steps.map { step in
            let sp = step.polyline
            let spCount = sp.pointCount

            guard spCount >= 2 else { return cum.last ?? 0 }

            let endCoord: CLLocationCoordinate2D? = {
                let spPtr = sp.points()
                let spBuf = UnsafeBufferPointer(start: spPtr, count: spCount)
                return spBuf.last?.coordinate
            }()

            if let endCoord {
                return closestAlongDistance(to: endCoord, points: pts, cumDist: cum)
            } else {
                return cum.last ?? 0
            }
        }

        // 4) Ensure step ends are monotonically increasing
        if stepEndAlongDistances.count >= 2 {
            for i in 1..<stepEndAlongDistances.count {
                stepEndAlongDistances[i] = max(stepEndAlongDistances[i], stepEndAlongDistances[i - 1])
            }
        }
    }

    // MARK: - Geometry helpers

    /// Returns (distanceMetersToRoute, alongMetersFromStartAtClosestPoint)
    private func closestInfo(to coordinate: CLLocationCoordinate2D,
                             points: [MKMapPoint],
                             cumDist: [Double]) -> (Double, Double) {
        let p = MKMapPoint(coordinate)

        var bestDist = Double.greatestFiniteMagnitude
        var bestAlong = 0.0

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let (closest, t) = closestPointOnSegment(p, a, b)
            let dist = p.distance(to: closest)
            if dist < bestDist {
                bestDist = dist
                let segLen = a.distance(to: b)
                let along = (cumDist[safe: i] ?? 0) + (t * segLen)
                bestAlong = along
            }
        }

        if bestDist == Double.greatestFiniteMagnitude {
            return (0, 0)
        }
        return (bestDist, bestAlong)
    }

    private func closestAlongDistance(to coordinate: CLLocationCoordinate2D,
                                      points: [MKMapPoint],
                                      cumDist: [Double]) -> Double {
        let (_, along) = closestInfo(to: coordinate, points: points, cumDist: cumDist)
        return along
    }

    /// Returns (closestPoint, t in [0,1])
    private func closestPointOnSegment(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> (MKMapPoint, Double) {
        let ax = a.x, ay = a.y
        let bx = b.x, by = b.y
        let px = p.x, py = p.y

        let abx = bx - ax
        let aby = by - ay
        let apx = px - ax
        let apy = py - ay

        let ab2 = (abx * abx) + (aby * aby)
        if ab2 <= .leastNonzeroMagnitude {
            return (a, 0)
        }

        var t = ((apx * abx) + (apy * aby)) / ab2
        if t < 0 { t = 0 }
        if t > 1 { t = 1 }

        let cx = ax + (t * abx)
        let cy = ay + (t * aby)
        return (MKMapPoint(x: cx, y: cy), t)
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // No-op: app can work without location but navigation will show no route.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            if self.isPreviewing || self.isNavigating {
                self.updateProgress(with: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore for now. If needed, expose a user-facing error state.
    }
}

// MARK: - Safe index

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
