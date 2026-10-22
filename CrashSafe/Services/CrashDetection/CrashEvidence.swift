import Foundation

nonisolated enum TransportationMode: String, Codable, Sendable {
    case car, motorcycle, bicycle, unknown
}

/// Experimental settings, not clinically or crash-test validated thresholds.
/// A future calibrated profile can be supplied without changing acquisition or UI code.
nonisolated struct CrashEvaluationConfiguration: Equatable, Sendable {
    var candidateG = 3.0
    var strongImpactG = 6.0
    var minimumImpactDuration = 0.01
    var rotationRadPerSecond = 2.0
    var minimumSpeedLossMPS = 4.0
    var minimumSpeedLossFraction = 0.25
    var settledRMSG = 0.15
    var preImpactSeconds = 2.0
    var postImpactSeconds = 3.0
    var deliveryGraceSeconds = 0.5
    var maximumMotionGap = 0.15
    var cooldownSeconds = 15.0

    var isValid: Bool {
        let positive = [candidateG, strongImpactG, minimumImpactDuration, rotationRadPerSecond,
                        minimumSpeedLossMPS, minimumSpeedLossFraction, settledRMSG, preImpactSeconds,
                        postImpactSeconds, maximumMotionGap, cooldownSeconds]
        return positive.allSatisfy { $0.isFinite && $0 > 0 } &&
            strongImpactG >= candidateG && minimumSpeedLossFraction <= 1 &&
            preImpactSeconds >= 0.5 && postImpactSeconds >= 1.5 &&
            deliveryGraceSeconds.isFinite && deliveryGraceSeconds >= 0
    }
}

nonisolated struct CrashCandidate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var uptime: TimeInterval
    var date: Date
    var transportationMode: TransportationMode
}

nonisolated enum CrashDecision: String, Codable, Sendable {
    case suspectedCrash, rejected, inconclusive
}

nonisolated enum CrashEvidence: String, Codable, Sendable {
    case sustainedImpact, strongImpact, rapidRotation, speedLoss, settledAfterImpact
    case possiblePhoneDrop, continuedTravel
}

nonisolated enum CrashDataIssue: String, Codable, Sendable {
    case insufficientBaseline, insufficientPostImpact, motionGap, missingReliableGPS
}

nonisolated struct CrashAssessment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { candidate.id }
    var candidate: CrashCandidate
    var decision: CrashDecision
    var evidence: [CrashEvidence]
    var issues: [CrashDataIssue]
    var peakG: Double
    var peakRotationRadPerSecond: Double
    var impactDuration: TimeInterval
    var preSpeedMPS: Double?
    var postSpeedMPS: Double?
    var speedDropMPS: Double?
    var postImpactRMSG: Double?
    var location: LocationSample?
}

/// Stateless step 5. It can consume candidates from the team's eventual step 4 implementation.
nonisolated struct CrashEvidenceEvaluator: Sendable {
    let configuration: CrashEvaluationConfiguration

    init(configuration: CrashEvaluationConfiguration = .init()) {
        precondition(configuration.isValid)
        self.configuration = configuration
    }

    func evaluate(candidate: CrashCandidate, motion: [MotionSample], locations: [LocationSample]) -> CrashAssessment {
        let c = configuration
        let t = candidate.uptime
        let samples = motion.filter { $0.isValid && $0.uptime >= t - c.preImpactSeconds &&
            $0.uptime <= t + c.postImpactSeconds }.sorted { $0.uptime < $1.uptime }
        let impact = samples.filter { $0.uptime >= t - 0.1 && $0.uptime <= t + 0.25 }
        let baseline = samples.filter { $0.uptime < t - 0.1 }
        let after = samples.filter { $0.uptime >= t + 0.5 }
        let fixes = locations.filter(\.isValid).sorted { $0.uptime < $1.uptime }
        let peak = impact.map { $0.accelerationG.magnitude }.max() ?? 0
        let rotation = samples.filter { abs($0.uptime - t) <= 0.5 }.map { $0.rotationRate.magnitude }.max() ?? 0
        let duration = longestRun(in: impact, matching: { $0.accelerationG.magnitude >= c.candidateG })
        let rms = after.isEmpty ? nil : (after.reduce(0) { $0 + pow($1.accelerationG.magnitude, 2) } / Double(after.count)).squareRoot()

        let preFix = fixes.last { $0.uptime < t - 0.1 && $0.hasReliableSpeed(at: t) }
        let postFixes = fixes.filter { $0.uptime >= t + 0.5 && $0.uptime <= t + c.postImpactSeconds &&
            $0.hasReliableSpeed(at: t + c.postImpactSeconds) }
        // Median post-impact speed resists one noisy GPS reading.
        let postFix = postFixes.sorted { $0.speedMPS < $1.speedMPS }.dropFirst(postFixes.count / 2).first
        let speedDrop = preFix.flatMap { pre in postFix.map { max(0, pre.speedMPS - $0.speedMPS) } }
        let speedLoss = preFix.flatMap { pre in postFix.map { post in
            pre.speedMPS >= 3 && pre.speedMPS - post.speedMPS - pre.speedAccuracy - post.speedAccuracy >= c.minimumSpeedLossMPS &&
                (pre.speedMPS - post.speedMPS) / pre.speedMPS >= c.minimumSpeedLossFraction
        }} ?? false

        let possibleDrop = longestRun(in: samples.filter { $0.uptime < t && $0.uptime >= t - 0.5 },
                                     matching: { $0.totalAccelerationG.magnitude < 0.25 }) >= 0.06
        let sustained = duration + 0.000001 >= c.minimumImpactDuration
        let settled = rms.map { $0 <= c.settledRMSG } ?? false
        var evidence: [CrashEvidence] = []
        if sustained { evidence.append(.sustainedImpact) }
        if peak >= c.strongImpactG { evidence.append(.strongImpact) }
        if rotation >= c.rotationRadPerSecond { evidence.append(.rapidRotation) }
        if speedLoss { evidence.append(.speedLoss) }
        if settled { evidence.append(.settledAfterImpact) }
        if possibleDrop { evidence.append(.possiblePhoneDrop) }
        if let preFix, let postFix, postFix.speedMPS >= 3, postFix.speedMPS >= preFix.speedMPS - 2 {
            evidence.append(.continuedTravel)
        }

        var issues: [CrashDataIssue] = []
        if baseline.count < 10 || span(baseline) < 0.5 { issues.append(.insufficientBaseline) }
        if after.count < 10 || span(after) < 1 || (after.last?.uptime ?? t) < t + c.postImpactSeconds - c.maximumMotionGap {
            issues.append(.insufficientPostImpact)
        }
        if zip(samples, samples.dropFirst()).contains(where: { $1.uptime - $0.uptime > c.maximumMotionGap }) {
            issues.append(.motionGap)
        }
        if preFix == nil || postFix == nil { issues.append(.missingReliableGPS) }
        let incompleteMotion = issues.contains { $0 != .missingReliableGPS }
        let decision: CrashDecision
        if incompleteMotion {
            decision = .inconclusive
        } else if !sustained {
            decision = .rejected
        } else if speedLoss {
            decision = .suspectedCrash
        } else if issues.contains(.missingReliableGPS) && peak >= c.strongImpactG &&
                    rotation >= c.rotationRadPerSecond && settled && !possibleDrop {
            decision = .suspectedCrash
        } else if peak >= c.strongImpactG || rotation >= c.rotationRadPerSecond || possibleDrop {
            // Continued travel and GPS absence are not proof that no crash happened.
            decision = .inconclusive
        } else {
            decision = .rejected
        }
        let location = fixes.filter { abs($0.uptime - t) <= 3 && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
            .min { abs($0.uptime - t) < abs($1.uptime - t) }
        return CrashAssessment(candidate: candidate, decision: decision, evidence: evidence, issues: issues,
                               peakG: peak, peakRotationRadPerSecond: rotation, impactDuration: duration,
                               preSpeedMPS: preFix?.speedMPS, postSpeedMPS: postFix?.speedMPS,
                               speedDropMPS: speedDrop, postImpactRMSG: rms, location: location)
    }

    private func span(_ samples: [MotionSample]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.uptime - first.uptime
    }

    private func longestRun(in samples: [MotionSample], matching: (MotionSample) -> Bool) -> TimeInterval {
        var start: TimeInterval?, previous: TimeInterval?, longest = 0.0
        for sample in samples {
            if matching(sample) {
                if previous.map({ sample.uptime - $0 > configuration.maximumMotionGap }) ?? true { start = nil }
                if start == nil { start = sample.uptime }
                longest = max(longest, sample.uptime - (start ?? sample.uptime))
            } else { start = nil }
            previous = sample.uptime
        }
        return longest
    }
}
