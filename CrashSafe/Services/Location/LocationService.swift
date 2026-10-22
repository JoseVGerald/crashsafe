import CoreLocation
import Foundation
import Observation
import os

/// The device's live location + a short place name ("Seattle, WA"), from Core Location — never a
/// hard-coded default. Shared by Home, the trip planner, the post-crash help hub and the driving monitor.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate, LocationSampleSource {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var location: CLLocation?
    private(set) var placeName: String?
    private(set) var streetName: String?
    /// "US-OR", "DE"…: picks the legal default speed limits for untagged roads.
    @ObservationIgnored private(set) var regionCode: String?

    @ObservationIgnored private var sampleObservers: [UUID: (LocationSample) -> Void] = [:]
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastGeocoded: CLLocation?
    @ObservationIgnored private let geocoder = CLGeocoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// "Always" lets iOS relaunch CrashSafe when a drive starts while the app is closed.
    var hasAlwaysAccess: Bool { authorization == .authorizedAlways }

    /// iOS shows the "Change to Always Allow" prompt only once; after that the change is made in Settings.
    var canPromptForAlways: Bool {
        switch authorization {
        case .notDetermined: true
        case .authorizedWhenInUse: !defaults.bool(forKey: Self.askedAlwaysKey)
        default: false
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let log = Logger(subsystem: "org.cac.crashsafe", category: "location")
    @ObservationIgnored private var wantsDriveWakeups = false
    private static let askedAlwaysKey = "location.askedForAlways"

    func requestPermission() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            start()
        }
    }

    /// Asks for "Always" (needed for drive detection while the app is closed).
    /// Returns `false` when iOS won't show a prompt, so the caller should send the user to Settings.
    @discardableResult
    func requestAlwaysPermission() -> Bool {
        guard canPromptForAlways else { return hasAlwaysAccess }
        if authorization == .authorizedWhenInUse { defaults.set(true, forKey: Self.askedAlwaysKey) }
        manager.requestAlwaysAuthorization()
        return true
    }

    /// Re-reads the permission (e.g. after returning from Settings) and resumes live updates.
    func refreshAuthorization() {
        authorization = manager.authorizationStatus
        if isAuthorized { start() }
        updateDriveWakeups()
    }

    /// Significant-change monitoring lets iOS wake or relaunch the app when the phone starts moving,
    /// so drive detection can resume after the app was closed. Only possible with "Always".
    func setDriveWakeups(_ enabled: Bool) {
        wantsDriveWakeups = enabled
        updateDriveWakeups()
    }

    private func updateDriveWakeups() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        if wantsDriveWakeups && hasAlwaysAccess {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func addSampleObserver(_ receive: @escaping (LocationSample) -> Void) -> UUID {
        let id = UUID()
        sampleObservers[id] = receive
        return id
    }

    func removeSampleObserver(_ id: UUID) { sampleObservers[id] = nil }

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
        updateDriveWakeups()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        // Quality only, never coordinates (Console → subsystem org.cac.crashsafe, debug level).
        Self.log.debug("fix speed=\(latest.speed, privacy: .public) speedAcc=\(latest.speedAccuracy, privacy: .public) hAcc=\(latest.horizontalAccuracy, privacy: .public) course=\(latest.course, privacy: .public)")
        // Preserve measurement timestamps, including batched fixes. Never re-stamp old GPS as fresh.
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let sample = LocationSample(uptime: uptime + fix.timestamp.timeIntervalSince(now), date: fix.timestamp,
                                        latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                        horizontalAccuracy: fix.horizontalAccuracy,
                                        speedMPS: fix.speed, speedAccuracy: fix.speedAccuracy)
            for receive in Array(sampleObservers.values) { receive(sample) }
        }
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
        if let country = placemark.isoCountryCode {
            // US states come back as two-letter codes ("OR"); elsewhere the country alone is used.
            let state = placemark.administrativeArea.flatMap { $0.count == 2 ? $0.uppercased() : nil }
            regionCode = state.map { "\(country)-\($0)" } ?? country
        }
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
