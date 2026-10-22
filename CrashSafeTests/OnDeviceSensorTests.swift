import CoreMotion
import Foundation
import Testing
@testable import CrashSafe

/// Runs only on a real iPhone (the simulator has no motion hardware): the exact path that crashed when
/// "Drive this car" started live sensors, and the live data the Sensor Lab shows. Quiet: no speech,
/// no siren, no alerts.
///
///     xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe -destination 'id=<device>' \
///       -only-testing:CrashSafeTests/OnDeviceSensorTests DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates
@MainActor
struct OnDeviceSensorTests {
    nonisolated static var hasHardware: Bool { CMMotionManager().isDeviceMotionAvailable }

    /// Core Motion calls back on its own queue ~100 times a second; before the fix, the first callback
    /// trapped (dispatch_assert_queue_fail) and the app crashed.
    @Test(.enabled(if: hasHardware)) func realMotionReachesTheMainActorAtAbout100Hz() async throws {
        let source = CoreMotionSource()
        var samples: [MotionSample] = []
        source.start(interval: 0.01) { sample, _ in
            MainActor.assertIsolated()
            if let sample { samples.append(sample) }
        }
        try await Task.sleep(for: .seconds(2))
        source.stop()
        let count = samples.count
        #expect(count >= 150, "got \(count) samples in 2 s")
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1.uptime > $0.uptime })
        let gravity = samples.map(\.gravityG.magnitude)
        #expect(gravity.allSatisfy { (0.95...1.05).contains($0) })
        // Lying still (or held), user acceleration is small and the tilt is defined.
        #expect(SensorLabMath.tilt(gravity: try #require(samples.last).gravityG) != nil)
        let measuredHz = Double(count - 1) / (samples.last!.uptime - samples.first!.uptime)
        #expect(measuredHz > 80, "measured \(measuredHz) Hz")
    }

    /// What "Drive this car" does: a live drive plus crash monitoring on the shared sensor hub.
    @Test(.enabled(if: hasHardware)) func liveDriveAndCrashMonitoringRunOnRealSensors() async throws {
        let hub = SensorHub(location: TestLocationSource())
        let driving = DrivingMonitor(sensors: hub)
        let detector = CoreMotionCrashDetector(sensors: hub)
        var readings = 0
        _ = hub.addObserver { if case .motion = $0 { readings += 1 } }
        driving.startLive(background: false)
        detector.startMonitoring(carType: .sedan)
        try await Task.sleep(for: .seconds(2))
        #expect(hub.health.state == .active)
        #expect(hub.health.measuredHz > 80)
        #expect(readings >= 150)
        #expect(detector.lastAssessment == nil) // sitting still is never a crash
        detector.stopMonitoring()
        driving.stop()
        #expect(!hub.isRunning)
    }

    /// The Sensor Lab on real sensors: live samples, then a replayed clip in their place, then live again.
    @Test(.enabled(if: hasHardware)) func sensorLabShowsLiveMotionAndReplaysOverIt() async throws {
        let replay = ReplayMotionSource()
        let hub = SensorHub(motion: replay, location: TestLocationSource())
        replay.onFinish = { [weak hub] in hub?.motionSourceChanged() }
        let lab = SensorLabModel(sensors: hub, replay: replay)
        lab.start()
        try await Task.sleep(for: .seconds(1))
        let live = try #require(lab.latest)
        #expect(abs(live.gravityG.magnitude - 1) < 0.05)
        #expect(lab.tilt != nil)
        var rng = SeededGenerator(seed: 4)
        let crash = ScenarioFactory().make(.frontalCrash, rng: &rng)
        // Just the 1.5 s around the impact, so the test stays short.
        let window = crash.readings.filter { abs($0.uptime - crash.eventUptime) < 0.75 }
        replay.play(.init(title: "test", readings: window)) { hub.motionSourceChanged() }
        try await Task.sleep(for: .seconds(1))
        #expect(lab.peakG > 3) // the replayed hit, not the phone on the desk
        try await Task.sleep(for: .seconds(1.2))
        #expect(!lab.isReplaying)
        #expect(hub.health.state == .active) // live sensors resumed
        lab.stop()
        #expect(!hub.isRunning)
    }
}
