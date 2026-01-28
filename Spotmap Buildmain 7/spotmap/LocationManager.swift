import Foundation
import CoreLocation
import Combine

/// Location manager used by the app.
///
/// Important: Do NOT mark this class `@MainActor`.
/// CoreLocation delegate callbacks can arrive on a non-main thread and Swift's
/// actor isolation checks may terminate the app at launch if a `@MainActor`-isolated
/// delegate is called off the main actor.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var lastLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Switch between low-power and high-accuracy tracking.
    ///
    /// Used by Explore mode so the 20m reveal radius feels responsive.
    func setHighAccuracy(_ enabled: Bool) {
        if enabled {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 8
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.start()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        DispatchQueue.main.async { [weak self] in
            self?.lastLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Don't crash the app on location errors; just keep the last known location.
        // You can inspect this in the UI via repo.lastErrorMessage if needed.
    }
}

