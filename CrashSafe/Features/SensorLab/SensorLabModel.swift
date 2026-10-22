import Foundation
import Observation

/// Live state behind the Sensor Lab: recent motion for the graphs, jolts, GPS speed, a silent copy of
/// the crash pipeline (shows what the detector would decide without starting a real check-in), and
/// 30-second recordings that can be shared and replayed.
@MainActor
@Observable
final class SensorLabModel {
    nonisolated enum Recording: Equatable {
        case idle
        case recording(until: TimeInterval)
        case saved(URL)
    }

    private(set) var isRunning = false
    private(set) var jolts: [Jolt] = []
    private(set) var lastAssessment: CrashAssessment?
    private(set) var assessmentsSeen = 0
    private(set) var recording: Recording = .idle
    private(set) var recordings: [URL] = []
    /// Off by default: replayed motion stays out of the real crash detector, so a replayed crash during
    /// a watched drive can't start a check-in that alerts contacts.
    var replayTriggersCheckIn = false

    /// High-rate state, read by the screen's 20 fps timeline rather than observed per sample.
    @ObservationIgnored private(set) var motion = SensorRing<MotionSample>(capacity: 600)
    @ObservationIgnored private(set) var fixes = SensorRing<LocationSample>(capacity: 20)
    @ObservationIgnored private(set) var tracker = JoltTracker()
    @ObservationIgnored private(set) var peakG = 0.0
    @ObservationIgnored private(set) var peakRotation = 0.0
    @ObservationIgnored private var pipeline = CrashPipeline()
    @ObservationIgnored private var recorded: [SensorReading] = []
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private let owner = UUID()
    @ObservationIgnored private let sensors: SensorHub
    @ObservationIgnored private let speedLimits: SpeedLimitService?
    @ObservationIgnored let replay: ReplayMotionSource?

    static let recordSeconds: TimeInterval = 30

    init(sensors: SensorHub, replay: ReplayMotionSource?, speedLimits: SpeedLimitService? = nil) {
        self.sensors = sensors
        self.replay = replay
        self.speedLimits = speedLimits
        recordings = Self.savedRecordings()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observer = sensors.addObserver { [weak self] in self?.ingest($0) }
        sensors.acquire(owner: owner, background: false)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer { sensors.removeObserver(observer) }
        observer = nil
        replay?.stopReplay()
        sensors.release(owner: owner)
        if case .recording = recording { finishRecording() }
    }

    func resetPeaks() {
        peakG = 0
        peakRotation = 0
        tracker.reset()
        jolts = []
        lastAssessment = nil
        assessmentsSeen = 0
        pipeline = CrashPipeline()
    }

    private func ingest(_ reading: SensorReading) {
        switch reading {
        case .motion(let sample):
            motion.append(sample)
            peakG = max(peakG, sample.accelerationG.magnitude)
            peakRotation = max(peakRotation, sample.rotationRate.magnitude)
            if let jolt = tracker.add(sample) {
                jolts.insert(jolt, at: 0)
                if jolts.count > 8 { jolts.removeLast() }
            }
        case .location(let fix):
            fixes.append(fix)
            speedLimits?.observe(fix)
        }
        if let assessment = pipeline.ingest(reading) {
            lastAssessment = assessment
            assessmentsSeen += 1
        }
        if case .recording(let until) = recording {
            recorded.append(reading)
            if reading.uptime >= until { finishRecording() }
        }
    }

    // MARK: Derived values

    var latest: MotionSample? { motion.values.last }
    var latestFix: LocationSample? { fixes.values.last }

    var tilt: SensorLabMath.Tilt? { latest.flatMap { SensorLabMath.tilt(gravity: $0.gravityG) } }

    /// Speeding up (+) or slowing (−) from the last two GPS fixes, g.
    var gpsLongitudinalG: Double? {
        let f = fixes.values
        guard f.count >= 2 else { return nil }
        return SensorLabMath.longitudinalG(from: f[f.count - 2], to: f[f.count - 1])
    }

    // MARK: Recording

    func startRecording() {
        guard isRunning, case .idle = recording.idleOrSaved else { return }
        recorded = []
        recording = .recording(until: (latest?.uptime ?? ProcessInfo.processInfo.systemUptime) + Self.recordSeconds)
    }

    func finishRecording() {
        guard case .recording = recording else { return }
        let readings = recorded
        recorded = []
        guard readings.count > 10, let url = try? Self.save(readings) else {
            recording = .idle
            return
        }
        recording = .saved(url)
        recordings = Self.savedRecordings()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        recordings = Self.savedRecordings()
        if case .saved(let saved) = recording, saved == url { recording = .idle }
    }

    static var folder: URL {
        URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    /// Recordings made here, plus any CSV copied into Documents/Recordings (for example into the
    /// simulator with `xcrun simctl get_app_container booted org.cac.crashsafe data`).
    static func savedRecordings() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func save(_ readings: [SensorReading]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "pulse-" + Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateTimeSeparator(.standard)) + ".csv"
        let url = folder.appending(path: name.replacingOccurrences(of: ":", with: ""))
        try SensorCSV.encode(readings).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Replay

    nonisolated enum Source: Hashable, Identifiable {
        case generated(SensorScenario.Kind)
        case realCrash
        case bundled(String)
        case file(URL)

        var id: String {
            switch self {
            case .generated(let kind): "generated-\(kind.rawValue)"
            case .realCrash: "nhtsa"
            case .bundled(let name): "bundled-\(name)"
            case .file(let url): url.path
            }
        }
    }

    /// Bundled clips of real iPhone motion (MotionSense, MIT license).
    static let bundledClips: [(name: String, title: String)] = [
        ("motionsense-walking", "Real walking (phone in pocket)"),
        ("motionsense-jogging", "Real jogging (phone in pocket)"),
    ]

    var isReplaying: Bool { replay?.isReplaying ?? false }
    var suppressesCrashDetection: Bool { isReplaying && !replayTriggersCheckIn }
    var replayTitle: String? { replay?.current?.title }

    func play(_ source: Source) {
        guard let replay, let clip = Self.clip(for: source) else { return }
        if !isRunning { start() }
        resetPeaks()
        replay.play(clip) { sensors.motionSourceChanged() }
    }

    func stopReplay() { replay?.stopReplay() }

    static func clip(for source: Source) -> ReplayMotionSource.Clip? {
        var rng = SeededGenerator(seed: UInt64(Date.now.timeIntervalSince1970))
        switch source {
        case .generated(let kind):
            let scenario = ScenarioFactory().make(kind, rng: &rng)
            return .init(title: "\(kind.title) · \(scenario.detail)", readings: scenario.readings)
        case .realCrash:
            let scenario = ScenarioFactory().vehiclePulse(
                x: RealCrashPulse.x, y: RealCrashPulse.y, z: RealCrashPulse.z, speedBeforeMPS: 56.09 / 3.6, speedAfterMPS: 0,
                deltaVMPS: 18.1, title: RealCrashPulse.title, mount: .dash, rng: &rng)
            return .init(title: RealCrashPulse.title, readings: scenario.readings)
        case .bundled(let name):
            guard let url = Bundle.main.url(forResource: name, withExtension: "csv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let title = bundledClips.first { $0.name == name }?.title ?? name
            return .init(title: title, readings: SensorCSV.decode(text))
        case .file(let url):
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return .init(title: url.deletingPathExtension().lastPathComponent, readings: SensorCSV.decode(text))
        }
    }
}

private extension SensorLabModel.Recording {
    /// Saved counts as idle for starting a new recording.
    var idleOrSaved: SensorLabModel.Recording {
        if case .saved = self { return .idle }
        return self
    }
}
