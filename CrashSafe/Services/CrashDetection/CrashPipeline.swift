import Foundation

/// Fixed storage; a long trip cannot grow the detector's memory indefinitely.
nonisolated struct SensorRing<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[next] = element
        next = (next + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    var values: [Element] {
        let start = count == storage.count ? next : 0
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }
}

/// Minimal bounded history and an interchangeable candidate gate support step 5.
/// The default gate is a prototype bridge until the team's step 4 detector is ready.
nonisolated struct CrashPipeline: Sendable {
    let configuration: CrashEvaluationConfiguration
    var transportationMode: TransportationMode
    let automaticCandidates: Bool
    private(set) var pending: CrashCandidate?
    private(set) var motion = SensorRing<MotionSample>(capacity: 2048)
    private(set) var locations = SensorRing<LocationSample>(capacity: 64)
    private var lastMotion: TimeInterval?
    private var lastLocation: TimeInterval?
    private var nextCandidateTime = -Double.infinity

    init(configuration: CrashEvaluationConfiguration = .init(), transportationMode: TransportationMode = .unknown,
         automaticCandidates: Bool = true) {
        precondition(configuration.isValid)
        self.configuration = configuration
        self.transportationMode = transportationMode
        self.automaticCandidates = automaticCandidates
    }

    mutating func ingest(_ reading: SensorReading) -> CrashAssessment? {
        switch reading {
        case .motion(let sample):
            guard sample.isValid, lastMotion.map({ sample.uptime > $0 }) ?? true else { return nil }
            lastMotion = sample.uptime
            motion.append(sample)
            let completed = advance(to: sample.uptime)
            if automaticCandidates, sample.accelerationG.magnitude >= configuration.candidateG {
                _ = submit(CrashCandidate(uptime: sample.uptime, date: sample.date, transportationMode: transportationMode))
            }
            return completed
        case .location(let fix):
            guard fix.isValid, lastLocation.map({ fix.uptime > $0 }) ?? true else { return nil }
            lastLocation = fix.uptime
            locations.append(fix)
            return nil // GPS never advances the motion clock or hides a motion outage.
        }
    }

    @discardableResult
    mutating func submit(_ candidate: CrashCandidate) -> Bool {
        guard candidate.uptime.isFinite, candidate.date.timeIntervalSince1970.isFinite,
              let lastMotion, abs(candidate.uptime - lastMotion) <= 0.25,
              pending == nil, candidate.uptime >= nextCandidateTime else { return false }
        pending = candidate
        return true
    }

    /// Called by a watchdog too, so loss of motion after an impact yields an inconclusive assessment.
    mutating func advance(to uptime: TimeInterval) -> CrashAssessment? {
        guard uptime.isFinite, let candidate = pending,
              uptime >= candidate.uptime + configuration.postImpactSeconds + configuration.deliveryGraceSeconds else { return nil }
        pending = nil
        let result = CrashEvidenceEvaluator(configuration: configuration)
            .evaluate(candidate: candidate, motion: motion.values, locations: locations.values)
        nextCandidateTime = uptime + (result.decision == .suspectedCrash ? configuration.cooldownSeconds : 1)
        return result
    }
}
