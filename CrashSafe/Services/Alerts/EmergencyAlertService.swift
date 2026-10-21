import Foundation

struct AlertRecipient: Sendable, Equatable {
    let name: String
    let phone: String
}

enum AlertDelivery: Sendable, Equatable {
    case sent
    /// No signal — will be sent when the phone reconnects.
    case queued
}

/// Notifies family contacts after a crash (unconscious path, or "I need help").
///
/// iOS can't send texts silently, so the real version is a push/SMS through our backend
/// when online and a persisted queue when offline. 911 stays with Apple's built-in Crash Detection.
protocol EmergencyAlertService: AnyObject {
    func alertFamily(_ recipients: [AlertRecipient], outcome: CheckInOutcome, event: CrashEvent, isOnline: Bool) async -> AlertDelivery
}

/// Pretends to send; reports `.queued` when offline.
final class MockEmergencyAlertService: EmergencyAlertService {
    func alertFamily(_ recipients: [AlertRecipient], outcome: CheckInOutcome, event: CrashEvent, isOnline: Bool) async -> AlertDelivery {
        try? await Task.sleep(for: .seconds(1))
        return isOnline ? .sent : .queued
    }
}
