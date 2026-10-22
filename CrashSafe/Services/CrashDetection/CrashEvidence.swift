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
    /// Horizontal speed change measured from the impact pulse itself, m/s (≈ 6.7 mph). Airbag systems
    /// use a similar measure; it works without GPS, which is often lost or lagging right after a crash.
    var crashDeltaVMPS = 3.0

    var isValid: Bool {
        let positive = [candidateG, strongImpactG, minimumImpactDuration, rotationRadPerSecond,
                        minimumSpeedLossMPS, minimumSpeedLossFraction, settledRMSG, preImpactSeconds,
                        postImpactSeconds, maximumMotionGap, cooldownSeconds, crashDeltaVMPS]
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
    /// The impact pulse alone changed the car's horizontal speed by at least `crashDeltaVMPS`.
    case largeImpactDeltaV
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
    /// Horizontal speed change integrated over the impact pulse, m/s.
    var impactDeltaVMPS: Double?
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
        let pulseDeltaV = Self.horizontalDeltaV(impact: impact, baseline: baseline, maximumGap: c.maximumMotionGap)
        let bigPulse = pulseDeltaV.map { $0 >= c.crashDeltaVMPS } ?? false
        let hugePulse = pulseDeltaV.map { $0 >= 2 * c.crashDeltaVMPS } ?? false
        let settled = rms.map { $0 <= c.settledRMSG } ?? false
        var evidence: [CrashEvidence] = []
        if sustained { evidence.append(.sustainedImpact) }
        if peak >= c.strongImpactG { evidence.append(.strongImpact) }
        if rotation >= c.rotationRadPerSecond { evidence.append(.rapidRotation) }
        if speedLoss { evidence.append(.speedLoss) }
        if settled { evidence.append(.settledAfterImpact) }
        if possibleDrop { evidence.append(.possiblePhoneDrop) }
        // A car that was standing still can't "continue" traveling: if it moves afterward, it was pushed.
        let continued = preFix.flatMap { pre in postFix.map { $0.speedMPS >= 3 && pre.speedMPS >= 3 && $0.speedMPS >= pre.speedMPS - 2 } } ?? false
        if continued { evidence.append(.continuedTravel) }
        if bigPulse && sustained { evidence.append(.largeImpactDeltaV) }

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
        } else if possibleDrop {
            // The phone fell and hit something. During an emergency stop that looks like speed loss plus
            // an impact, so it counts only when the hit itself was a hard horizontal one (a loose phone
            // thrown into the dash by a crash), not a landing on the floor.
            decision = speedLoss && bigPulse ? .suspectedCrash : .inconclusive
        } else if speedLoss {
            decision = .suspectedCrash
        } else if hugePulse || (bigPulse && !continued) {
            // The pulse alone shows a crash-sized speed change: rear-ended or T-boned while stopped,
            // side impacts that don't slow the car, and crashes where GPS drops out.
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
                               speedDropMPS: speedDrop, postImpactRMSG: rms, location: location,
                               impactDeltaVMPS: pulseDeltaV)
    }

    /// Integrates user acceleration over the contiguous pulse around the peak and drops the part along
    /// gravity, so potholes, bumps and a phone landing flat don't count. m/s; nil without samples.
    /// The pulse is the run of samples above max(0.8 g, 20% of the peak, 1.5 × the RMS of the second
    /// before): a crash stands out from what came before it, while the steady 1–2 g of brisk walking
    /// or jogging would otherwise merge into one long "pulse".
    static func horizontalDeltaV(impact: [MotionSample], baseline: [MotionSample], maximumGap: TimeInterval) -> Double? {
        guard let peakIndex = impact.indices.max(by: { impact[$0].accelerationG.magnitude < impact[$1].accelerationG.magnitude }) else { return nil }
        let recent = baseline.filter { $0.uptime >= impact[0].uptime - 1 }
        let baselineRMS = recent.isEmpty ? 0 : (recent.reduce(0) { $0 + pow($1.accelerationG.magnitude, 2) } / Double(recent.count)).squareRoot()
        let threshold = max(0.8, impact[peakIndex].accelerationG.magnitude * 0.2, 1.5 * baselineRMS)
        var lo = peakIndex, hi = peakIndex
        while lo > 0, impact[lo - 1].accelerationG.magnitude >= threshold { lo -= 1 }
        while hi + 1 < impact.count, impact[hi + 1].accelerationG.magnitude >= threshold { hi += 1 }
        let spacing = impact.count > 1 ? (impact.last!.uptime - impact.first!.uptime) / Double(impact.count - 1) : 0.01
        var sum = SensorVector.zero
        for i in lo...hi {
            let dt = i + 1 < impact.count ? impact[i + 1].uptime - impact[i].uptime : spacing
            sum = sum + impact[i].accelerationG * (min(max(dt, 0), maximumGap) * SensorVector.standardGravity)
        }
        // "Down" from the moment just before the hit (the phone may tumble during it).
        let reference = baseline.suffix(10).reduce(SensorVector.zero) { $0 + $1.gravityG }
        let gravity = reference.magnitude > 0.2 ? reference : impact[peakIndex].gravityG
        guard gravity.magnitude > 0.2 else { return sum.magnitude }
        let down = gravity * (1 / gravity.magnitude)
        return (sum - down * sum.dot(down)).magnitude
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
