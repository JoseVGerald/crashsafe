import Foundation
import Testing
@testable import CrashSafe

@MainActor
struct LiveCrashDetectorTests {
    @Test func realSensorAssessmentReachesExistingEventStream() async throws {
        let clock = TestSensorClock()
        let motion = TestMotionSource()
        let location = TestLocationSource()
        let hub = SensorHub(motion: motion, location: location, now: { clock.time }, useWatchdog: false)
        let detector = CoreMotionCrashDetector(sensors: hub, useWatchdog: false)
        detector.startMonitoring(carType: .sedan)
        for index in 0...560 {
            let time = 10 + Double(index) / 100
            clock.time = time
            if [100, 300, 400, 500].contains(index) {
                location.emit(LocationSample(uptime: time, date: Date(timeIntervalSince1970: time),
                                             latitude: 47, longitude: -122, horizontalAccuracy: 5,
                                             speedMPS: index < 200 ? 20 : 0, speedAccuracy: 0.5))
            }
            motion.emit(MotionSample(uptime: time, date: Date(timeIntervalSince1970: time),
                                     accelerationG: SensorVector(x: (200...204).contains(index) ? 4 : 0, y: 0, z: 0),
                                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
        }
        try #require(detector.lastAssessment?.decision == .suspectedCrash)
        // The stream buffers the result even before the UI listener resumes.
        var iterator = detector.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.isSimulated == false)
        #expect(event?.assessment?.evidence.contains(.speedLoss) == true)
        #expect(event?.speedDropMPH == 20 * 2.23694)
        detector.stopMonitoring()
        #expect(!hub.isRunning)
    }

    @Test func stopClearsPendingEvidenceAndPreservesOtherSensorConsumer() {
        let motion = TestMotionSource()
        let hub = SensorHub(motion: motion, location: TestLocationSource(), now: { 10 }, useWatchdog: false)
        let dashboard = UUID()
        hub.acquire(owner: dashboard, background: false)
        let detector = CoreMotionCrashDetector(sensors: hub, useWatchdog: false)
        detector.startMonitoring(carType: .motorcycle)
        motion.emit(MotionSample(uptime: 10, date: Date(), accelerationG: SensorVector(x: 8, y: 0, z: 0),
                                 gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))
        detector.stopMonitoring()
        #expect(hub.isRunning)
        #expect(!detector.submitCandidate(CrashCandidate(uptime: 10, date: Date(), transportationMode: .car)))
        detector.startMonitoring(carType: .sedan)
        #expect(detector.lastAssessment == nil)
        detector.stopMonitoring()
        hub.release(owner: dashboard)
        #expect(motion.stops == 1)
    }
}
