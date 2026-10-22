import Foundation
import Testing
@testable import CrashSafe

@MainActor
struct SensorLabReplayTests {
    /// A replayed crash in the Sensor Lab must not start a real check-in unless the tester opts in.
    @Test func crashDetectorIgnoresReadingsWhileSuppressed() {
        let clock = TestSensorClock()
        let motion = TestMotionSource()
        let location = TestLocationSource()
        let hub = SensorHub(motion: motion, location: location, now: { clock.time }, useWatchdog: false)
        var suppressed = true
        let detector = CoreMotionCrashDetector(sensors: hub, useWatchdog: false, ignoreReadings: { suppressed })
        detector.startMonitoring(carType: .sedan)
        func drive(from start: Double) {
            for index in 0...560 {
                let time = start + Double(index) / 100
                clock.time = time
                if [100, 300, 400, 500].contains(index) {
                    location.emit(LocationSample(uptime: time, date: Date(timeIntervalSince1970: time), latitude: 47, longitude: -122,
                                                 horizontalAccuracy: 5, speedMPS: index < 200 ? 20 : 0, speedAccuracy: 0.5))
                }
                motion.emit(MotionSample(uptime: time, date: Date(timeIntervalSince1970: time),
                                         accelerationG: SensorVector(x: (200...204).contains(index) ? 4 : 0, y: 0, z: 0),
                                         gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
            }
        }
        drive(from: 10)
        #expect(detector.lastAssessment == nil)
        suppressed = false
        drive(from: 30)
        #expect(detector.lastAssessment?.decision == .suspectedCrash)
        detector.stopMonitoring()
    }

    /// With no motion hardware (the simulator), a clip still reaches the hub, which goes back to
    /// "unavailable" afterward instead of reporting a stale sensor.
    @Test func replayFeedsAHubWithoutHardware() async throws {
        let hardware = TestMotionSource()
        hardware.isAvailable = false
        let replay = ReplayMotionSource(live: hardware)
        let hub = SensorHub(motion: replay, location: TestLocationSource(), useWatchdog: false)
        replay.onFinish = { [weak hub] in hub?.motionSourceChanged() }
        var received = 0
        _ = hub.addObserver { if case .motion = $0 { received += 1 } }
        let owner = UUID()
        hub.acquire(owner: owner, background: false)
        #expect(hub.health.state == .unavailable)
        var rng = SeededGenerator(seed: 3)
        let scenario = ScenarioFactory().make(.pothole, rng: &rng)
        let clip = ReplayMotionSource.Clip(title: "test", readings: Array(scenario.readings.prefix(30)))
        replay.play(clip) { hub.motionSourceChanged() }
        #expect(replay.isReplaying)
        try await Task.sleep(for: .milliseconds(700))
        #expect(received >= 25)
        #expect(!replay.isReplaying)
        #expect(hub.health.state == .unavailable)
        hub.release(owner: owner)
    }

    @Test func labPausesLiveMotionDuringReplayAndResumesAfter() async throws {
        let hardware = TestMotionSource()
        let replay = ReplayMotionSource(live: hardware)
        let hub = SensorHub(motion: replay, location: TestLocationSource(), useWatchdog: false)
        let owner = UUID()
        hub.acquire(owner: owner, background: false)
        #expect(hardware.starts == 1)
        let clip = ReplayMotionSource.Clip(title: "still", readings: (0..<10).map {
            .motion(MotionSample(uptime: Double($0) / 100, date: .now, accelerationG: .zero, gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
        })
        replay.play(clip) { hub.motionSourceChanged() }
        #expect(hardware.receive == nil) // live readings paused
        try await Task.sleep(for: .milliseconds(400))
        #expect(hardware.starts == 2 && hardware.receive != nil) // and back
        hub.release(owner: owner)
    }
}

struct VoiceClipTests {
    /// Every line the check-in speaks has a natural pre-recorded clip in the app bundle.
    @Test @MainActor func everyCheckInLineHasABundledNaturalVoiceClip() throws {
        var spoken = Set(stride(from: 60, through: 5, by: -5).map(CrashResponseCenter.promptText(remaining:)))
        spoken.insert(CrashResponseCenter.okLine)
        spoken.insert(CrashResponseCenter.helpLine)
        for line in spoken {
            let url = try #require(PulseVoiceClips.url(for: line), "no clip for “\(line)”")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 5_000)
        }
        #expect(PulseVoiceClips.url(for: "Slow to 55 mph") == nil) // dynamic text still uses the system voice
    }
}
