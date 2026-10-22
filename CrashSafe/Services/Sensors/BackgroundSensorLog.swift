import Foundation
import os
import UIKit

/// Whether the app is off screen and whether the phone is locked, read live from iOS on each reading.
/// (Not cached from transition notifications: after a background relaunch there is no transition to see.)
@MainActor
enum AppState {
    static func current() -> (background: Bool, locked: Bool) {
        let app = UIApplication.shared
        // Protected data goes away a few seconds after locking (needs a passcode, which nearly every phone has).
        return (app.applicationState != .active, !app.isProtectedDataAvailable)
    }
}

/// Proof that sensors keep running off screen: readings received while the app was in the background
/// and while the phone was locked, with the longest motion gap. Counts only — no readings are stored.
nonisolated struct BackgroundSensorLog: Codable, Equatable, Sendable {
    var since = Date()
    var backgroundMotion = 0
    var backgroundLocation = 0
    var lockedMotion = 0
    var lockedLocation = 0
    /// Longest gap between motion readings while off screen, in seconds.
    var longestBackgroundGap: Double = 0
    var lastBackgroundReading: Date?

    var isEmpty: Bool { backgroundMotion == 0 && backgroundLocation == 0 }

    mutating func record(motion: Bool, uptimeGap: Double?, background: Bool, locked: Bool, at date: Date) {
        guard background || locked else { return }
        if motion {
            backgroundMotion += 1
            if locked { lockedMotion += 1 }
            if let uptimeGap { longestBackgroundGap = max(longestBackgroundGap, uptimeGap) }
        } else {
            backgroundLocation += 1
            if locked { lockedLocation += 1 }
        }
        lastBackgroundReading = date
    }

    /// Written next to the app's data so a developer can pull it off a test phone
    /// (`xcrun devicectl device copy from --domain-type appDataContainer`).
    static var fileURL: URL {
        URL.documentsDirectory.appending(path: "background-sensor-log.json")
    }

    /// The counts from before the app was closed or relaunched in the background.
    static func load() -> BackgroundSensorLog? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BackgroundSensorLog.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static let logger = Logger(subsystem: "org.cac.crashsafe", category: "background-sensors")
}
