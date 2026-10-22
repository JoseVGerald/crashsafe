import Foundation
import Observation
import UIKit

/// Owns the "Are you OK?" check-in from the moment a crash is detected, independent of any screen.
/// The countdown starts immediately — with the phone locked in a pocket there may be no view to
/// start it — and a lock-screen notification asks the driver to answer. The full-screen
/// `CheckInView` shows this same view model when the app is open.
@Observable
final class CrashResponseCenter {
    private(set) var current: CheckInViewModel?
    /// The siren is sounding (no answer). The driver or a bystander can stop it.
    private(set) var isSirenOn = false
    /// A 911 call was started (iOS shows its own "Call 911" confirmation).
    private(set) var startedEmergencyCall = false
    /// How many times the driver has been asked "Are you okay?" in this check-in.
    private(set) var promptsSpoken = 0

    /// The driver's family contacts, read when a crash happens (owner ID → recipients).
    @ObservationIgnored var recipientsProvider: (String) -> [AlertRecipient] = { _ in [] }
    /// Saves the outcome (owner ID, event, outcome).
    @ObservationIgnored var recordOutcome: (String, CrashEvent, CheckInOutcome) -> Void = { _, _, _ in }
    /// Asks iOS for time to finish the countdown and family alert even if the app would otherwise be
    /// suspended; returns the call that releases it.
    @ObservationIgnored var keepAlive: @MainActor (String) -> (() -> Void) = { CrashResponseCenter.backgroundTask(named: $0) }

    @ObservationIgnored private let alerts: any EmergencyAlertService
    @ObservationIgnored private let notifier: any CrashNotifying
    @ObservationIgnored private let alarm: any CrashAlarm
    @ObservationIgnored private let dialer: any EmergencyDialer
    @ObservationIgnored private let isOnline: () -> Bool
    @ObservationIgnored private let duration: Int
    @ObservationIgnored private let tick: Duration

    init(alerts: any EmergencyAlertService, notifier: any CrashNotifying, isOnline: @escaping () -> Bool,
         alarm: any CrashAlarm = SilentCrashAlarm(), dialer: any EmergencyDialer = NoEmergencyDialer(),
         duration: Int = 30, tick: Duration = .seconds(1)) {
        self.alerts = alerts
        self.notifier = notifier
        self.alarm = alarm
        self.dialer = dialer
        self.isOnline = isOnline
        self.duration = duration
        self.tick = tick
    }

    var isCounting: Bool { current?.phase == .counting }

    /// Starts the check-in for `event`. While one is still counting down, a second event is ignored.
    @discardableResult
    func begin(_ event: CrashEvent, ownerID: String) -> CheckInViewModel {
        if let current, current.phase == .counting { return current }
        let recipients = recipientsProvider(ownerID)
        let viewModel = CheckInViewModel(event: event, recipients: recipients, alerts: alerts,
                                         isOnline: isOnline, duration: duration, tick: tick)
        let release = keepAlive("Crash check-in")
        isSirenOn = false
        startedEmergencyCall = false
        promptsSpoken = 0
        viewModel.onTick = { [weak self] remaining in self?.prompt(remaining: remaining) }
        viewModel.onResolve = { [weak self, notifier, weak viewModel] outcome in
            self?.escalate(outcome, event: event)
            notifier.withdrawCheckIn(for: event)
            if let text = Self.followUp(for: outcome, recipients: recipients) {
                notifier.postFollowUp(text, for: event)
            }
            self?.recordOutcome(ownerID, event, outcome)
            // Hold on until the family alert (if any) has gone out.
            Task {
                while viewModel?.isAlerting == true { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(2))
                release()
            }
        }
        current = viewModel
        viewModel.start()
        notifier.postCheckIn(for: event, secondsToRespond: duration, contactSummary: Self.summary(of: recipients))
        prompt(remaining: duration)
        return viewModel
    }

    /// "Are you okay?" every 5 seconds until the driver answers or time runs out.
    private func prompt(remaining: Int) {
        guard current?.phase == .counting, remaining > 0, remaining % 5 == 0 else { return }
        promptsSpoken += 1
        alarm.say(Self.promptText(remaining: remaining))
    }

    static let okLine = "Okay. I'm glad you're okay."
    static let helpLine = "Getting you help."

    static func promptText(remaining: Int) -> String {
        switch remaining {
        case 10: "Are you okay? If you don't answer in 10 seconds, I'll sound an alarm and call for help."
        case ...5: "Are you okay? \(remaining) seconds."
        default: "Are you okay? Tap I'm OK if you're all right."
        }
    }

    /// No answer: siren for anyone nearby, family alerted (by the check-in), and the 911 call started.
    /// "I need help": the 911 call started and family alerted. Test crashes never start a 911 call.
    private func escalate(_ outcome: CheckInOutcome, event: CrashEvent) {
        alarm.stopAll()
        switch outcome {
        case .ok:
            alarm.say(Self.okLine)
        case .needsHelp:
            alarm.say(Self.helpLine)
            if !event.isSimulated {
                dialer.call911()
                startedEmergencyCall = true
            }
        case .noResponse:
            alarm.startSiren()
            isSirenOn = true
            if !event.isSimulated {
                dialer.call911()
                startedEmergencyCall = true
            }
        }
    }

    func stopSiren() {
        alarm.stopSiren()
        isSirenOn = false
    }

    func startSiren() {
        alarm.startSiren()
        isSirenOn = true
    }

    /// An answer from the lock screen (or anywhere outside the check-in screen).
    func respond(_ outcome: CheckInOutcome) {
        current?.respond(outcome)
    }

    /// The driver closed the help hub; forget the finished check-in.
    func dismiss() {
        guard current?.phase != .counting else { return }
        stopSiren()
        current = nil
    }

    static func backgroundTask(named name: String) -> (() -> Void) {
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) { token.end() }
        return { token.end() }
    }

    static func summary(of recipients: [AlertRecipient]) -> String? {
        let names = recipients.map(\.name)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "your \(names.count) family contacts"
        }
    }

    /// What to tell a driver who may not be looking at the screen once the check-in resolves.
    static func followUp(for outcome: CheckInOutcome, recipients: [AlertRecipient]) -> String? {
        guard outcome != .ok else { return nil }
        guard let who = summary(of: recipients) else {
            return "No family contacts saved. Call 911 if anyone is hurt."
        }
        return outcome == .noResponse
            ? "No answer, so we're alerting \(who) with your location."
            : "Alerting \(who) with your location. Call 911 if anyone is hurt."
    }
}

/// One `beginBackgroundTask` grant, ended exactly once (by the caller or by iOS's expiration handler).
@MainActor
private final class BackgroundTaskToken {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// For tests and previews: says nothing, no siren.
@MainActor
final class SilentCrashAlarm: CrashAlarm {
    private(set) var spoken: [String] = []
    private(set) var isSirenOn = false
    func say(_ text: String) { spoken.append(text) }
    func startSiren() { isSirenOn = true }
    func stopSiren() { isSirenOn = false }
    func stopAll() { isSirenOn = false }
}

@MainActor
final class NoEmergencyDialer: EmergencyDialer {
    private(set) var calls = 0
    func call911() { calls += 1 }
}
