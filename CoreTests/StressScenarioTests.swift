import Foundation
import Testing
@testable import CrashDetectionCore

/// Regression tests from the virtual stress test (`Tools/StressLab`, docs/stress-test-report.md):
/// real crash pulses, real walking, and the generated events that exposed gaps.
struct StressScenarioTests {
    struct Clip: Decodable {
        var closing_kmh: Double
        var x: [Double]
        var y: [Double]
        var z: [Double]
        var delta_v_mps: [String: Double]
    }

    static func clip(_ name: String) throws -> Clip {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Clip.self, from: Data(contentsOf: url))
    }

    @Test func realThirtyFiveMphBarrierCrashChecksInFromEveryMount() throws {
        let clip = try Self.clip("nhtsa_v07605_frontal_35mph")
        var rng = SeededGenerator(seed: 1)
        for saturation in [8.0, 16.0] {
            for mount in PhoneMount.standard {
                let scenario = ScenarioFactory(saturationG: saturation).vehiclePulse(
                    x: clip.x, y: clip.y, z: clip.z, speedBeforeMPS: clip.closing_kmh / 3.6, speedAfterMPS: 0,
                    deltaVMPS: abs(clip.delta_v_mps["x"]!), title: "", mount: mount, rng: &rng)
                let outcome = ScenarioOutcome.evaluate(scenario)
                #expect(outcome.alerted, "\(mount.name) ±\(saturation) g")
                #expect(outcome.assessments.first?.evidence.contains(.speedLoss) == true)
            }
        }
    }

    @Test func carHitFromTheSideWhileStoppedChecksInWithoutAnyGPSSpeedLoss() throws {
        let clip = try Self.clip("nhtsa_v07602_side_struck_while_stopped")
        var rng = SeededGenerator(seed: 2)
        let dv = abs(clip.delta_v_mps["y"]!)
        let scenario = ScenarioFactory().vehiclePulse(x: clip.x, y: clip.y, z: clip.z, speedBeforeMPS: 0, speedAfterMPS: dv,
                                                      deltaVMPS: dv, title: "", mount: .dash, rng: &rng)
        let outcome = ScenarioOutcome.evaluate(scenario)
        #expect(outcome.alerted)
        let assessment = try #require(outcome.assessments.first { $0.decision == .suspectedCrash })
        #expect(assessment.evidence.contains(.largeImpactDeltaV))
        #expect(!assessment.evidence.contains(.speedLoss))
        // The pulse's own speed change matches what NHTSA measured (19 mph) within 15%.
        #expect(abs((assessment.impactDeltaVMPS ?? 0) - dv) / dv < 0.15)
    }

    @Test func briskRealWalkingNeverChecksIn() throws {
        let url = try #require(Bundle.module.url(forResource: "motionsense_wlk7_sub24_60-70s", withExtension: "csv", subdirectory: "Fixtures"))
        let rows = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst()
        var pipeline = CrashPipeline()
        var decisions: [CrashDecision] = []
        for (i, line) in rows.enumerated() {
            let c = line.split(separator: ",").compactMap { Double($0) }
            guard c.count >= 13 else { continue }
            let t = 100 + Double(i) / 50
            let sample = MotionSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t),
                                      accelerationG: SensorVector(x: c[10], y: c[11], z: c[12]),
                                      gravityG: SensorVector(x: c[4], y: c[5], z: c[6]), rotationRate: SensorVector(x: c[7], y: c[8], z: c[9]))
            if let a = pipeline.ingest(.motion(sample)) { decisions.append(a.decision) }
        }
        if let a = pipeline.advance(to: 200) { decisions.append(a.decision) }
        #expect(!decisions.isEmpty) // its 4 g heel strikes do get examined…
        #expect(!decisions.contains(.suspectedCrash)) // …and are not called a crash.
    }

    @Test func generatedCrashesAreCaughtAndLookAlikesAreNot() {
        var rng = SeededGenerator(seed: 2026)
        let factory = ScenarioFactory()
        var caught = 0
        for _ in 0..<40 {
            let s = factory.make(.frontalCrash, rng: &rng)
            if ScenarioOutcome.evaluate(s).alerted { caught += 1 }
        }
        #expect(caught >= 38)
        for kind in SensorScenario.Kind.allCases where !kind.isCrash {
            for _ in 0..<15 {
                let s = factory.make(kind, rng: &rng)
                #expect(!ScenarioOutcome.evaluate(s).alerted, "\(kind.title): \(s.detail)")
            }
        }
    }

    @Test func emergencyStopWherePhoneFallsIsNotACrash() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<30 {
            let s = ScenarioFactory().make(.phoneFliesOffMountWhileBraking, rng: &rng)
            let outcome = ScenarioOutcome.evaluate(s)
            #expect(!outcome.alerted, "\(s.detail)")
        }
    }

    @Test func rearEndedWhileStoppedIsCaughtAboveSevenMph() {
        var rng = SeededGenerator(seed: 11)
        var caught = 0, total = 0
        for _ in 0..<60 {
            let s = ScenarioFactory().make(.rearEndedWhileStopped, rng: &rng)
            guard let dv = s.trueDeltaVMPS, dv >= 3.5 else { continue }
            total += 1
            if ScenarioOutcome.evaluate(s).alerted { caught += 1 }
        }
        #expect(total > 20 && caught == total)
    }

    @Test func scenariosAreReproducible() {
        var a = SeededGenerator(seed: 5), b = SeededGenerator(seed: 5)
        let s1 = ScenarioFactory().make(.pothole, rng: &a), s2 = ScenarioFactory().make(.pothole, rng: &b)
        #expect(s1.readings.count == s2.readings.count && s1.detail == s2.detail)
    }
}

struct SensorLabTests {
    @Test func tiltFromGravity() throws {
        let flat = try #require(SensorLabMath.tilt(gravity: SensorVector(x: 0, y: 0, z: -1)))
        #expect(abs(flat.pitch) < 1e-9 && abs(flat.roll) < 1e-9 && abs(flat.fromFlat) < 1e-9)
        #expect(abs(flat.bubble.x) < 1e-9 && abs(flat.bubble.y) < 1e-9)
        let upright = try #require(SensorLabMath.tilt(gravity: SensorVector(x: 0, y: -1, z: 0)))
        #expect(abs(upright.pitch - 90) < 1e-9 && abs(upright.fromFlat - 90) < 1e-9)
        // Right edge lowered 30°: the bubble floats left, toward the raised edge.
        let s = sin(Double.pi / 6), c = cos(Double.pi / 6)
        let rolled = try #require(SensorLabMath.tilt(gravity: SensorVector(x: s, y: 0, z: -c)))
        #expect(abs(rolled.roll - 30) < 1e-9)
        #expect(rolled.bubble.x < -0.6 && abs(rolled.bubble.y) < 1e-9)
        // Top edge raised 20°: bubble moves up the screen.
        let pitched = try #require(SensorLabMath.tilt(gravity: SensorVector(x: 0, y: -sin(.pi / 9), z: -cos(.pi / 9))))
        #expect(abs(pitched.pitch - 20) < 1e-9 && pitched.bubble.y < 0)
        #expect(SensorLabMath.tilt(gravity: .zero) == nil)
    }

    @Test func splitsAccelerationAroundGravity() {
        let (h, v) = SensorLabMath.split(SensorVector(x: 0.3, y: 0, z: -0.4), gravity: SensorVector(x: 0, y: 0, z: -1))
        #expect(abs(h - 0.3) < 1e-12 && abs(v - 0.4) < 1e-12)
    }

    @Test func gpsSpeedChangeInG() throws {
        let a = LocationSample(uptime: 10, date: .now, latitude: 45, longitude: -122, horizontalAccuracy: 5, speedMPS: 20, speedAccuracy: 0.5)
        var b = a
        b.uptime = 11; b.speedMPS = 20 - 9.80665 * 0.5
        #expect(abs(try #require(SensorLabMath.longitudinalG(from: a, to: b)) + 0.5) < 1e-9)
        b.uptime = 10.1
        #expect(SensorLabMath.longitudinalG(from: a, to: b) == nil)
        #expect(SensorLabMath.compass(95) == "E" && SensorLabMath.compass(350) == "N")
    }

    @Test func joltTrackerTellsBumpsHitsAndDropsApart() {
        var tracker = JoltTracker()
        func feed(_ seconds: Double, from t0: Double, accel: SensorVector, gravity: SensorVector = SensorVector(x: 0, y: 0, z: -1)) -> Double {
            for i in 0..<Int(seconds * 100) {
                let t = t0 + Double(i) / 100
                tracker.add(MotionSample(uptime: t, date: .now, accelerationG: accel, gravityG: gravity, rotationRate: .zero))
            }
            return t0 + seconds
        }
        var t = feed(1, from: 0, accel: .zero)
        t = feed(0.03, from: t, accel: SensorVector(x: 0.8, y: 0, z: 0))
        t = feed(0.5, from: t, accel: .zero)
        t = feed(0.02, from: t, accel: SensorVector(x: 4, y: 0, z: 0))
        t = feed(0.5, from: t, accel: .zero)
        // Free fall (accelerometer reads 0: user acceleration cancels gravity), then a landing.
        t = feed(0.3, from: t, accel: SensorVector(x: 0, y: 0, z: 1))
        t = feed(0.02, from: t, accel: SensorVector(x: 0, y: 0, z: 9))
        _ = feed(0.3, from: t, accel: .zero)
        #expect(tracker.jolts.map(\.kind) == [.bump, .crashLevel, .drop])
        #expect(tracker.jolts[1].peakG == 4)
    }

    @Test func csvRoundTripKeepsMotionAndSpeedButNoCoordinates() {
        let readings: [SensorReading] = [
            .motion(MotionSample(uptime: 5, date: .now, accelerationG: SensorVector(x: 0.1, y: -0.2, z: 0.3),
                                 gravityG: SensorVector(x: 0, y: -1, z: 0), rotationRate: SensorVector(x: 1, y: 2, z: 3))),
            .location(LocationSample(uptime: 5.5, date: .now, latitude: 45.52, longitude: -122.68, horizontalAccuracy: 4,
                                     speedMPS: 12.5, speedAccuracy: 0.7)),
        ]
        let csv = SensorCSV.encode(readings)
        #expect(!csv.contains("45.52") && !csv.contains("122.68"))
        let back = SensorCSV.decode(csv, start: 100)
        #expect(back.count == 2)
        guard case .motion(let m) = back[0], case .location(let l) = back[1] else { Issue.record("wrong kinds"); return }
        #expect(m.uptime == 100 && abs(m.accelerationG.y + 0.2) < 1e-5 && abs(m.rotationRate.z - 3) < 1e-5)
        #expect(abs(l.uptime - 100.5) < 1e-9 && abs(l.speedMPS - 12.5) < 1e-5 && l.latitude == 0)
    }
}
