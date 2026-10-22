import Foundation
import Testing
@testable import CrashSafe

@MainActor
struct SensorHubTests {
    @Test func consumersShareOneSessionAndReleaseIndependently() {
        let motion = TestMotionSource()
        let location = TestLocationSource()
        let hub = SensorHub(motion: motion, location: location, now: { 10 }, useWatchdog: false)
        let driver = UUID(), detector = UUID()
        var dashboardSamples = 0, detectorSamples = 0
        let a = hub.addObserver { _ in dashboardSamples += 1 }
        _ = hub.addObserver { _ in detectorSamples += 1 }
        hub.acquire(owner: driver, background: false)
        hub.acquire(owner: detector, background: true)
        #expect(motion.starts == 1)
        #expect(motion.interval == 0.01)
        #expect(location.background)
        motion.emit(sample(10))
        #expect(dashboardSamples == 1 && detectorSamples == 1)
        hub.removeObserver(a)
        hub.release(owner: driver)
        #expect(hub.isRunning && location.background)
        motion.emit(sample(10.01))
        #expect(dashboardSamples == 1 && detectorSamples == 2)
        hub.release(owner: detector)
        #expect(!hub.isRunning && !location.background && motion.stops == 1)
        #expect(location.observers.isEmpty)
    }

    @Test func rejectsInvalidDuplicateOutOfOrderAndOldSamples() {
        let motion = TestMotionSource()
        let hub = SensorHub(motion: motion, location: TestLocationSource(), now: { 10 }, useWatchdog: false)
        hub.acquire(owner: UUID(), background: false)
        var received = 0
        _ = hub.addObserver { _ in received += 1 }
        motion.emit(sample(9.9))
        motion.emit(sample(9.9))
        motion.emit(sample(9.8))
        motion.emit(sample(8))
        motion.emit(sample(11))
        var invalid = sample(10)
        invalid.rotationRate.x = .nan
        motion.emit(invalid)
        #expect(received == 1)
        #expect(hub.health.rejectedMotionSamples == 5)
    }

    @Test func staleStreamRecoversAndReportsGap() {
        let clock = TestSensorClock()
        let motion = TestMotionSource()
        let hub = SensorHub(motion: motion, location: TestLocationSource(), now: { clock.time }, useWatchdog: false)
        hub.acquire(owner: UUID(), background: false)
        motion.emit(sample(10))
        clock.time = 11
        hub.checkFreshness()
        #expect(hub.health.state == .stale)
        motion.emit(sample(11))
        #expect(hub.health.state == .active && hub.health.motionGaps == 1)
    }

    @Test func unavailableAndDeniedMotionAreVisible() {
        let motion = TestMotionSource()
        motion.isAvailable = false
        let hub = SensorHub(motion: motion, location: TestLocationSource(), useWatchdog: false)
        let owner = UUID()
        hub.acquire(owner: owner, background: false)
        #expect(hub.health.state == .unavailable && motion.starts == 0)
        hub.release(owner: owner)
        motion.isAvailable = true
        hub.acquire(owner: owner, background: false)
        motion.receive?(nil, true)
        #expect(hub.health.state == .permissionDenied)
        hub.release(owner: owner)
    }

    @Test func gpsFixesRetainQualityAndFanOut() {
        let location = TestLocationSource()
        let hub = SensorHub(motion: TestMotionSource(), location: location, now: { 10 }, useWatchdog: false)
        hub.acquire(owner: UUID(), background: false)
        var received: [LocationSample] = []
        _ = hub.addObserver { if case .location(let fix) = $0 { received.append(fix) } }
        let fix = LocationSample(uptime: 9, date: Date(), latitude: 47, longitude: -122,
                                 horizontalAccuracy: 5, speedMPS: 15, speedAccuracy: 1)
        location.emit(fix)
        location.emit(fix)
        #expect(received == [fix])
        #expect(hub.health.rejectedLocationSamples == 1)
    }

    @Test func watchdogDoesNotTurnUnreliableGpsIntoReliableGps() {
        let location = TestLocationSource()
        let hub = SensorHub(motion: TestMotionSource(), location: location, now: { 10 }, useWatchdog: false)
        hub.acquire(owner: UUID(), background: false)
        location.emit(LocationSample(uptime: 10, date: Date(), latitude: 47, longitude: -122,
                                     horizontalAccuracy: 5, speedMPS: 20, speedAccuracy: -1))
        #expect(hub.health.locationUnavailable)
        hub.checkFreshness()
        #expect(hub.health.locationUnavailable)
    }

    private func sample(_ time: Double) -> MotionSample {
        MotionSample(uptime: time, date: Date(timeIntervalSince1970: time), accelerationG: .zero,
                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)
    }
}

@MainActor
final class TestSensorClock { var time = 10.0 }

@MainActor
final class TestMotionSource: MotionSource {
    var isAvailable = true
    var starts = 0, stops = 0
    var interval = 0.0
    var receive: (@MainActor (MotionSample?, Bool) -> Void)?
    func start(interval: TimeInterval, receive: @escaping @MainActor (MotionSample?, Bool) -> Void) {
        starts += 1
        self.interval = interval
        self.receive = receive
    }
    func stop() { stops += 1; receive = nil }
    func emit(_ sample: MotionSample) { receive?(sample, false) }
}

@MainActor
final class TestLocationSource: LocationSampleSource {
    var isDenied = false
    var background = false
    var observers: [UUID: (LocationSample) -> Void] = [:]
    func addSampleObserver(_ receive: @escaping (LocationSample) -> Void) -> UUID {
        let id = UUID(); observers[id] = receive; return id
    }
    func removeSampleObserver(_ id: UUID) { observers[id] = nil }
    func start() {}
    func setBackgroundUpdates(_ enabled: Bool) { background = enabled }
    func emit(_ sample: LocationSample) { for receive in Array(observers.values) { receive(sample) } }
}
