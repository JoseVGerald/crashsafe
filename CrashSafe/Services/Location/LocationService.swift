import CoreLocation
import Foundation
import Observation

/// Current location + a short place name ("Bellevue, WA"). Shared by Home, the trip planner,
/// the post-crash help hub and the driving monitor.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var location: CLLocation?
    private(set) var placeName: String?
    private(set) var streetName: String?

    /// Raw updates for the driving monitor (one listener).
    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastGeocoded: CLLocation?
    @ObservationIgnored private let geocoder = CLGeocoder()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    func requestPermission() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            start()
        }
    }

    /// Needed for always-on drive detection in the background.
    func requestAlwaysPermission() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Keeps updates flowing while the app is in the background (requires the `location` background mode).
    func setBackgroundUpdates(_ enabled: Bool) {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("location") else { return }
        manager.allowsBackgroundLocationUpdates = enabled
        manager.showsBackgroundLocationIndicator = enabled
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        onUpdate?(latest)
        if lastGeocoded.map({ $0.distance(from: latest) > 400 }) ?? true {
            lastGeocoded = latest
            Task { await geocode(latest) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known location; the UI shows "Locating…" until one arrives.
    }

    private func geocode(_ location: CLLocation) async {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        placeName = Self.shortName(for: placemark)
        streetName = placemark.thoroughfare.map { street in
            placemark.subThoroughfare.map { "\($0) \(street)" } ?? street
        }
    }

    static func shortName(for placemark: CLPlacemark) -> String {
        [placemark.locality ?? placemark.subAdministrativeArea, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// One-off reverse geocode for a picked coordinate.
    static func describe(_ coordinate: CLLocationCoordinate2D) async -> (title: String, subtitle: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return ("Dropped pin", String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
        }
        let title = placemark.name ?? placemark.thoroughfare ?? "Dropped pin"
        return (title, shortName(for: placemark))
    }
}
