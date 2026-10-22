import Foundation
import Observation
import Testing
@testable import CrashSafe

/// Counts how often an observed value changes (each change redraws every screen that shows it).
nonisolated final class ObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var changes = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return changes }

    /// Starts watching `read` unless a watch is already waiting for the next change.
    @MainActor func watch(_ read: () -> Void) {
        lock.lock()
        let already = armed
        armed = true
        lock.unlock()
        guard !already else { return }
        withObservationTracking(read) { [self] in
            lock.lock(); armed = false; changes += 1; lock.unlock()
        }
    }
}

/// On a phone the motion sensors deliver 100 readings a second while the app is open (activity
/// sensing). Writing an observed value on every reading made Home, Profile and CarPlay redraw 100 times
/// a second ("the lag is insane" on Profile); the simulator has no motion sensor, so it never showed.
@MainActor
struct RedrawTests {
    @Test func steadyMotionDoesNotRedrawScreensThatShowSensorHealth() {
        let clock = TestSensorClock()
        let motion = TestMotionSource()
        let hub = SensorHub(motion: motion, location: TestLocationSource(), now: { clock.time }, useWatchdog: false)
        hub.acquire(owner: UUID(), background: false)
        let probe = ObservationProbe()
        for i in 0..<300 { // 3 s at 100 Hz
            probe.watch { _ = hub.health }
            clock.time = 10 + Double(i) / 100
            motion.emit(MotionSample(uptime: clock.time, date: .now, accelerationG: SensorVector(x: 0.01, y: 0, z: 0),
                                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
        }
        #expect(hub.health.state == .active && hub.health.measuredHz > 90)
        #expect(probe.count <= 3, "health changed \(probe.count) times in 3 s") // starting → active, then the rate
    }

    @Test func liveDriveUpdatesTheScreenTenTimesASecondAndKeepsPeaks() {
        let clock = TestSensorClock()
        let motion = TestMotionSource()
        let hub = SensorHub(motion: motion, location: TestLocationSource(), now: { clock.time }, useWatchdog: false)
        let driving = DrivingMonitor(sensors: hub)
        driving.startLive(background: false)
        let probe = ObservationProbe()
        for i in 0..<100 { // 1 s at 100 Hz, a one-sample 3 g jolt in the middle
            probe.watch { _ = driving.snapshot.currentG; _ = driving.gHistory }
            clock.time = 10 + Double(i) / 100
            let g = i == 55 ? 3.0 : 0.05 + 0.01 * Double(i % 3)
            motion.emit(MotionSample(uptime: clock.time, date: .now, accelerationG: SensorVector(x: g, y: 0, z: 0),
                                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
        }
        #expect(probe.count <= 15, "the drive screen changed \(probe.count) times in 1 s") // ~10 updates + new peaks; was 100
        #expect(driving.snapshot.peakG == 3)
        #expect(driving.gHistory.contains(3)) // the jolt still reaches the sparkline
        driving.stop()
    }
}
