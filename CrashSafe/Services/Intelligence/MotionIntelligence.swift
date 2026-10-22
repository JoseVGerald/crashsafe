import Foundation
import Observation

/// Keeps the rolling sensor history while sensors run and turns it into what Pulse and the crash
/// flow use: the current transport mode, harsh braking/acceleration events, and impact reports.
@MainActor
@Observable
final class MotionIntelligence {
    nonisolated struct TimedHarshEvent: Equatable, Sendable {
        var event: HarshEvent
        var date: Date
    }

    /// Smoothed over the last three windows (~7.5 s).
    private(set) var current: TransportObservation?
    private(set) var windowsAnalyzed = 0
    private(set) var lastWindowDate: Date?
    private(set) var recentHarshEvents: [TimedHarshEvent] = []
    /// True while the foreground activity-sensing lease is held.
    private(set) var isSensingActivity = false

    @ObservationIgnored private(set) var history = SensorHistory()
    @ObservationIgnored private let sensors: SensorHub
    @ObservationIgnored let model: any TransportModeModel
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var recent: [TransportObservation] = []
    @ObservationIgnored private var lastClassified: TimeInterval?
    @ObservationIgnored private var lastHarshCheck: TimeInterval?
    @ObservationIgnored private let activityOwner = UUID()
    @ObservationIgnored private let detector = HarshEventDetector()

    static let hop: TimeInterval = 2.5

    init(sensors: SensorHub, model: any TransportModeModel = FeatureTransportModel()) {
        self.sensors = sensors
        self.model = model
    }

    /// Starts listening to whatever the sensor hub delivers (drives, crash monitoring, activity sensing).
    func start() {
        guard observer == nil else { return }
        observer = sensors.addObserver { [weak self] reading in self?.ingest(reading) }
    }

    /// While the app is on screen, keep sensors running so the mode shows up even when not driving.
    func setActivitySensing(_ on: Bool) {
        guard on != isSensingActivity else { return }
        isSensingActivity = on
        if on { sensors.acquire(owner: activityOwner, background: false) } else { sensors.release(owner: activityOwner) }
    }

    func ingest(_ reading: SensorReading) {
        guard history.append(reading), case .motion(let sample) = reading else { return }
        let t = sample.uptime
        if t - (lastClassified ?? -.infinity) >= Self.hop,
           let window = history.window(endingAt: t, duration: Double(SynchronizedWindow.contractSamples) / SynchronizedWindow.contractHz) {
            lastClassified = t
            classify(window, date: sample.date)
        }
        if t - (lastHarshCheck ?? -.infinity) >= 5, let window = history.window(endingAt: t, duration: 5) {
            lastHarshCheck = t
            let start = sample.date.addingTimeInterval(-window.duration)
            for event in detector.detect(in: window) {
                recentHarshEvents.append(TimedHarshEvent(event: event, date: start.addingTimeInterval(event.start)))
            }
            if recentHarshEvents.count > 20 { recentHarshEvents.removeFirst(recentHarshEvents.count - 20) }
        }
    }

    private func classify(_ window: SynchronizedWindow, date: Date) {
        let probabilities = model.probabilities(for: TransportFeatures.extract(from: window))
        recent.append(TransportObservation(probabilities: probabilities, modelID: model.modelID))
        if recent.count > 3 { recent.removeFirst() }
        let averaged = (0..<8).map { i in recent.map { $0.probabilities[i] }.reduce(0, +) / Double(recent.count) }
        current = TransportObservation(probabilities: averaged, modelID: model.modelID)
        windowsAnalyzed += 1
        lastWindowDate = date
    }

    /// Impact metrics for a crash event: measured from the history for real events, from the
    /// synthetic crash for test events.
    func impactReport(for event: CrashEvent) -> ImpactReport? {
        if event.isSimulated { return ImpactAnalyzer.simulatedReport() }
        guard let uptime = event.assessment?.candidate.uptime else { return nil }
        return ImpactAnalyzer.analyze(history: history, impactUptime: uptime)
    }

    /// Harsh events in the last `seconds` (for Pulse and the incident packet).
    func harshEvents(within seconds: TimeInterval, now: Date = .now) -> [TimedHarshEvent] {
        recentHarshEvents.filter { now.timeIntervalSince($0.date) <= seconds }
    }

    /// What Pulse is told about right now (sent with every question; derived values only).
    var assistantActivity: AssistantActivity? {
        guard let current else { return nil }
        let recent = harshEvents(within: 600)
        return AssistantActivity(
            transport: .init(label: current.label, basis: "model", probability: current.probability, modelId: current.modelID),
            harshBrakes10min: recent.filter { $0.event.kind == .harshBrake }.count,
            harshAccels10min: recent.filter { $0.event.kind == .harshAccel }.count)
    }

    /// Harsh events in the minute before `date`, as the incident packet's behavior events
    /// (seconds from the start of that minute).
    func behaviorEvents(before date: Date) -> [AssistantIncident.BehaviorEvent] {
        let start = date.addingTimeInterval(-60)
        return recentHarshEvents.filter { $0.date >= start && $0.date <= date }.suffix(20).map {
            let offset = $0.date.timeIntervalSince(start)
            return .init(kind: $0.event.kind.rawValue, start: offset,
                         end: offset + ($0.event.end - $0.event.start), severity: $0.event.severity)
        }
    }

    enum TestMotion: String, CaseIterable, Identifiable {
        case walk = "Walking", drive = "Driving", still = "Sitting still"
        var id: String { rawValue }
    }

    /// Testing section: plays 12 s of synthetic motion + GPS through the real analysis (for simulators,
    /// which have no motion sensor). Uptimes continue from the history so real readings still append.
    func replay(_ kind: TestMotion) {
        let start = (history.latestMotionUptime ?? ProcessInfo.processInfo.systemUptime) + 0.01
        let speed: Double = kind == .walk ? 1.4 : kind == .drive ? 20 : 0
        var lat = 45.5152
        for k in 0..<1_200 {
            let t = start + Double(k) / 100
            let a: SensorVector = switch kind {
            case .walk: SensorVector(x: 0.04 * sin(2 * .pi * 0.95 * t), y: 0, z: 0.25 * sin(2 * .pi * 1.9 * t))
            case .drive: SensorVector(x: 0.02 * sin(t * 13), y: 0.03 * sin(t * 7), z: 0.04 * sin(t * 17))
            case .still: SensorVector(x: 0.002, y: 0.001, z: 0.002)
            }
            let date = Date.now.addingTimeInterval(Double(k) / 100 - 12)
            ingest(.motion(MotionSample(uptime: t, date: date, accelerationG: a,
                                        gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)))
            if k % 100 == 0 {
                ingest(.location(LocationSample(uptime: t, date: date, latitude: lat, longitude: -122.6784,
                                                horizontalAccuracy: 5, speedMPS: speed, speedAccuracy: 0.5)))
                lat += speed / 111_320
            }
        }
    }

    /// For tests.
    func reset() {
        history = SensorHistory()
        recent = []
        current = nil
        windowsAnalyzed = 0
        lastClassified = nil
        lastHarshCheck = nil
        recentHarshEvents = []
    }
}
