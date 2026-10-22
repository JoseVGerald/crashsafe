import Foundation
import Observation

/// A possible crash, as reported by a `CrashDetector`.
struct CrashEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    /// Peak acceleration in g. Real detectors read this from Core Motion.
    let peakG: Double
    /// Drop in GPS speed around the impact, in mph; nil when reliable GPS is missing.
    let speedDropMPH: Double?
    let isSimulated: Bool
    let assessment: CrashAssessment?
    /// How hard the hit was and how fast the car stopped (from the rolling sensor history).
    var impact: ImpactReport?

    init(date: Date, peakG: Double, speedDropMPH: Double?, isSimulated: Bool, assessment: CrashAssessment? = nil) {
        self.date = date
        self.peakG = peakG
        self.speedDropMPH = speedDropMPH
        self.isSimulated = isSimulated
        self.assessment = assessment
    }
}

/// Watches sensors during an active trip and emits `CrashEvent`s.
///
/// The live implementation shares acquisition with the dashboard and evaluates candidates offline.
protocol CrashDetector: AnyObject {
    var isMonitoring: Bool { get }
    /// Single stream of detected crashes for the lifetime of the app.
    var events: AsyncStream<CrashEvent> { get }
    func startMonitoring(carType: CarType)
    func stopMonitoring()
    /// Demo hook: emits a fake event so the check-in flow can be shown without crashing a car.
    func simulateCrash()
}

/// Step 5 integration. Only suspected crashes enter the existing check-in flow.
/// All assessments remain inspectable; inconclusive events do not claim that the user is safe.
@MainActor
@Observable
final class CoreMotionCrashDetector: CrashDetector {
    private(set) var isMonitoring = false
    private(set) var lastAssessment: CrashAssessment?
    @ObservationIgnored let events: AsyncStream<CrashEvent>
    @ObservationIgnored private let continuation: AsyncStream<CrashEvent>.Continuation
    @ObservationIgnored private let sensors: SensorHub
    @ObservationIgnored private let configuration: CrashEvaluationConfiguration
    @ObservationIgnored private let automaticCandidates: Bool
    @ObservationIgnored private let useWatchdog: Bool
    @ObservationIgnored private let owner = UUID()
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var pipeline: CrashPipeline
    /// True while readings must not reach crash detection (a Sensor Lab replay, unless the tester opts in).
    @ObservationIgnored private let ignoreReadings: @MainActor () -> Bool

    init(sensors: SensorHub, configuration: CrashEvaluationConfiguration = .init(),
         automaticCandidates: Bool = true, useWatchdog: Bool = true,
         ignoreReadings: @escaping @MainActor () -> Bool = { false }) {
        self.sensors = sensors
        self.ignoreReadings = ignoreReadings
        self.configuration = configuration
        self.automaticCandidates = automaticCandidates
        self.useWatchdog = useWatchdog
        pipeline = CrashPipeline(configuration: configuration, automaticCandidates: automaticCandidates)
        (events, continuation) = AsyncStream.makeStream(of: CrashEvent.self, bufferingPolicy: .bufferingNewest(1))
    }

    func startMonitoring(carType: CarType) {
        guard !isMonitoring else { return }
        let mode: TransportationMode = carType == .motorcycle ? .motorcycle : (carType == .other ? .unknown : .car)
        pipeline = CrashPipeline(configuration: configuration, transportationMode: mode, automaticCandidates: automaticCandidates)
        lastAssessment = nil
        isMonitoring = true
        observer = sensors.addObserver { [weak self] reading in
            guard let self, self.isMonitoring, !self.ignoreReadings() else { return }
            self.publish(self.pipeline.ingest(reading))
        }
        sensors.acquire(owner: owner, background: true)
        if useWatchdog {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, self.isMonitoring else { return }
                    self.publish(self.pipeline.advance(to: ProcessInfo.processInfo.systemUptime))
                }
            }
        }
    }

    /// Integration point for step 4. Candidate timestamps use the shared monotonic sensor clock.
    @discardableResult
    func submitCandidate(_ candidate: CrashCandidate) -> Bool {
        guard isMonitoring else { return false }
        return pipeline.submit(candidate)
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.cancel()
        timer = nil
        if let observer { sensors.removeObserver(observer) }
        observer = nil
        sensors.release(owner: owner)
        pipeline = CrashPipeline(configuration: configuration, automaticCandidates: automaticCandidates)
    }

    func simulateCrash() {
        continuation.yield(CrashEvent(date: .now, peakG: 6.2, speedDropMPH: 38, isSimulated: true))
    }

    private func publish(_ assessment: CrashAssessment?) {
        guard let assessment else { return }
        lastAssessment = assessment
        guard assessment.decision == .suspectedCrash else { return }
        continuation.yield(CrashEvent(date: assessment.candidate.date, peakG: assessment.peakG,
                                     speedDropMPH: assessment.speedDropMPS.map { $0 * 2.23694 },
                                     isSimulated: false, assessment: assessment))
    }
}

/// Never detects anything on its own; only `simulateCrash()` emits events.
@Observable
final class MockCrashDetector: CrashDetector {
    private(set) var isMonitoring = false
    @ObservationIgnored let events: AsyncStream<CrashEvent>
    @ObservationIgnored private let continuation: AsyncStream<CrashEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: CrashEvent.self, bufferingPolicy: .bufferingNewest(1))
    }

    func startMonitoring(carType: CarType) {
        isMonitoring = true
    }

    func stopMonitoring() {
        isMonitoring = false
    }

    func simulateCrash() {
        continuation.yield(CrashEvent(date: .now, peakG: 6.2, speedDropMPH: 38, isSimulated: true))
    }
}
