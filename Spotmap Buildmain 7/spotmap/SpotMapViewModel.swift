import Foundation
import MapKit
import CoreLocation
import Combine
import SwiftUI

@MainActor
final class SpotMapViewModel: ObservableObject {
    @Published var mapPosition: MapCameraPosition = .automatic
    @Published var selectedSpot: Spot?
    @Published var showingAdd = false
    @Published var mapCenter: CLLocationCoordinate2D = .init(latitude: 52.3702, longitude: 4.8952) // default A'dam

    let locationManager = LocationManager()
    let repo: SpotRepository

    private var cancellables = Set<AnyCancellable>()
    private var didAutoFocus = false
    private var didInitialRefresh = false

    init(repo: SpotRepository) {
        self.repo = repo

        // When a location becomes available the first time, zoom to it.
        locationManager.$lastLocation
            .compactMap { $0 }
            .sink { [weak self] loc in
                guard let self else { return }
                guard !self.didAutoFocus else { return }
                self.didAutoFocus = true
                self.focus(on: loc.coordinate)
            }
            .store(in: &cancellables)
    }

    func onAppear() {
        locationManager.requestWhenInUse()

        // Always do at least one refresh (using default center or cached center)
        // so the app doesn't look "empty" if location isn't available yet.
        if !didInitialRefresh {
            didInitialRefresh = true
            let c = mapCenter
            repo.refreshNearby(center: CLLocation(latitude: c.latitude, longitude: c.longitude), force: true)
        }

        // If location was already known (rare, but can happen), focus immediately.
        if let loc = locationManager.lastLocation, !didAutoFocus {
            didAutoFocus = true
            focus(on: loc.coordinate)
        }
    }

    func focusOnUser() {
        guard let loc = locationManager.lastLocation else { return }
        focus(on: loc.coordinate)
    }

    func focus(on coordinate: CLLocationCoordinate2D) {
        mapPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        ))
        mapCenter = coordinate
        repo.refreshNearby(center: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), force: true)
    }

    func mapCenterChanged(to coordinate: CLLocationCoordinate2D) {
        mapCenter = coordinate
        repo.refreshNearby(center: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func handleDeepLink(_ url: URL) {
        guard let deepLink = DeepLink(url: url) else { return }

        switch deepLink {
        case .spot(let recordName):
            Task {
                if let spot = await repo.fetchSpotIfNeeded(recordName: recordName) {
                    selectedSpot = spot
                    focus(on: spot.location.coordinate)
                }
            }
        default:
            break
        }
    }
}
