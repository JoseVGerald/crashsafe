import Foundation
import Observation

/// Drives the "Are you OK?" countdown and decides which path the driver takes.
@Observable
final class CheckInViewModel {
    enum Phase: Equatable {
        case counting
        case resolved(CheckInOutcome)
    }

    let event: CrashEvent
    let duration: Int
    let recipients: [AlertRecipient]
    private(set) var secondsRemaining: Int
    private(set) var phase: Phase = .counting
    private(set) var isAlerting = false
    private(set) var alertDelivery: AlertDelivery?

    /// Called once, when the driver answers or the countdown runs out.
    @ObservationIgnored var onResolve: ((CheckInOutcome) -> Void)?
    @ObservationIgnored private let alerts: any EmergencyAlertService
    @ObservationIgnored private let isOnline: () -> Bool
    @ObservationIgnored private let tick: Duration
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(event: CrashEvent,
         recipients: [AlertRecipient],
         alerts: any EmergencyAlertService,
         isOnline: @escaping () -> Bool,
         duration: Int = 30,
         tick: Duration = .seconds(1)) {
        self.event = event
        self.recipients = recipients
        self.alerts = alerts
        self.isOnline = isOnline
        self.duration = duration
        self.tick = tick
        self.secondsRemaining = duration
    }

    var progress: Double {
        duration == 0 ? 0 : Double(secondsRemaining) / Double(duration)
    }

    func start() {
        guard timer == nil, phase == .counting else { return }
        timer = Task { [weak self] in
            while let self, self.secondsRemaining > 0 {
                try? await Task.sleep(for: self.tick)
                guard !Task.isCancelled else { return }
                self.secondsRemaining -= 1
            }
            self?.resolve(.noResponse)
        }
    }

    func respond(_ outcome: CheckInOutcome) {
        resolve(outcome)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func resolve(_ outcome: CheckInOutcome) {
        guard phase == .counting else { return }
        stop()
        phase = .resolved(outcome)
        onResolve?(outcome)
        if outcome != .ok, !recipients.isEmpty {
            Task { await sendAlerts(for: outcome) }
        }
    }

    private func sendAlerts(for outcome: CheckInOutcome) async {
        isAlerting = true
        alertDelivery = await alerts.alertFamily(recipients, outcome: outcome, event: event, isOnline: isOnline())
        isAlerting = false
    }
}
