import Foundation
import Observation

/// Something that can ask iOS to wake the app when the phone starts moving (significant location changes).
@MainActor
protocol DriveWakeupSource: AnyObject {
    func setDriveWakeups(_ enabled: Bool)
}

extension LocationService: DriveWakeupSource {}

/// "Watch every drive": when Core Motion reports a drive, start the driving monitor *and* crash
/// detection, and stop only what it started when the drive ends (a trip the driver started by hand is
/// left alone). The armed state is saved, so when iOS relaunches a closed app for a location event —
/// with no screen on display — `resumeIfArmed()` brings detection back without any view appearing.
@MainActor
@Observable
final class BackgroundDriveWatcher {
    nonisolated struct Configuration: Codable, Equatable, Sendable {
        var ownerID: String
        var carType: CarType
    }

    private(set) var configuration: Configuration?
    private(set) var startedDriving = false
    private(set) var startedDetection = false

    @ObservationIgnored private let driving: DrivingMonitor
    @ObservationIgnored private let crashDetector: any CrashDetector
    @ObservationIgnored private let wakeups: any DriveWakeupSource
    @ObservationIgnored private let autoDetector: DriveAutoDetector?
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "driveWatcher.configuration"

    init(driving: DrivingMonitor, crashDetector: any CrashDetector, wakeups: any DriveWakeupSource,
         autoDetector: DriveAutoDetector?, defaults: UserDefaults = .standard) {
        self.driving = driving
        self.crashDetector = crashDetector
        self.wakeups = wakeups
        self.autoDetector = autoDetector
        self.defaults = defaults
    }

    var isArmed: Bool { configuration != nil }

    /// Watch every drive for this driver and car. Saved so a background relaunch can resume.
    func arm(_ configuration: Configuration) {
        self.configuration = configuration
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.storageKey) }
        wakeups.setDriveWakeups(true)
        guard let autoDetector else { return }
        autoDetector.onDriveStarted = { [weak self] in self?.driveStarted() }
        autoDetector.onDriveEnded = { [weak self] in self?.driveEnded() }
        autoDetector.start()
    }

    /// Stop watching (setting turned off, or signed out).
    func disarm() {
        configuration = nil
        defaults.removeObject(forKey: Self.storageKey)
        wakeups.setDriveWakeups(false)
        autoDetector?.stop()
        driveEnded()
    }

    /// Call on every launch, including a background relaunch for a location event.
    func resumeIfArmed() {
        guard configuration == nil,
              let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(Configuration.self, from: data) else { return }
        arm(saved)
    }

    func driveStarted() {
        guard let configuration else { return }
        if !driving.isActive {
            driving.startLive(background: true)
            startedDriving = true
        }
        if !crashDetector.isMonitoring {
            crashDetector.startMonitoring(carType: configuration.carType)
            startedDetection = true
        }
    }

    func driveEnded() {
        if startedDetection {
            crashDetector.stopMonitoring()
            startedDetection = false
        }
        if startedDriving {
            if driving.mode == .live { driving.stop() }
            startedDriving = false
        }
    }
}
