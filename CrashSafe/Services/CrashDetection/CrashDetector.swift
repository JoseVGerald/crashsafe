import Foundation
import Observation

/// A possible crash, as reported by a `CrashDetector`.
struct CrashEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    /// Peak acceleration in g. Real detectors read this from Core Motion.
    let peakG: Double
    /// Drop in GPS speed around the impact, in mph.
    let speedDropMPH: Double
    let isSimulated: Bool
}

/// Watches sensors during an active trip and emits `CrashEvent`s.
///
/// DETECTION TEAM: implement a `CoreMotionCrashDetector` that conforms to this
/// (motion + GPS speed drop, tuned by `carType`) and swap it in `AppEnvironment.live()`.
protocol CrashDetector: AnyObject {
    var isMonitoring: Bool { get }
    /// Single stream of detected crashes for the lifetime of the app.
    var events: AsyncStream<CrashEvent> { get }
    func startMonitoring(carType: CarType)
    func stopMonitoring()
    /// Demo hook: emits a fake event so the check-in flow can be shown without crashing a car.
    func simulateCrash()
}

/// Never detects anything on its own; only `simulateCrash()` emits events.
@Observable
final class MockCrashDetector: CrashDetector {
    private(set) var isMonitoring = false
    @ObservationIgnored let events: AsyncStream<CrashEvent>
    @ObservationIgnored private let continuation: AsyncStream<CrashEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: CrashEvent.self, bufferingPolicy: .bufferingNewest(1))
    }

    func startMonitoring(carType: CarType) {
        isMonitoring = true
    }

    func stopMonitoring() {
        isMonitoring = false
    }

    func simulateCrash() {
        continuation.yield(CrashEvent(date: .now, peakG: 6.2, speedDropMPH: 38, isSimulated: true))
    }
}
