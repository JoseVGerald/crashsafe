import Foundation
import Testing
@testable import CrashDetectionCore

struct CrashEvidenceTests {
    @Test func impactAndReliableSpeedLossProduceExplainableSuspectedCrash() {
        let result = assess(motion: trace(), gps: fixes())
        #expect(result.decision == .suspectedCrash)
        #expect(result.evidence.contains(.sustainedImpact))
        #expect(result.evidence.contains(.speedLoss))
        #expect(result.peakG == 4)
        #expect(result.speedDropMPS == 20)
        #expect(result.issues.isEmpty)
        #expect(result.location != nil)
    }

    @Test func crashDoesNotRequireStillnessOrRotationWhenSpeedLossCorroborates() {
        let result = assess(motion: trace(afterG: 0.4), gps: fixes())
        #expect(result.decision == .suspectedCrash)
        #expect(!result.evidence.contains(.settledAfterImpact))
        #expect(!result.evidence.contains(.rapidRotation))
    }

    @Test func isolatedSpikeAndHardBrakingAreRejected() {
        let spike = assess(motion: trace(impactG: 8, impactSamples: 1), gps: fixes())
        #expect(spike.decision == .rejected)
        let brake = assess(motion: trace(impactG: 0.5), gps: fixes())
        #expect(brake.decision == .rejected)
    }

    @Test func missingGpsRequiresStrongerIndependentEvidence() {
        let strong = assess(motion: trace(impactG: 8, rotation: 3), gps: [])
        #expect(strong.decision == .suspectedCrash)
        #expect(strong.issues == [.missingReliableGPS])
        #expect(strong.speedDropMPS == nil)
        let weak = assess(motion: trace(), gps: [])
        #expect(weak.decision == .rejected)
    }

    @Test func freeFallPatternPreventsMotionOnlyPhoneDropConfirmation() {
        var samples = trace(impactG: 8, rotation: 4)
        for index in 180..<196 {
            samples[index].accelerationG = SensorVector(x: 0, y: 0, z: 1)
        }
        let result = assess(motion: samples, gps: [])
        #expect(result.evidence.contains(.possiblePhoneDrop))
        #expect(result.decision == .inconclusive)
    }

    @Test func continuedTravelDoesNotAutomaticallyRuleOutCrash() {
        let result = assess(motion: trace(impactG: 8, rotation: 3), gps: fixes(postSpeed: 20))
        #expect(result.evidence.contains(.continuedTravel))
        #expect(result.decision == .inconclusive)
    }

    @Test func gpsUncertaintyIsAccountedFor() {
        var gps = fixes(postSpeed: 13)
        for index in gps.indices { gps[index].speedAccuracy = 3 }
        let result = assess(motion: trace(), gps: gps)
        #expect(!result.evidence.contains(.speedLoss))
        #expect(result.decision == .rejected)
        for index in gps.indices { gps[index].speedAccuracy = -1 }
        #expect(assess(motion: trace(), gps: gps).issues.contains(.missingReliableGPS))
    }

    @Test func staleGpsAndInsufficientMotionRemainExplicit() {
        var gps = fixes()
        gps[0].uptime = 5
        #expect(assess(motion: trace(), gps: gps).issues.contains(.missingReliableGPS))
        let gap = trace().filter { $0.uptime < 12.3 || $0.uptime > 12.6 }
        let interrupted = assess(motion: gap, gps: fixes())
        #expect(interrupted.decision == .inconclusive)
        #expect(interrupted.issues.contains(.motionGap))
        let short = assess(motion: trace().filter { $0.uptime >= 12 }, gps: fixes())
        #expect(short.decision == .inconclusive)
        #expect(short.issues.contains(.insufficientBaseline))
        let missingAfter = assess(motion: trace().filter { $0.uptime < 13 }, gps: fixes())
        #expect(missingAfter.decision == .inconclusive)
        #expect(missingAfter.issues.contains(.insufficientPostImpact))
    }

    @Test func assessmentRoundTripsWithoutConvertingUnknownSpeedToZero() throws {
        let result = assess(motion: trace(impactG: 8, rotation: 3), gps: [])
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(CrashAssessment.self, from: data) == result)
        #expect(result.speedDropMPS == nil)
    }

    @Test func pipelineEvaluatesExternalCandidatesAndSuppressesDuplicateAlerts() {
        var pipeline = CrashPipeline(automaticCandidates: false)
        var results: [CrashAssessment] = []
        let gps = fixes()
        for sample in trace() {
            for fix in gps where abs(fix.uptime - sample.uptime) < 0.001 { _ = pipeline.ingest(.location(fix)) }
            if let result = pipeline.ingest(.motion(sample)) { results.append(result) }
            if abs(sample.uptime - 12) < 0.001 {
                let accepted = pipeline.submit(candidate)
                let duplicate = pipeline.submit(candidate)
                #expect(accepted)
                #expect(!duplicate)
            }
        }
        if let result = pipeline.advance(to: 15.5) { results.append(result) }
        #expect(results.count == 1)
        #expect(results.first?.decision == .suspectedCrash)
        let duplicateResult = pipeline.advance(to: 20)
        #expect(duplicateResult == nil)
        _ = pipeline.ingest(.motion(sample(18, g: 8)))
        let duringCooldown = pipeline.submit(CrashCandidate(uptime: 18, date: Date(), transportationMode: .car))
        #expect(!duringCooldown)
    }

    @Test func watchdogFinalizesMissingPostImpactDataAsInconclusive() {
        var pipeline = CrashPipeline()
        for sample in trace().filter({ $0.uptime < 12.1 }) { _ = pipeline.ingest(.motion(sample)) }
        let result = pipeline.advance(to: 16)
        #expect(result?.decision == .inconclusive)
        #expect(result?.issues.contains(.insufficientPostImpact) == true)
    }

    @Test func pipelineIgnoresInvalidAndReversedSamplesAndBoundsStorage() {
        var pipeline = CrashPipeline(automaticCandidates: false)
        for index in 0..<3000 { _ = pipeline.ingest(.motion(sample(Double(index) / 100, g: 0))) }
        #expect(pipeline.motion.count == 2048)
        let last = pipeline.motion.values.last
        _ = pipeline.ingest(.motion(sample(1, g: 8)))
        _ = pipeline.ingest(.motion(sample(.nan, g: 8)))
        #expect(pipeline.motion.values.last == last)
        #expect(pipeline.pending == nil)
    }

    @Test func ringWrapsInChronologicalOrder() {
        var ring = SensorRing<Int>(capacity: 3)
        for number in 1...5 { ring.append(number) }
        #expect(ring.values == [3, 4, 5])
    }

    @Test func invalidConfigurationsAreDetectable() {
        var config = CrashEvaluationConfiguration()
        #expect(config.isValid)
        config.candidateG = .nan
        #expect(!config.isValid)
    }

    private var candidate: CrashCandidate {
        CrashCandidate(uptime: 12, date: Date(timeIntervalSince1970: 12), transportationMode: .car)
    }

    private func assess(motion: [MotionSample], gps: [LocationSample]) -> CrashAssessment {
        CrashEvidenceEvaluator().evaluate(candidate: candidate, motion: motion, locations: gps)
    }

    private func trace(impactG: Double = 4, impactSamples: Int = 5, rotation: Double = 0, afterG: Double = 0) -> [MotionSample] {
        (0...500).map { index in
            let g = (200..<(200 + impactSamples)).contains(index) ? impactG : (index > 230 ? afterG : 0)
            var value = sample(10 + Double(index) / 100, g: g)
            if (200...210).contains(index) { value.rotationRate.z = rotation }
            return value
        }
    }

    private func sample(_ time: Double, g: Double) -> MotionSample {
        MotionSample(uptime: time, date: Date(timeIntervalSince1970: time),
                     accelerationG: SensorVector(x: g, y: 0, z: 0),
                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)
    }

    private func fixes(postSpeed: Double = 0) -> [LocationSample] {
        [11.0, 13, 14, 15].map { time in
            LocationSample(uptime: time, date: Date(timeIntervalSince1970: time), latitude: 47, longitude: -122,
                           horizontalAccuracy: 5, speedMPS: time < 12 ? 20 : postSpeed, speedAccuracy: 0.5)
        }
    }
}
