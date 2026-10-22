// Virtual stress test for CrashSafe's crash detection, run on a Mac:
//
//     Tools/StressLab/run.sh            (fetches the datasets on first run, then writes the report)
//
// It feeds the app's own CrashPipeline, CrashEvidenceEvaluator, ImpactAnalyzer and transport model
// (compiled from the same source files) with:
//   1. thousands of generated events with known physics: crashes and look-alikes (drops, potholes…);
//   2. real crash pulses from NHTSA's crash tests, placed in a drive and seen through different mounts;
//   3. hours of real iPhone motion from people walking, jogging and using stairs (MotionSense);
//   4. ~80 minutes of real driving with aggressive braking and turns (driverBehaviorDataset);
//   5. corrupted input (NaN, gaps, out-of-order, glitches).
// and writes docs/stress-test-report.md.
@testable import CrashDetectionCore
import Foundation

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var datasets = "Backend/datasets"
var output = "docs/stress-test-report.md"
var trials = 200
var seed: UInt64 = 2026
var printFeatures = false
while let arg = arguments.next() {
    switch arg {
    case "--datasets": datasets = arguments.next() ?? datasets
    case "--out": output = arguments.next() ?? output
    case "--trials": trials = Int(arguments.next() ?? "") ?? trials
    case "--seed": seed = UInt64(arguments.next() ?? "") ?? seed
    case "--features": printFeatures = true
    default: print("Unknown argument \(arg)")
    }
}

let clock = ContinuousClock()
let began = clock.now
var report: [String] = []
@MainActor func line(_ s: String = "") { report.append(s); print(s) }
func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : String(format: "%.0f%%", 100 * Double(n) / Double(d)) }
func mph(_ mps: Double) -> String { String(format: "%.0f", mps * 2.23694) }

// MARK: 1. Generated events

struct Tally {
    var alert = 0, inconclusive = 0, rejected = 0, none = 0, total = 0
    mutating func add(_ o: ScenarioOutcome) {
        total += 1
        switch o.decision {
        case .suspectedCrash: alert += 1
        case .inconclusive: inconclusive += 1
        case .rejected: rejected += 1
        case nil: none += 1
        }
    }
}

var rng = SeededGenerator(seed: seed)
var synthetic: [(SensorScenario.Kind, Double, Tally)] = []
var deltaVErrors: [Double] = []
var deltaVRatios: [Double] = []
var bucketHits: [String: (Int, Int)] = [:]
var missedExamples: [String] = []
var falseAlarmExamples: [String] = []
let buckets: [(String, ClosedRange<Double>)] = [("under 7 mph", 0...3.13), ("7–11 mph", 3.13...5), ("11–18 mph", 5...8), ("over 18 mph", 8...100)]
for saturation in [16.0, 8.0] {
    let factory = ScenarioFactory(saturationG: saturation)
    for kind in SensorScenario.Kind.allCases {
        var tally = Tally()
        for _ in 0..<trials {
            let scenario = factory.make(kind, rng: &rng)
            let outcome = ScenarioOutcome.evaluate(scenario)
            tally.add(outcome)
            if kind.isCrash, let dv = scenario.trueDeltaVMPS, saturation == 16 {
                let name = buckets.first { $0.1.contains(dv) }!.0
                var b = bucketHits[name] ?? (0, 0)
                b.1 += 1
                if outcome.alerted { b.0 += 1 }
                bucketHits[name] = b
                if let estimate = outcome.estimatedDeltaVMPS {
                    deltaVErrors.append(abs(estimate - dv))
                    deltaVRatios.append(estimate / dv)
                }
                if !outcome.alerted, dv > 5, missedExamples.count < 8 {
                    missedExamples.append("\(kind.title): \(scenario.detail), \(scenario.mount) → \(outcome.decision?.rawValue ?? "never examined")" +
                                          (outcome.assessments.last.map { " (evidence: \($0.evidence.map(\.rawValue).joined(separator: ", ")); issues: \($0.issues.map(\.rawValue).joined(separator: ", ")))" } ?? ""))
                }
            }
            if !kind.isCrash, outcome.alerted, falseAlarmExamples.count < 10, saturation == 16 {
                falseAlarmExamples.append("\(kind.title): \(scenario.detail), \(scenario.mount)" +
                                          (outcome.assessments.first { $0.decision == .suspectedCrash }.map { " (evidence: \($0.evidence.map(\.rawValue).joined(separator: ", ")))" } ?? ""))
            }
        }
        synthetic.append((kind, saturation, tally))
    }
}

// MARK: 2. Real NHTSA crash pulses

nonisolated struct NHTSAClip: Decodable {
    var test: Int
    var group: String
    var title: String?
    var closing_kmh: Double?
    var x: [Double]
    var y: [Double]
    var z: [Double]
    var delta_v_mps: [String: Double]
}

var realRows: [String] = []
var realAlerts = 0, realTotal = 0
var realByGroup: [String: (Int, Int)] = [:]
let clipFolder = URL(fileURLWithPath: datasets).appendingPathComponent("nhtsa/clips")
let clipFiles = ((try? FileManager.default.contentsOfDirectory(at: clipFolder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for file in clipFiles {
    guard let data = try? Data(contentsOf: file), let clip = try? JSONDecoder().decode(NHTSAClip.self, from: data) else { continue }
    let closing = (clip.closing_kmh ?? 0) / 3.6
    let dvx = clip.delta_v_mps["x"] ?? 0, dvy = clip.delta_v_mps["y"] ?? 0
    let dv = (dvx * dvx + dvy * dvy).squareRoot()
    // Struck-side tests: the car was standing still and is pushed sideways.
    let (before, after): (Double, Double) = switch clip.group {
    case "side_mdb": (0, abs(dvy))
    case "car_to_car_striking": (closing, max(0, closing - abs(dvx)))
    default: (closing, 0)
    }
    var hits = 0, runs = 0
    var peak = 0.0
    var decisions: [String: Int] = [:]
    for saturation in [16.0, 8.0] {
        let factory = ScenarioFactory(saturationG: saturation)
        for mount in PhoneMount.standard {
            for _ in 0..<3 {
                let s = factory.vehiclePulse(x: clip.x, y: clip.y, z: clip.z, speedBeforeMPS: before, speedAfterMPS: after,
                                             deltaVMPS: dv, title: clip.title ?? "", mount: mount, rng: &rng)
                let o = ScenarioOutcome.evaluate(s)
                runs += 1
                if o.alerted { hits += 1 }
                decisions[o.decision?.rawValue ?? "none", default: 0] += 1
                peak = max(peak, o.assessments.map(\.peakG).max() ?? 0)
            }
        }
    }
    realAlerts += hits
    realTotal += runs
    var g = realByGroup[clip.group] ?? (0, 0)
    g.0 += hits; g.1 += runs
    realByGroup[clip.group] = g
    realRows.append("| \(clip.test) | \(clip.title ?? "") | \(clip.group) | \(mph(before)) → \(mph(after)) | \(mph(dv)) | \(String(format: "%.0f", peak)) | \(pct(hits, runs)) | \(decisions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) |")
}

// MARK: 3. MotionSense: real iPhone motion, not driving

func readCSV(_ url: URL) -> [[Double]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var rows: [[Double]] = []
    for line in text.split(whereSeparator: \.isNewline).dropFirst() {
        rows.append(line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) ?? .nan })
    }
    return rows
}

struct ActivityStats {
    var seconds = 0.0, candidates = 0, alerts = 0, inconclusive = 0, maxG = 0.0
    var windows = 0, correct = 0
    var predicted: [String: Int] = [:]
}
var activities: [String: ActivityStats] = [:]
var motionSenseAlarms: [String] = []
var featureLog: [String: [TransportFeatures]] = [:]
/// Subjects 1–12 tune the model; 13–24 are held out to check it.
var heldOut: [String: (correct: Int, windows: Int)] = [:]
let expected: [String: TransportClass] = ["wlk": .walk, "ups": .walk, "dws": .walk, "jog": .run, "sit": .still, "std": .still]
let model = FeatureTransportModel()
let msRoot = URL(fileURLWithPath: datasets).appendingPathComponent("motionsense/A_DeviceMotion_data")
let trialsDirs = ((try? FileManager.default.contentsOfDirectory(at: msRoot, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
for dir in trialsDirs where dir.hasDirectoryPath {
    let activity = String(dir.lastPathComponent.prefix(3))
    let subjects = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "csv" }
    for file in subjects {
        var stats = activities[activity] ?? ActivityStats()
        var pipeline = CrashPipeline()
        var history = SensorHistory()
        var lastWindow = -Double.infinity
        let rows = readCSV(file)
        for (i, r) in rows.enumerated() where r.count >= 13 {
            let t = 100 + Double(i) / 50
            let sample = MotionSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t),
                                      accelerationG: SensorVector(x: r[10], y: r[11], z: r[12]),
                                      gravityG: SensorVector(x: r[4], y: r[5], z: r[6]),
                                      rotationRate: SensorVector(x: r[7], y: r[8], z: r[9]))
            stats.maxG = max(stats.maxG, sample.accelerationG.magnitude.isFinite ? sample.accelerationG.magnitude : 0)
            if let a = pipeline.ingest(.motion(sample)) {
                stats.candidates += 1
                if a.decision == .suspectedCrash {
                    stats.alerts += 1
                    motionSenseAlarms.append(String(format: "%@/%@ at %.1f s: peak %.1f g, pulse Δv %.1f m/s, rotation %.1f rad/s, evidence %@",
                                                    dir.lastPathComponent, file.lastPathComponent, a.candidate.uptime - 100, a.peakG,
                                                    a.impactDeltaVMPS ?? -1, a.peakRotationRadPerSecond,
                                                    a.evidence.map(\.rawValue).joined(separator: ", ")))
                }
                if a.decision == .inconclusive { stats.inconclusive += 1 }
            }
            history.append(.motion(sample))
            if t - lastWindow >= 2.5, let w = history.window(endingAt: t, duration: 5) {
                lastWindow = t
                let features = TransportFeatures.extract(from: w)
                let p = model.probabilities(for: features)
                let best = p.indices.max { p[$0] < p[$1] }!
                let label = TransportClass(rawValue: best)!
                stats.windows += 1
                stats.predicted[label.title, default: 0] += 1
                if label == expected[activity] { stats.correct += 1 }
                let subject = Int(file.deletingPathExtension().lastPathComponent.dropFirst(4)) ?? 0
                if subject <= 12 { featureLog[activity, default: []].append(features) } else {
                    var h = heldOut[activity] ?? (0, 0)
                    h.windows += 1
                    if label == expected[activity] { h.correct += 1 }
                    heldOut[activity] = h
                }
            }
        }
        if let last = rows.indices.last, let a = pipeline.advance(to: 100 + Double(last) / 50 + 10) {
            stats.candidates += 1
            if a.decision == .suspectedCrash { stats.alerts += 1 }
            if a.decision == .inconclusive { stats.inconclusive += 1 }
        }
        stats.seconds += Double(rows.count) / 50
        activities[activity] = stats
    }
}

// MARK: 4. Real driving (Android phone, earth frame, m/s²)

struct DriveStats {
    var seconds = 0.0, candidates = 0, alerts = 0, inconclusive = 0, maxG = 0.0, samples = 0
    var windows = 0
    var predicted: [String: Int] = [:]
    var heldOutWindows = 0, heldOutOnFoot = 0, heldOutCar = 0
    /// As the app shows it: probabilities averaged over the last three windows (MotionIntelligence).
    var smoothedWindows = 0, smoothedOnFoot = 0
}
var drive = DriveStats()
let driveRoot = URL(fileURLWithPath: datasets).appendingPathComponent("driver-behavior/data")
for trip in ((try? FileManager.default.contentsOfDirectory(at: driveRoot, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
    func load(_ name: String) -> [(Double, SensorVector)] {
        guard let text = try? String(contentsOf: trip.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let c = line.split(separator: ",")
            guard c.count >= 5, let ns = Double(c[1]), let x = Double(c[2]), let y = Double(c[3]), let z = Double(c[4]) else { return nil }
            return (ns / 1e9, SensorVector(x: x, y: y, z: z))
        }
    }
    let linear = load("aceleracaoLinear_terra.csv")
    let gyro = load("giroscopio_terra.csv")
    guard let t0 = linear.first?.0, !gyro.isEmpty else { continue }
    var pipeline = CrashPipeline()
    var history = SensorHistory()
    var lastWindow = -Double.infinity
    var recentProbabilities: [[Double]] = []
    var j = 0
    var last = -Double.infinity
    for (t, a) in linear where t > last {
        last = t
        while j + 1 < gyro.count && gyro[j + 1].0 <= t { j += 1 }
        // Android reports acceleration with the opposite sign to Core Motion; flip and convert to g.
        let sample = MotionSample(uptime: 100 + t - t0, date: Date(timeIntervalSinceReferenceDate: t),
                                  accelerationG: a * (-1 / SensorVector.standardGravity),
                                  gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: gyro[j].1)
        drive.samples += 1
        drive.maxG = max(drive.maxG, sample.accelerationG.magnitude)
        history.append(.motion(sample))
        if sample.uptime - lastWindow >= 2.5, let w = history.window(endingAt: sample.uptime, duration: 5) {
            lastWindow = sample.uptime
            let features = TransportFeatures.extract(from: w)
            let p = model.probabilities(for: features)
            let best = TransportClass(rawValue: p.indices.max { p[$0] < p[$1] }!)!
            drive.windows += 1
            drive.predicted[best.title, default: 0] += 1
            recentProbabilities.append(p)
            if recentProbabilities.count > 3 { recentProbabilities.removeFirst() }
            let averaged = (0..<8).map { i in recentProbabilities.map { $0[i] }.reduce(0, +) / Double(recentProbabilities.count) }
            let shown = TransportClass(rawValue: averaged.indices.max { averaged[$0] < averaged[$1] }!)!
            drive.smoothedWindows += 1
            if shown == .walk || shown == .run { drive.smoothedOnFoot += 1 }
            // Trips 16 and 17 informed the gait rule; 20 and 21 are held out.
            if printFeatures && (best == .walk || best == .run) {
                print(String(format: "carOnFoot trip %@ t=%.0f cadence %.2f strength %.2f accelStd %.2f accelMean %.2f gyroMean %.2f gyroStd %.2f", trip.lastPathComponent, sample.uptime - 100, features.cadenceHz, features.cadenceStrength, features.accelStdMS2, features.accelMeanMS2, features.gyroMeanRadS, features.gyroStdRadS))
            }
            if ["16", "17"].contains(trip.lastPathComponent) { featureLog["car", default: []].append(features) } else {
                drive.heldOutWindows += 1
                if best == .walk || best == .run { drive.heldOutOnFoot += 1 }
                if best == .car { drive.heldOutCar += 1 }
            }
        }
        if let r = pipeline.ingest(.motion(sample)) {
            drive.candidates += 1
            if r.decision == .suspectedCrash { drive.alerts += 1 }
            if r.decision == .inconclusive { drive.inconclusive += 1 }
        }
    }
    drive.seconds += last - t0
}

if printFeatures {
    func q(_ xs: [Double]) -> String {
        let s = xs.sorted()
        return [10, 50, 90].map { String(format: "%.2f", s[min(s.count - 1, s.count * $0 / 100)]) }.joined(separator: "/")
    }
    for (activity, fs) in featureLog.sorted(by: { $0.key < $1.key }) {
        print("\(activity) n=\(fs.count) cadence \(q(fs.map(\.cadenceHz))) strength \(q(fs.map(\.cadenceStrength))) accelStd \(q(fs.map(\.accelStdMS2))) accelMean \(q(fs.map(\.accelMeanMS2))) gyroMean \(q(fs.map(\.gyroMeanRadS))) gyroStd \(q(fs.map(\.gyroStdRadS)))")
    }
}

// MARK: 5. Corrupted input

var fuzzRuns = 0, fuzzAlerts = 0
var glitchAlerts = 0
let fuzzStart = clock.now
for _ in 0..<2_000 {
    var pipeline = CrashPipeline()
    var t = 50.0
    for _ in 0..<600 {
        t += rng.chance(0.05) ? rng.uniform(-0.5...0.8) : 0.01
        func v() -> Double {
            switch Int.random(in: 0..<20, using: &rng) {
            case 0: .nan
            case 1: .infinity
            case 2: rng.uniform(-200...200)
            default: rng.gaussian() * 0.05
            }
        }
        let reading: SensorReading = rng.chance(0.95)
            ? .motion(MotionSample(uptime: rng.chance(0.01) ? .nan : t, date: Date(timeIntervalSinceReferenceDate: t),
                                   accelerationG: SensorVector(x: v(), y: v(), z: v()), gravityG: SensorVector(x: 0, y: 0, z: -1),
                                   rotationRate: SensorVector(x: v(), y: v(), z: v())))
            : .location(LocationSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t), latitude: rng.uniform(-100...100),
                                       longitude: rng.uniform(-200...200), horizontalAccuracy: v(), speedMPS: v(), speedAccuracy: v()))
        if let a = pipeline.ingest(reading), a.decision == .suspectedCrash { fuzzAlerts += 1 }
    }
    fuzzRuns += 1
}
// A single-sample glitch (one 40 g reading in a steady drive) must never raise an alert.
for _ in 0..<500 {
    var pipeline = CrashPipeline()
    for k in 0..<1_000 {
        let t = 10 + Double(k) / 100
        let a = k == 500 ? SensorVector(x: 40, y: 0, z: 0) : SensorVector(x: rng.gaussian() * 0.03, y: rng.gaussian() * 0.03, z: rng.gaussian() * 0.03)
        if let r = pipeline.ingest(.motion(MotionSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t), accelerationG: a,
                                                         gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero))),
           r.decision == .suspectedCrash { glitchAlerts += 1 }
        if k % 100 == 0 {
            _ = pipeline.ingest(.location(LocationSample(uptime: t + 0.001, date: .now, latitude: 45, longitude: -122, horizontalAccuracy: 5,
                                                         speedMPS: 20, speedAccuracy: 0.5)))
        }
    }
}
let fuzzSeconds = (clock.now - fuzzStart).components.seconds

// MARK: Report

let elapsed = clock.now - began
line("# CrashSafe virtual stress test")
line()
line("Generated by `Tools/StressLab` on \(Date.now.formatted(date: .abbreviated, time: .shortened)) (seed \(seed), \(trials) trials per event and sensor range, \(elapsed.components.seconds) s).")
line("Every number below comes from the app's own crash pipeline (`CrashPipeline` → `CrashEvidenceEvaluator`, default `CrashEvaluationConfiguration`), compiled from the same source files the iPhone app uses.")
line("A **check-in** means the evaluator decided `suspectedCrash`, which is what starts the \"Are you okay?\" flow; `inconclusive` and `rejected` stay silent.")
line()
let crashTallies = synthetic.filter { $0.0.isCrash && $0.1 == 16 }.map(\.2)
let quietTallies = synthetic.filter { !$0.0.isCrash && $0.1 == 16 }.map(\.2)
let detected = crashTallies.reduce(0) { $0 + $1.alert }, crashTotal = crashTallies.reduce(0) { $0 + $1.total }
let falseAlarms = quietTallies.reduce(0) { $0 + $1.alert }, quietTotal = quietTallies.reduce(0) { $0 + $1.total }
let msHours = activities.values.reduce(0) { $0 + $1.seconds } / 3600
let msAlerts = activities.values.reduce(0) { $0 + $1.alerts }
line("## Summary")
line()
line("| Test | Result |")
line("|---|---|")
line("| Generated crashes (all sizes, ±16 g sensor) | \(pct(detected, crashTotal)) get a check-in (\(detected)/\(crashTotal)) |")
for (name, _) in buckets {
    let b = bucketHits[name] ?? (0, 0)
    line("| … crashes with speed change \(name) | \(pct(b.0, b.1)) (\(b.0)/\(b.1)) |")
}
line("| Real NHTSA crash pulses (\(clipFiles.count) tests × 4 mounts × 2 sensor ranges × 3) | \(pct(realAlerts, realTotal)) get a check-in (\(realAlerts)/\(realTotal)) |")
line("| Generated look-alikes (drops, potholes, bumps, braking, door slams…) | \(pct(falseAlarms, quietTotal)) false check-ins (\(falseAlarms)/\(quietTotal)) |")
line("| Real iPhone motion, walking/jogging/stairs (\(String(format: "%.1f", msHours)) h, MotionSense) | \(msAlerts) false check-ins |")
let heldCorrect = heldOut.values.reduce(0) { $0 + $1.correct }, heldWindows = heldOut.values.reduce(0) { $0 + $1.windows }
line("| Transport model on held-out people (still / walking / running, incl. stairs) | \(pct(heldCorrect, heldWindows)) of \(heldWindows) windows correct |")
let carOnFoot = (drive.predicted["Walking"] ?? 0) + (drive.predicted["Running"] ?? 0)
line("| Real car trips mistaken for walking or running (motion only, no GPS) | \(pct(carOnFoot, drive.windows)) of \(drive.windows) windows; held-out trips \(pct(drive.heldOutOnFoot, drive.heldOutWindows)), called a car there \(pct(drive.heldOutCar, drive.heldOutWindows)) |")
line("| … as the app shows it (averaged over 3 windows, ~7.5 s) | \(pct(drive.smoothedOnFoot, drive.smoothedWindows)) mistaken for walking or running |")
line("| Real driving with aggressive braking and turns (\(String(format: "%.0f", drive.seconds / 60)) min) | \(drive.alerts) false check-ins, \(drive.candidates) events examined, max \(String(format: "%.2f", drive.maxG)) g |")
line("| Corrupted input (\(fuzzRuns) runs of NaN/∞/out-of-order/gaps) | \(fuzzAlerts) check-ins, no crashes (\(fuzzSeconds) s) |")
line("| One-sample 40 g glitch during a drive (500 runs) | \(glitchAlerts) check-ins |")
if !deltaVErrors.isEmpty {
    let sorted = deltaVErrors.sorted(), ratios = deltaVRatios.sorted()
    line("| Speed-change (Δv) estimate on detected crashes | median error \(mph(sorted[sorted.count / 2])) mph; median estimate/true \(String(format: "%.2f", ratios[ratios.count / 2])) |")
}
line()
line("## 1. Generated events")
line()
line("Physics-based events with randomized speed, pulse length, phone mount (dash, console, pocket, cup holder or any orientation), road vibration, GPS noise and lag (0.7 s), and occasional GPS loss. Each sample averages the signal over its 10 ms, like the phone's own filter. ±16 g is a newer iPhone's accelerometer range; ±8 g an older one.")
line()
line("| Event | Should check in? | Sensor | Check-in | Inconclusive | Rejected | Not examined |")
line("|---|---|---|---|---|---|---|")
for (kind, saturation, t) in synthetic {
    line("| \(kind.title) | \(kind.isCrash ? "yes" : "no") | ±\(Int(saturation)) g | \(pct(t.alert, t.total)) | \(pct(t.inconclusive, t.total)) | \(pct(t.rejected, t.total)) | \(pct(t.none, t.total)) |")
}
line()
if !missedExamples.isEmpty {
    line("Examples of missed crashes over 11 mph:")
    line()
    for e in missedExamples { line("- \(e)") }
    line()
}
if !falseAlarmExamples.isEmpty {
    line("Examples of false check-ins:")
    line()
    for e in falseAlarmExamples { line("- \(e)") }
    line()
}
line("## 2. Real crash pulses (NHTSA Vehicle Crash Test Database)")
line()
line("The cabin-floor accelerometer from each test (10 kHz, averaged into 100 Hz samples), placed in a drive at the test speed and rotated into four phone mounts, at ±16 g and ±8 g. Δv is the car's measured speed change. Public domain data, nrd.api.nhtsa.dot.gov.")
line()
line("| Test | Vehicle / test | Type | Speed (mph) | Δv (mph) | Peak at phone (g) | Check-in | Decisions |")
line("|---|---|---|---|---|---|---|---|")
for row in realRows { line(row) }
line()
for (group, v) in realByGroup.sorted(by: { $0.key < $1.key }) { line("- \(group): \(pct(v.0, v.1)) check-ins") }
line()
line("## 3. Real iPhone motion away from a car (MotionSense)")
line()
line("iPhone 6s Core Motion at 50 Hz in a front pocket, 24 people (Malekzadeh et al., IoTDI'19). Every reading goes through the crash pipeline (no GPS) and the transport-mode model (5 s windows every 2.5 s).")
line()
line("| Activity | Time | Max g | Examined | Check-ins | Transport model correct | Held-out people (13–24) | Most common answer |")
line("|---|---|---|---|---|---|---|---|")
let names = ["wlk": "Walking", "jog": "Jogging", "ups": "Upstairs", "dws": "Downstairs", "sit": "Sitting", "std": "Standing"]
for (activity, s) in activities.sorted(by: { $0.key < $1.key }) {
    let top = s.predicted.max { $0.value < $1.value }?.key ?? "–"
    let h = heldOut[activity] ?? (0, 0)
    line("| \(names[activity] ?? activity) | \(String(format: "%.0f", s.seconds / 60)) min | \(String(format: "%.1f", s.maxG)) | \(s.candidates) | \(s.alerts) | \(pct(s.correct, s.windows)) | \(pct(h.correct, h.windows)) | \(top) |")
}
line()
for alarm in motionSenseAlarms { line("- False check-in: \(alarm)") }
if !motionSenseAlarms.isEmpty { line() }
line("## 4. Real driving (driverBehaviorDataset)")
line()
line("Android phone fixed in a car, ~50 Hz, four trips with labeled aggressive braking, turns and lane changes (Ferreira et al., PLOS ONE 2017). Linear acceleration and gyroscope through the crash pipeline (no GPS in the dataset).")
line()
line("- \(String(format: "%.0f", drive.seconds / 60)) min, \(drive.samples) samples, strongest reading \(String(format: "%.2f", drive.maxG)) g")
line("- Events examined: \(drive.candidates); check-ins: \(drive.alerts); inconclusive: \(drive.inconclusive)")
let onFoot = (drive.predicted["Walking"] ?? 0) + (drive.predicted["Running"] ?? 0)
line("- Transport model, motion only (the dataset has no GPS, which is what tells car from bus or train): \(drive.windows) windows; mistaken for walking or running: \(pct(onFoot, drive.windows)). Answers: \(drive.predicted.sorted { $0.value > $1.value }.map { "\($0.key) \(pct($0.value, drive.windows))" }.joined(separator: ", "))")
line()
line("## 5. Corrupted input")
line()
line("- \(fuzzRuns) runs of 600 readings with NaN, ∞, ±200 g values, timestamps going backward or jumping, and invalid GPS: \(fuzzAlerts) check-ins; the pipeline never crashed.")
line("- 500 drives with a single 40 g glitch sample: \(glitchAlerts) check-ins (an impact must last at least two samples).")
line()
line("## Limits")
line()
line("- Generated events follow simple physics; real phones also slide, bounce in cup holders and get picked up after a crash.")
line("- NHTSA records the car's floor, not a phone: a loose phone sees extra hits, a phone in a padded mount sees a softer pulse.")
line("- MotionSense and the driving set have no GPS, so they exercise the no-GPS path, which is the strictest one.")
line("- Thresholds are the team's experimental defaults (`CrashEvaluationConfiguration`), not crash-test validated.")
line("- Crashes with a speed change under ~7 mph are deliberately not reported (`crashDeltaVMPS` = 3 m/s), like airbag systems: a phone can't tell a fender bender from a dropped bag.")
line("- A 35 mph barrier crash peaks above the phone's sensor range, so the app's speed-change estimate reads low (~22 mph instead of ~40 at ±16 g). Detection doesn't depend on it.")
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
try report.joined(separator: "\n").appending("\n").write(toFile: output, atomically: true, encoding: .utf8)
print("\nWrote \(output)")
