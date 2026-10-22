import Foundation
import Testing
@testable import CrashDetectionCore

struct SensorTypesTests {
    @Test func physicalUnitsAndGravityArePreserved() {
        let motion = MotionSample(uptime: 10, date: Date(), accelerationG: SensorVector(x: 3, y: 4, z: 0),
                                  gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)
        #expect(motion.accelerationG.magnitude == 5)
        #expect(motion.totalAccelerationG.z == -1)
        #expect(motion.isValid)
    }

    @Test func staleFutureAndInaccurateGpsCannotCorroborateImpact() {
        var fix = LocationSample(uptime: 10, date: Date(), latitude: 47, longitude: -122,
                                 horizontalAccuracy: 5, speedMPS: 20, speedAccuracy: 1)
        #expect(fix.hasReliableSpeed(at: 11))
        #expect(!fix.hasReliableSpeed(at: 13))
        #expect(!fix.hasReliableSpeed(at: 9))
        fix.speedAccuracy = -1
        #expect(!fix.hasReliableSpeed(at: 11))
        fix.speedAccuracy = 10
        #expect(!fix.hasReliableSpeed(at: 11))
        fix.latitude = .nan
        #expect(!fix.isValid)
    }
}
