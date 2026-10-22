import Foundation
import UserNotifications

/// Lock-screen side of the crash check-in. The countdown itself runs in `CrashResponseCenter`;
/// this only tells a driver who isn't looking at the app that it's waiting for an answer.
protocol CrashNotifying: AnyObject {
    func postCheckIn(for event: CrashEvent, secondsToRespond: Int, contactSummary: String?)
    func withdrawCheckIn(for event: CrashEvent)
    func postFollowUp(_ text: String, for event: CrashEvent)
}

/// Identifiers shared by the notifier and the notification delegate.
nonisolated enum CrashNotification {
    static let category = "CRASH_CHECKIN"
    static let okAction = "CRASH_OK"
    static let helpAction = "CRASH_HELP"

    static func checkInID(_ eventID: UUID) -> String { "crash-\(eventID.uuidString)" }
    static func followUpID(_ eventID: UUID) -> String { "crash-\(eventID.uuidString)-followup" }

    /// The answer a notification action stands for; nil for a plain tap (just opens the app).
    static func outcome(forAction identifier: String) -> CheckInOutcome? {
        switch identifier {
        case okAction: .ok
        case helpAction: .needsHelp
        default: nil
        }
    }

    /// "I'm OK" works from the lock screen without unlocking; "I need help" opens the app to the help hub.
    static var categories: Set<UNNotificationCategory> {
        let ok = UNNotificationAction(identifier: okAction, title: "I'm OK", options: [])
        let help = UNNotificationAction(identifier: helpAction, title: "I need help", options: [.foreground, .destructive])
        return [UNNotificationCategory(identifier: category, actions: [ok, help], intentIdentifiers: [],
                                       options: [.customDismissAction])]
    }
}

/// Posts local notifications through `UNUserNotificationCenter`.
final class LocalCrashNotifier: CrashNotifying {
    private let center = UNUserNotificationCenter.current()

    func postCheckIn(for event: CrashEvent, secondsToRespond: Int, contactSummary: String?) {
        let content = UNMutableNotificationContent()
        content.title = event.isSimulated ? "Test crash — are you OK?" : "Possible crash detected"
        content.body = contactSummary.map {
            "Are you OK? If you don't answer in \(secondsToRespond) seconds, we'll alert \($0) with your location."
        } ?? "Are you OK? If you don't answer in \(secondsToRespond) seconds, we'll treat it as an emergency."
        content.categoryIdentifier = CrashNotification.category
        content.sound = .defaultCritical // falls back to the default sound without the critical-alert entitlement
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        add(content, id: CrashNotification.checkInID(event.id))
    }

    func withdrawCheckIn(for event: CrashEvent) {
        let id = CrashNotification.checkInID(event.id)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func postFollowUp(_ text: String, for event: CrashEvent) {
        let content = UNMutableNotificationContent()
        content.title = "CrashSafe"
        content.body = text
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        add(content, id: CrashNotification.followUpID(event.id))
    }

    private func add(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Receives notification taps and actions. Set as the notification center's delegate at launch,
/// so an answer from the lock screen reaches the running countdown.
nonisolated final class CrashNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Called on the main actor with the driver's answer (nil = they just tapped the banner).
    let onResponse: @MainActor @Sendable (CheckInOutcome?) -> Void
    /// While the app is on screen the full-screen check-in is already showing, so skip the banner.
    let isAppActive: @MainActor @Sendable () -> Bool

    init(onResponse: @escaping @MainActor @Sendable (CheckInOutcome?) -> Void,
         isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.onResponse = onResponse
        self.isAppActive = isAppActive
    }

    // Completion-handler versions, finished on the main thread. UIKit asserts that these completions run
    // on main; the `async` versions finish on a background executor and crashed the app when the driver
    // answered from the lock screen.

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isCheckIn = notification.request.content.categoryIdentifier == CrashNotification.category
        let done = MainThreadCompletion(completionHandler)
        DispatchQueue.main.async { [isAppActive] in
            let active = MainActor.assumeIsolated { isAppActive() }
            // On screen, the full-screen check-in is already up: skip the banner, but keep it in Notification
            // Center so it's still on the lock screen if the driver locks the phone mid-countdown.
            done.call(isCheckIn && active ? [.list] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isCheckIn = response.notification.request.content.categoryIdentifier == CrashNotification.category
        let outcome = CrashNotification.outcome(forAction: response.actionIdentifier)
        let done = MainThreadCompletion<Void>({ _ in completionHandler() })
        DispatchQueue.main.async { [onResponse] in
            if isCheckIn { MainActor.assumeIsolated { onResponse(outcome) } }
            done.call(())
        }
    }
}

/// Carries a system completion handler to the main queue, where it is called exactly once.
nonisolated final class MainThreadCompletion<Value>: @unchecked Sendable {
    private var body: ((Value) -> Void)?

    init(_ body: @escaping (Value) -> Void) { self.body = body }

    /// Main thread only.
    func call(_ value: Value) {
        dispatchPrecondition(condition: .onQueue(.main))
        body?(value)
        body = nil
    }
}
