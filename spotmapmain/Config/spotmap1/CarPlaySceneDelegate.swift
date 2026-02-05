import Foundation
@preconcurrency import CarPlay
import UIKit
import MapKit
import CoreLocation
import CloudKit

/// CarPlay integration for SpotMap.
///
/// Design intent: calm, minimal, template-driven CarPlay UX.
/// - Root = Map with only a few actions (Search / Spots / Recenter)
/// - Search = CPSearchTemplate -> results list
/// - Preview = route choices list (fastest + alternates when available)
/// - Navigating = minimal controls + optional steps list
///
/// Notes:
/// - Full third-party navigation on real headunits requires the proper
///   CarPlay Navigation/Maps entitlement. The code compiles and works in
///   the CarPlay simulator; on unsupported setups it still provides the
///   template flows and can fall back to opening the phone app.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        let coordinator = CarPlayCoordinator()
        self.coordinator = coordinator

        // Attach a lightweight MapKit renderer into the CarPlay window.
        // This helps the simulator/headunit show a map background even when
        // your iPhone UI is separate.
        coordinator.attach(interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        coordinator?.detach()
        coordinator = nil
    }
}

// MARK: - Coordinator

/// Imperative bridge between app state and CarPlay templates.
/// Keep this logic out of the scene delegate.
@MainActor
final class CarPlayCoordinator: NSObject {

    // Controllers
    private weak var interfaceController: CPInterfaceController?
    private weak var carPlayWindow: CPWindow?

    // UI
    private var mapTemplate: CPMapTemplate?
    private var navSession: CPNavigationSession?
    private var stepsTemplate: CPListTemplate?
    private var spotsTemplate: CPListTemplate?

    // Renderer
    private var mapVC: CarPlayMapViewController?

    // Domain
    private let spotRepo = SpotRepository()
    private let nav = NavigationManager()

    // State
    private var activeTrip: CPTrip?
    private var activeRoute: MKRoute?
    private var activeDestination: MKMapItem?
    private var activeSpotRecordName: String?
    private var lastRouteChoices: [MKRoute] = []

    // Observers
    private var spotRefreshTask: Task<Void, Never>?
    private var navUpdateTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    func attach(interfaceController: CPInterfaceController, window: CPWindow) {
        detach() // idempotent

        self.interfaceController = interfaceController
        self.carPlayWindow = window

        // Map renderer
        let mapVC = CarPlayMapViewController()
        self.mapVC = mapVC
        window.rootViewController = mapVC

        // Root template
        let map = makeRootMapTemplate()
        self.mapTemplate = map
        interfaceController.setRootTemplate(map, animated: true, completion: nil)

        // Start watchers
        startSpotRefreshLoop()
        startNavSyncLoop()
        applySpotsToCarPlayUI()
    }

    func detach() {
        spotRefreshTask?.cancel()
        navUpdateTask?.cancel()
        searchTask?.cancel()
        spotRefreshTask = nil
        navUpdateTask = nil
        searchTask = nil

        navSession = nil
        activeTrip = nil
        activeRoute = nil
        activeDestination = nil
        activeSpotRecordName = nil
        lastRouteChoices = []

        mapTemplate = nil
        stepsTemplate = nil
        spotsTemplate = nil

        interfaceController = nil
        carPlayWindow = nil
        mapVC = nil
    }

    // MARK: - Root map template

    private func makeRootMapTemplate() -> CPMapTemplate {
        let template = CPMapTemplate()
        template.mapDelegate = self

        // Overlay map buttons (small, not cluttered).
        template.mapButtons = [
            CPMapButton { [weak self] _ in
                self?.mapVC?.recenterOnUser()
            }.configured(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie")
        ]

        // Top bar actions.
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Spots") { [weak self] _ in
                self?.presentSpots()
            },
            CPBarButton(title: "Zoek") { [weak self] _ in
                self?.presentSearch()
            }
        ]

        return template
    }

    private func setMapButtonsForState(isNavigating: Bool) {
        guard let mapTemplate else { return }

        if isNavigating {
            mapTemplate.leadingNavigationBarButtons = [
                CPBarButton(title: "Stop") { [weak self] _ in
                    self?.stopNavigation()
                }
            ]
            mapTemplate.trailingNavigationBarButtons = [
                CPBarButton(title: "Stappen") { [weak self] _ in
                    self?.presentSteps()
                }
            ]

            // Keep only recenter as an overlay map button.
            mapTemplate.mapButtons = [
                CPMapButton { [weak self] _ in
                    self?.mapVC?.recenterOnUser()
                }.configured(systemImage: "location.fill", accessibilityLabel: "Recenter")
            ]
        } else {
            mapTemplate.trailingNavigationBarButtons = [
                CPBarButton(title: "Spots") { [weak self] _ in
                    self?.presentSpots()
                },
                CPBarButton(title: "Zoek") { [weak self] _ in
                    self?.presentSearch()
                }
            ]

            mapTemplate.mapButtons = [
                CPMapButton { [weak self] _ in
                    self?.mapVC?.recenterOnUser()
                }.configured(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie")
            ]
        }
    }

    // MARK: - Spots

    private func presentSpots() {
        guard let ic = interfaceController else { return }

        let spots = spotRepo.spots
        let items: [CPListItem] = spots.prefix(100).map { spot in
            let item = CPListItem(text: spot.title, detailText: spot.note.isEmpty ? nil : spot.note)
            item.handler = { [weak self] _, completion in
                let destination = MKMapItem(placemark: MKPlacemark(coordinate: spot.location.coordinate))
                self?.previewRoutes(to: destination, name: spot.title, recordName: spot.id.recordName)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items.isEmpty ? [openOnPhoneItem()] : items,
                                    header: "Spots",
                                    sectionIndexTitle: nil)

        let t = CPListTemplate(title: "Spots", sections: [section])
        t.leadingNavigationBarButtons = [
            CPBarButton(title: "Terug") { [weak ic] _ in
                ic?.popTemplate(animated: true, completion: nil)
            }
        ]
        self.spotsTemplate = t
        ic.pushTemplate(t, animated: true, completion: nil)
    }

    private func applySpotsToCarPlayUI() {
        // If the user is currently viewing the spots template, refresh its section.
        guard let spotsTemplate else { return }
        let spots = spotRepo.spots
        let items: [CPListItem] = spots.prefix(100).map { spot in
            let item = CPListItem(text: spot.title, detailText: spot.note.isEmpty ? nil : spot.note)
            item.handler = { [weak self] _, completion in
                let destination = MKMapItem(placemark: MKPlacemark(coordinate: spot.location.coordinate))
                self?.previewRoutes(to: destination, name: spot.title, recordName: spot.id.recordName)
                completion()
            }
            return item
        }
        spotsTemplate.updateSections([
            CPListSection(items: items.isEmpty ? [openOnPhoneItem()] : items,
                          header: "Spots",
                          sectionIndexTitle: nil)
        ])
    }

    // MARK: - Search

    private func presentSearch() {
        guard let ic = interfaceController else { return }
        let search = CPSearchTemplate()
        search.delegate = self
        ic.pushTemplate(search, animated: true, completion: nil)
    }

    // MARK: - Route preview

    private func previewRoutes(to destination: MKMapItem, name: String?, recordName: String? = nil) {
        activeDestination = destination
        activeSpotRecordName = recordName

        // Mirror on the phone engine (so instruction/progress works).
        nav.previewNavigation(to: destination, name: name)

        // Compute alternates for CarPlay choice list.
        Task { [weak self] in
            guard let self else { return }
            let routes = await self.calculateAlternates(to: destination)
            await MainActor.run {
                self.lastRouteChoices = routes
                self.presentRouteChoices(routes: routes, destinationName: name ?? destination.name ?? "Bestemming")
                self.mapVC?.showPreview(destination: destination, routes: routes)
            }
        }
    }

    private func presentRouteChoices(routes: [MKRoute], destinationName: String) {
        guard let ic = interfaceController else { return }

        let choices: [CPListItem] = routes.prefix(3).enumerated().map { (idx, r) in
            let mins = Int(round(r.expectedTravelTime / 60))
            let km = r.distance / 1000
            let label = idx == 0 ? "Snelste" : "Alternatief"
            let item = CPListItem(text: "\(label): \(mins) min", detailText: String(format: "%.1f km", km))
            item.handler = { [weak self] _, completion in
                self?.startNavigation(using: r, destinationName: destinationName)
                completion()
            }
            return item
        }

        let startOnPhone = CPListItem(text: "Open op iPhone", detailText: "Start navigatie in de app")
        startOnPhone.handler = { [weak self] _, completion in
            if let recordName = self?.activeSpotRecordName {
                self?.openURL("spotmap://navigate/spot/\(recordName)")
            } else {
                self?.openURL("spotmap://")
            }
            completion()
        }

        let section = CPListSection(items: choices + [startOnPhone], header: destinationName, sectionIndexTitle: nil)
        let template = CPListTemplate(title: "Route", sections: [section])
        template.leadingNavigationBarButtons = [
            CPBarButton(title: "Terug") { [weak ic] _ in
                ic?.popTemplate(animated: true, completion: nil)
            }
        ]

        ic.pushTemplate(template, animated: true, completion: nil)
    }

    private func startNavigation(using route: MKRoute, destinationName: String) {
        guard let mapTemplate else { return }
        guard let dest = activeDestination else { return }

        activeRoute = route
        mapVC?.showActive(route: route, destination: dest)

        // Build CPTrip with up to 3 choices (including the chosen one).
        let origin = MKMapItem.forCurrentLocation()
        let choices = lastRouteChoices.prefix(3).map { mkRoute in
            let mins = Int(round(mkRoute.expectedTravelTime / 60))
            let km = mkRoute.distance / 1000
            return CPRouteChoice(summaryVariants: ["\(mins) min"],
                                 additionalInformationVariants: [String(format: "%.1f km", km)],
                                 selectionSummaryVariants: [destinationName])
        }
        let trip = CPTrip(origin: origin, destination: dest, routeChoices: Array(choices))
        self.activeTrip = trip

        // Start session
        let session = mapTemplate.startNavigationSession(for: trip)
        self.navSession = session

        setMapButtonsForState(isNavigating: true)

        // Start phone navigation (for turn-by-turn state) and keep CarPlay UI in sync.
        nav.startNavigation()

        // Pop back to map root to keep UI calm.
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
    }

    private func stopNavigation() {
        nav.stopNavigation()
        navSession = nil
        activeTrip = nil
        activeRoute = nil
        activeDestination = nil
        activeSpotRecordName = nil
        lastRouteChoices = []

        mapVC?.clearOverlays()
        setMapButtonsForState(isNavigating: false)

        // Return to root map.
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
    }

    // MARK: - Steps

    private func presentSteps() {
        guard let ic = interfaceController else { return }
        guard let route = activeRoute ?? nav.route else {
            let t = CPListTemplate(title: "Stappen", sections: [CPListSection(items: [])])
            ic.pushTemplate(t, animated: true, completion: nil)
            return
        }

        let items: [CPListItem] = route.steps
            .filter { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(50)
            .map { step in
                let dist = step.distance
                let text = step.instructions
                let detail = dist > 0 ? String(format: "%.0f m", dist) : nil
                return CPListItem(text: text, detailText: detail)
            }

        let section = CPListSection(items: items, header: "Stappen", sectionIndexTitle: nil)
        let t = CPListTemplate(title: "Stappen", sections: [section])
        t.leadingNavigationBarButtons = [
            CPBarButton(title: "Terug") { [weak ic] _ in
                ic?.popTemplate(animated: true, completion: nil)
            }
        ]
        stepsTemplate = t
        ic.pushTemplate(t, animated: true, completion: nil)
    }

    // MARK: - MKDirections

    private func calculateAlternates(to destination: MKMapItem) async -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        do {
            let response = try await MKDirections(request: request).calculate()
            // Sort by expected time, keep 3.
            let sorted = response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
            return Array(sorted.prefix(3))
        } catch {
            return []
        }
    }

    // MARK: - Background loops

    private func startSpotRefreshLoop() {
        spotRefreshTask?.cancel()
        spotRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    let loc = self.spotRepo.locationForBestEffortRefresh() ?? CLLocation(latitude: 52.0, longitude: 5.0)
                    self.spotRepo.refreshNearby(center: loc)
                    self.applySpotsToCarPlayUI()
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
            }
        }
    }

    private func startNavSyncLoop() {
        navUpdateTask?.cancel()
        navUpdateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    self.syncNavToCarPlay()
                }
                try? await Task.sleep(nanoseconds: 700_000_000) // ~1.4 Hz
            }
        }
    }

    private func syncNavToCarPlay() {
        guard let mapTemplate else { return }
        guard nav.isNavigating, let trip = activeTrip else { return }

        let distance = Measurement(value: max(0, nav.remainingDistanceMeters), unit: UnitLength.meters)
        let estimates = CPTravelEstimates(distanceRemaining: distance,
                                          timeRemaining: max(0, nav.remainingTimeSeconds))
        mapTemplate.updateEstimates(estimates, for: trip)

        // Minimal on-map instruction banner (kept calm).
        if !nav.instruction.isEmpty {
            mapVC?.setBanner(text: nav.instruction)
        }
    }

    // MARK: - Helpers

    private func openOnPhoneItem() -> CPListItem {
        let item = CPListItem(text: "Open SpotMap", detailText: "Open de app op je iPhone")
        item.handler = { [weak self] _, completion in
            self?.openURL("spotmap://")
            completion()
        }
        return item
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func handleSearchTemplate(updatedSearchText searchText: String,
                                      completionHandler: @escaping ([CPListItem]) -> Void) {
        // Cancel any in-flight search to keep UI responsive and avoid calling the completion handler out-of-order.
        searchTask?.cancel()
        searchTask = nil

        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            DispatchQueue.main.async { completionHandler([]) }
            return
        }

        searchTask = Task { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completionHandler([]) }
                return
            }

            guard !Task.isCancelled else { return }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.resultTypes = [.address, .pointOfInterest]

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }

                let items = response.mapItems.prefix(10).map { item -> CPListItem in
                    let title = item.name ?? "Resultaat"
                    let subtitle = item.placemark.title
                    let listItem = CPListItem(text: title, detailText: subtitle)
                    listItem.handler = { [weak self] _, completion in
                        self?.previewRoutes(to: item, name: title)
                        completion()
                    }
                    return listItem
                }

                DispatchQueue.main.async {
                    completionHandler(Array(items))
                }
            } catch {
                // Ignore errors (often "network unavailable" etc.) and just return an empty list.
                DispatchQueue.main.async { completionHandler([]) }
            }
        }
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayCoordinator: CPMapTemplateDelegate {
    nonisolated func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        // No-op: we keep UI minimal.
    }

    nonisolated func mapTemplateDidEndPanGesture(_ mapTemplate: CPMapTemplate) {
        // No-op.
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlayCoordinator: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate,
                                    updatedSearchText searchText: String,
                                    completionHandler: @escaping ([CPListItem]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.handleSearchTemplate(updatedSearchText: searchText, completionHandler: completionHandler)
        }
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        // We handle selection via per-item handlers.
        completionHandler()
    }

    nonisolated func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // No-op.
    }
}

// MARK: - UIKit map renderer

/// Very lightweight MapKit renderer used on the CarPlay window.
/// This is not a full navigation renderer; it exists to provide a calm
/// background map plus route overlays in the simulator.
final class CarPlayMapViewController: UIViewController, MKMapViewDelegate {
    private let mapView = MKMapView(frame: .zero)
    private let bannerLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false

        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.textAlignment = .center
        bannerLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        bannerLabel.textColor = .white
        bannerLabel.numberOfLines = 2
        bannerLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.55)
        bannerLabel.layer.cornerRadius = 12
        bannerLabel.layer.masksToBounds = true
        bannerLabel.alpha = 0

        view.addSubview(bannerLabel)
        NSLayoutConstraint.activate([
            bannerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bannerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            bannerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            bannerLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    func setBanner(text: String) {
        guard !text.isEmpty else {
            UIView.animate(withDuration: 0.2) {
                self.bannerLabel.alpha = 0
            }
            return
        }

        bannerLabel.text = text
        if bannerLabel.alpha < 0.99 {
            UIView.animate(withDuration: 0.2) {
                self.bannerLabel.alpha = 1
            }
        }
    }

    func recenterOnUser() {
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    func clearOverlays() {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        setBanner(text: "")
    }

    func showPreview(destination: MKMapItem, routes: [MKRoute]) {
        clearOverlays()

        let ann = MKPointAnnotation()
        ann.title = destination.name
        ann.coordinate = destination.placemark.coordinate
        mapView.addAnnotation(ann)

        for r in routes.prefix(3) {
            mapView.addOverlay(r.polyline)
        }

        zoomToFit(routes: routes, destination: destination)
    }

    func showActive(route: MKRoute, destination: MKMapItem) {
        clearOverlays()
        let ann = MKPointAnnotation()
        ann.title = destination.name
        ann.coordinate = destination.placemark.coordinate
        mapView.addAnnotation(ann)
        mapView.addOverlay(route.polyline)
        zoomToFit(routes: [route], destination: destination)
    }

    private func zoomToFit(routes: [MKRoute], destination: MKMapItem) {
        let polylines = routes.prefix(3).map { $0.polyline }
        guard let first = polylines.first else {
            let region = MKCoordinateRegion(center: destination.placemark.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25))
            mapView.setRegion(region, animated: true)
            return
        }
        var mapRect = first.boundingMapRect
        for pl in polylines.dropFirst() {
            mapRect = mapRect.union(pl.boundingMapRect)
        }
        mapView.setVisibleMapRect(mapRect, edgePadding: UIEdgeInsets(top: 120, left: 80, bottom: 120, right: 80), animated: true)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: polyline)
            r.lineWidth = 6
            r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

// MARK: - Small helpers

private extension CPMapButton {
    func configured(systemImage: String, accessibilityLabel: String) -> CPMapButton {
        self.image = UIImage(systemName: systemImage)
        self.isEnabled = true
        self.accessibilityLabel = accessibilityLabel
        return self
    }
}
