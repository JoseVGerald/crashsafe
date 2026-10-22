import Foundation
import Testing
@testable import CrashDetectionCore

/// Synthetic signals with known physics, so each number can be checked by hand.
enum Synthetic {
    static func motion(_ uptime: Double, _ a: SensorVector, rotation: SensorVector = .zero) -> SensorReading {
        .motion(MotionSample(uptime: uptime, date: Date(timeIntervalSinceReferenceDate: uptime), accelerationG: a,
                             gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: rotation))
    }

    static func fix(_ uptime: Double, speed: Double, lat: Double = 45.5, lon: Double = -122.6) -> SensorReading {
        .location(LocationSample(uptime: uptime, date: Date(timeIntervalSinceReferenceDate: uptime), latitude: lat,
                                 longitude: lon, horizontalAccuracy: 5, speedMPS: speed, speedAccuracy: 0.5))
    }

    /// 100 Hz motion from `start` for `seconds`, with 1 Hz GPS moving north at `speed` m/s.
    static func history(seconds: Double, start: Double = 100, speed: (Double) -> Double,
                        accel: (Double) -> SensorVector, rotation: (Double) -> SensorVector = { _ in .zero }) -> SensorHistory {
        var h = SensorHistory()
        var lat = 45.5
        for i in 0..<Int(seconds * 100) {
            let t = start + Double(i) / 100
            h.append(motion(t, accel(t), rotation: rotation(t)))
            if i % 100 == 0 {
                h.append(fix(t, speed: speed(t), lat: lat))
                lat += speed(t) / 111_320
            }
        }
        return h
    }
}

struct SensorHistoryTests {
    @Test func resamplesToTheTransportRepoContract() throws {
        let h = Synthetic.history(seconds: 8, speed: { _ in 10 }, accel: { t in SensorVector(x: 0.1 * t, y: 0, z: 0) })
        let w = try #require(h.window(endingAt: 107, duration: 5))
        #expect(w.count == SynchronizedWindow.contractSamples && w.hz == 50)
        // Linear interpolation of a linear signal is exact; g → m/s².
        #expect(abs(w.linearAccelerationMS2[0].x - 0.1 * w.startUptime * 9.80665) < 1e-6)
        #expect(w.speedMPS.allSatisfy { $0 == 10 })
        #expect(w.fixes.count == 5 || w.fixes.count == 6)
    }

    @Test func failsClosedOnGapsAndMissingCoverage() {
        var h = Synthetic.history(seconds: 8, speed: { _ in 0 }, accel: { _ in .zero })
        #expect(h.window(endingAt: 120, duration: 5) == nil) // beyond the data
        #expect(h.window(endingAt: 103, duration: 5) == nil) // before the data starts
        // A 0.5 s hole inside the window.
        h = SensorHistory()
        for i in 0..<800 where !(300..<350).contains(i) {
            h.append(Synthetic.motion(100 + Double(i) / 100, .zero))
        }
        #expect(h.window(endingAt: 107, duration: 5) == nil)
        let accepted = h.append(Synthetic.motion(50, .zero))
        #expect(!accepted) // out of order is refused
    }

    @Test func historyIsBounded() {
        let h = Synthetic.history(seconds: 60, speed: { _ in 1 }, accel: { _ in .zero })
        #expect(h.motion.count == SensorHistory.motionCapacity)
    }
}

struct ImpactAnalysisTests {
    /// 35 mph, then a 100 ms half-sine pulse of 10 g along -y, then braking to a stop.
    static func crash() -> (SensorHistory, Double) {
        let impact = 108.0
        let h = Synthetic.history(seconds: 18, speed: { t in t < impact ? 15.6 : max(0, 9 - (t - impact) * 3.6) }) { t in
            if t >= impact && t <= impact + 0.1 { return SensorVector(x: 0, y: -10 * sin(.pi * (t - impact) / 0.1), z: 0) }
            if t > impact + 0.1 && t < impact + 2.6 { return SensorVector(x: 0, y: -0.38, z: 0) }
            return SensorVector(x: 0.002, y: 0, z: 0.003)
        }
        return (h, impact)
    }

    @Test func measuresPeakDeltaVAndStop() throws {
        let (h, impact) = Self.crash()
        let r = try #require(ImpactAnalyzer.analyze(history: h, impactUptime: impact + 0.05))
        #expect(abs(r.peakG - 10) < 0.1)
        // ∫ 10 g · sin over 0.1 s = 10 · 9.80665 · 0.1 · 2/π ≈ 6.24 m/s (above the 0.8 g pulse edge).
        #expect(r.deltaVMPS > 5.9 && r.deltaVMPS < 6.3)
        #expect(r.pulseDuration > 0.08 && r.pulseDuration < 0.11)
        #expect(r.preImpactSpeedMPS == 15.6)
        #expect(r.stopBasis == "gps")
        #expect(try #require(r.timeToStop) > 2 && r.timeToStop! < 3.1)
        #expect(r.severity == .moderate)
        #expect(!r.isSimulated)
    }

    @Test func severityBandsAndSimulatedReport() {
        let simulated = ImpactAnalyzer.simulatedReport()
        #expect(simulated.isSimulated && simulated.severity == .moderate)
        #expect(abs(simulated.deltaVMPH - 14) < 1)
        // Not enough motion after the impact: no report rather than a guess.
        let (h, impact) = ImpactAnalysisTests.crash()
        #expect(ImpactAnalyzer.analyze(history: h, impactUptime: impact + 9.5) == nil)
    }
}

struct TransportModeTests {
    let model = FeatureTransportModel()

    func classify(_ h: SensorHistory, end: Double = 108) throws -> TransportObservation {
        let w = try #require(h.window(endingAt: end, duration: 5))
        return TransportObservation(probabilities: model.probabilities(for: .extract(from: w)), modelID: model.modelID)
    }

    @Test func walkingIsRecognizedFromStepCadence() throws {
        // 1.9 steps/s, ±0.25 g vertical bounce, 1.4 m/s.
        let h = Synthetic.history(seconds: 9, speed: { _ in 1.4 }) { t in
            SensorVector(x: 0.05 * sin(2 * .pi * 0.95 * t), y: 0, z: 0.25 * sin(2 * .pi * 1.9 * t))
        }
        let o = try classify(h)
        #expect(o.label == "walk")
        #expect(o.probability >= TransportObservation.acceptance)
        #expect(abs(o.probabilities.reduce(0, +) - 1) < 1e-9)
    }

    @Test func drivingAndStillAreSeparated() throws {
        let car = Synthetic.history(seconds: 9, speed: { _ in 20 }) { t in
            SensorVector(x: 0.02 * sin(t * 13), y: 0.03 * sin(t * 7), z: 0.04 * sin(t * 17))
        }
        #expect(try classify(car).label == "car")
        let still = Synthetic.history(seconds: 9, speed: { _ in 0 }) { _ in SensorVector(x: 0.001, y: 0, z: 0.002) }
        #expect(try classify(still).label == "still")
    }

    @Test func gpsFeaturesMatchTheRepoFormula() throws {
        // Five fixes 1 s apart heading north at 10 m/s: speed 10, distance 40, no heading change.
        var fixes: [LocationSample] = []
        for i in 0..<5 {
            fixes.append(LocationSample(uptime: Double(i), date: Date(timeIntervalSinceReferenceDate: Double(i)),
                                        latitude: 45 + Double(i) * 10 / 111_195, longitude: -122,
                                        horizontalAccuracy: 5, speedMPS: 10, speedAccuracy: 1))
        }
        let f = try #require(TransportFeatures.gpsFeatures(fixes, durationMS: 5000))
        #expect(f.count == 12)
        #expect(abs(f[0] - 10) < 0.01 && abs(f[5] - 40) < 0.05 && f[7] < 1e-6)
        #expect(f[10] == 5 && abs(f[11] - 0.8) < 1e-9)
    }

    @Test func dampedPerWindowNormalizationMatchesTrainShl() throws {
        let channels = [[1.0, 2, 3, 4], [5.0, 5, 5, 5]]
        let x = try #require(TransportFeatures.normalizedIMU(channels, floor: [0.1, 0.5], clip: 1.5))
        #expect(abs(x[0].reduce(0, +)) < 1e-9)          // zero mean
        #expect(x[0].allSatisfy { abs($0) <= 1.5 })        // clipped
        #expect(x[1].allSatisfy { $0 == 0 })               // flat channel stays 0 (floor, not divide by 0)
        #expect(TransportFeatures.normalizedIMU(channels, floor: [0.1], clip: 3) == nil) // no invented floors
    }
}

struct HarshEventTests {
    @Test func hardBrakingIsDetectedFromGpsSpeedChange() throws {
        // 20 m/s, then −5 m/s per second (0.51 g) for 2 s.
        let h = Synthetic.history(seconds: 10, speed: { t in t < 104 ? 20 : max(10, 20 - (t - 104) * 5) }) { _ in .zero }
        let w = try #require(h.window(endingAt: 108, duration: 5))
        let events = HarshEventDetector().detect(in: w)
        #expect(events.count == 1)
        #expect(events.first?.kind == .harshBrake)
        #expect((events.first?.severity ?? 0) > 0.9)
        let steady = Synthetic.history(seconds: 10, speed: { _ in 20 }) { _ in .zero }
        #expect(HarshEventDetector().detect(in: try #require(steady.window(endingAt: 108, duration: 5))).isEmpty)
    }
}

/// The backend (Backend/rag/motion_intel.py) writes these values from the same synthetic signals;
/// matching them keeps the app and the agent backend computing identical numbers.
struct BackendParityTests {
    nonisolated(unsafe) static let golden: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Backend/rag/tests/motion_golden.json").standardized
        let data = (try? Data(contentsOf: url)) ?? Data("{}".utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }()

    func probabilities(_ key: String) -> [Double] {
        ((Self.golden[key] as? [String: Any])?["probabilities"] as? [Double]) ?? []
    }

    @Test func transportProbabilitiesMatchTheBackend() throws {
        let walk = Synthetic.history(seconds: 9, speed: { _ in 1.4 }) { t in
            SensorVector(x: 0.05 * sin(2 * .pi * 0.95 * t), y: 0, z: 0.25 * sin(2 * .pi * 1.9 * t))
        }
        let car = Synthetic.history(seconds: 9, speed: { _ in 20 }) { t in
            SensorVector(x: 0.02 * sin(t * 13), y: 0.03 * sin(t * 7), z: 0.04 * sin(t * 17))
        }
        for (key, h) in [("walk", walk), ("car", car)] {
            let expected = probabilities(key)
            try #require(expected.count == 8, "golden file missing; run Backend/rag/tests/make_motion_golden.py")
            let w = try #require(h.window(endingAt: 108, duration: 5))
            let ours = FeatureTransportModel().probabilities(for: .extract(from: w))
            for (a, b) in zip(ours, expected) { #expect(abs(a - b) < 1e-9) }
        }
    }

    @Test func impactMatchesTheBackend() throws {
        let expected = try #require(Self.golden["crash_impact"] as? [String: Any])
        let (h, impact) = ImpactAnalysisTests.crash()
        let r = try #require(ImpactAnalyzer.analyze(history: h, impactUptime: impact + 0.05))
        #expect(abs(r.deltaVMPS - (expected["delta_v_mps"] as? Double ?? -1)) < 1e-9)
        #expect(abs(r.peakG - (expected["peak_g"] as? Double ?? -1)) < 1e-9)
        #expect(abs(r.pulseDuration - (expected["pulse_duration_s"] as? Double ?? -1)) < 1e-9)
        #expect(abs((r.timeToStop ?? -1) - (expected["time_to_stop_s"] as? Double ?? -2)) < 1e-9)
        #expect(r.severity.rawValue == expected["severity"] as? String)
    }

    @Test func harshEventsMatchTheBackend() throws {
        let expected = try #require(Self.golden["brake_events"] as? [[String: Any]])
        let h = Synthetic.history(seconds: 10, speed: { t in t < 104 ? 20 : max(10, 20 - (t - 104) * 5) }) { _ in .zero }
        let events = HarshEventDetector().detect(in: try #require(h.window(endingAt: 108, duration: 5)))
        #expect(events.count == expected.count)
        for (e, x) in zip(events, expected) {
            #expect(e.kind.rawValue == x["kind"] as? String)
            #expect(abs(e.start - (x["start"] as? Double ?? -1)) < 1e-9 && abs(e.end - (x["end"] as? Double ?? -1)) < 1e-9)
        }
    }
}

struct LongitudinalEventTests {
    /// Feeds `seconds` of 100 Hz motion: horizontal g along x, yaw (rad/s) about vertical, gravity down z.
    static func run(_ detector: inout LongitudinalEventDetector, from start: Double, seconds: Double,
                    g: Double, yaw: Double) -> [Double] {
        var hits: [Double] = []
        for i in 0..<Int(seconds * 100) {
            let t = start + Double(i) / 100
            let s = MotionSample(uptime: t, date: .now, accelerationG: SensorVector(x: g + 0.02 * sin(t * 40), y: 0, z: 0.03 * sin(t * 25)),
                                 gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: SensorVector(x: 0.01, y: 0, z: yaw))
            if let peak = detector.add(s) { hits.append(peak) }
        }
        return hits
    }

    @Test func hardStopIsCaughtButTurnsAndJoltsAreNot() {
        var d = LongitudinalEventDetector()
        #expect(Self.run(&d, from: 0, seconds: 5, g: 0.02, yaw: 0).isEmpty)          // cruising
        #expect(Self.run(&d, from: 5, seconds: 1.5, g: 0.35, yaw: 0.03).count == 1)  // hard stop
        #expect(Self.run(&d, from: 10, seconds: 3, g: 0.42, yaw: 0.45).isEmpty)      // hard turn
        #expect(Self.run(&d, from: 15, seconds: 0.3, g: 0.6, yaw: 0).isEmpty)        // pothole jolt
        #expect(Self.run(&d, from: 20, seconds: 1.5, g: 0.18, yaw: 0).isEmpty)       // gentle stop
    }
}
