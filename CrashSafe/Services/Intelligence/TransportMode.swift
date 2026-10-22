import Foundation

/// Transportation-mode classification, ported from the basis of
/// github.com/udaykamboj/multi-placement-transportation-mode-classification-ML-system:
/// its 8 SHL classes, its 50 Hz × 250-sample (5 s) IMU windows, its damped per-window
/// normalization, and its 12 per-window GPS features. The trained MSRLSTM network isn't
/// bundled (its checkpoints ship without the normalization statistics it needs), so a
/// transparent feature model fills the `TransportModeModel` slot until a converted model is added.
nonisolated enum TransportClass: Int, CaseIterable, Codable, Sendable {
    case still, walk, run, bike, car, bus, train, subway

    /// Labels used by the backend's incident schema (`Backend/rag/incident_context.py`).
    var label: String {
        switch self {
        case .still: "still"
        case .walk: "walk"
        case .run: "run"
        case .bike: "bicycle"
        case .car: "car"
        case .bus: "bus"
        case .train: "train"
        case .subway: "subway"
        }
    }

    var title: String {
        switch self {
        case .still: "Still"
        case .walk: "Walking"
        case .run: "Running"
        case .bike: "Cycling"
        case .car: "In a car"
        case .bus: "On a bus"
        case .train: "On a train"
        case .subway: "On a subway"
        }
    }

    var systemImage: String {
        switch self {
        case .still: "figure.stand"
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .bike: "bicycle"
        case .car: "car.fill"
        case .bus: "bus.fill"
        case .train: "tram.fill"
        case .subway: "tram.tunnel.fill"
        }
    }
}

/// One classified window, in the shape the agent backend accepts (`transport` in the incident packet).
nonisolated struct TransportObservation: Codable, Equatable, Sendable {
    /// Below this the label is reported as "unknown" (the backend uses the same 0.8 bar).
    static let acceptance = 0.8

    var label: String
    var basis: String
    var probability: Double
    var modelID: String
    var probabilities: [Double]

    var transportClass: TransportClass? {
        TransportClass.allCases.first { $0.label == label }
    }

    init(probabilities: [Double], modelID: String) {
        let best = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        self.probabilities = probabilities
        self.probability = probabilities[best]
        self.modelID = modelID
        self.basis = "model"
        self.label = probabilities[best] >= Self.acceptance ? (TransportClass(rawValue: best)?.label ?? "unknown") : "unknown"
    }
}

/// The model slot. A Core ML conversion of the repo's network would implement this with
/// `TransportFeatures.normalizedIMU(_:floor:clip:)` as its input.
nonisolated protocol TransportModeModel: Sendable {
    var modelID: String { get }
    /// Eight probabilities in `TransportClass` order, summing to 1.
    func probabilities(for features: TransportFeatures) -> [Double]
}

/// Features from one synchronized window.
nonisolated struct TransportFeatures: Codable, Equatable, Sendable {
    /// The repo's `window_gps_features`, same order: mean, max, std, p50, p90 speed (m/s), total
    /// distance (m), straight-line rate (m/s), mean/std/max heading change (rad), fix count, coverage.
    var gps: [Double]?
    var accelMeanMS2: Double
    var accelStdMS2: Double
    var accelMaxMS2: Double
    var gyroMeanRadS: Double
    var gyroStdRadS: Double
    /// Strongest periodicity of vertical acceleration between 0.7 and 4 Hz (steps, pedalling).
    var cadenceHz: Double
    /// Autocorrelation at that cadence, 0…1.
    var cadenceStrength: Double
    /// Median GPS speed over the window (from the per-sample speeds), m/s.
    var medianSpeedMPS: Double?

    static func extract(from window: SynchronizedWindow) -> TransportFeatures {
        let accel = window.linearAccelerationMS2.map(\.magnitude)
        let gyro = window.rotationRadPerSecond.map(\.magnitude)
        // Cadence from the vertical component (acceleration along gravity): independent of how the
        // phone is held, and not frequency-doubled the way |acceleration| is.
        let vertical = zip(window.linearAccelerationMS2, window.gravityG).map { a, g in
            g.magnitude > 0 ? a.dot(g) / g.magnitude : 0
        }
        let (cadence, strength) = dominantPeriod(vertical, hz: window.hz)
        let speeds = window.speedMPS.compactMap { $0 }
        return TransportFeatures(
            gps: gpsFeatures(window.fixes, durationMS: window.duration * 1000),
            accelMeanMS2: mean(accel), accelStdMS2: std(accel), accelMaxMS2: accel.max() ?? 0,
            gyroMeanRadS: mean(gyro), gyroStdRadS: std(gyro),
            cadenceHz: cadence, cadenceStrength: strength,
            medianSpeedMPS: speeds.count >= window.count / 3 ? ImpactAnalyzer.median(speeds) : nil)
    }

    /// Port of `window_gps_features` (scripts/parse_shl_gps.py).
    static func gpsFeatures(_ fixes: [LocationSample], durationMS: Double) -> [Double]? {
        let fl = fixes.sorted { $0.date < $1.date }
        guard fl.count >= 2 else { return nil }
        let span = (fl.last!.date.timeIntervalSince(fl.first!.date)) * 1000
        guard span > 0 else { return nil }
        var dist: [Double] = [], speed: [Double] = [], bears: [Double] = []
        for (a, b) in zip(fl, fl.dropFirst()) {
            let d = haversine(a.latitude, a.longitude, b.latitude, b.longitude)
            let dt = max(b.date.timeIntervalSince(a.date) * 1000, 1)
            dist.append(d)
            speed.append(d / (dt / 1000))
            bears.append(atan2(b.longitude - a.longitude, b.latitude - a.latitude))
        }
        var hd: [Double] = []
        for (a, b) in zip(bears, bears.dropFirst()) {
            let x = abs(b - a)
            hd.append(min(x, 2 * .pi - x))
        }
        let total = dist.reduce(0, +)
        return [mean(speed), speed.max() ?? 0, std(speed), percentile(speed, 50), percentile(speed, 90),
                total, total / max(span / 1000, 1e-3),
                hd.isEmpty ? 0 : mean(hd), hd.isEmpty ? 0 : std(hd), hd.max() ?? 0,
                Double(fl.count), span / durationMS]
    }

    /// Port of `damped_perwin` + clip (scripts/train_shl.py): per-channel instance normalization
    /// with the std floored so near-still windows don't amplify noise. `floor` comes from the
    /// model's training statistics; there is no default on purpose.
    static func normalizedIMU(_ channels: [[Double]], floor: [Double], clip: Double) -> [[Double]]? {
        guard !channels.isEmpty, channels.count == floor.count, clip > 0, floor.allSatisfy({ $0 > 0 }) else { return nil }
        return channels.enumerated().map { c, xs in
            let m = mean(xs), s = max(std(xs), floor[c])
            return xs.map { min(max(($0 - m) / s, -clip), clip) }
        }
    }

    /// The repo's 9-channel layout (lacc x/y/z m/s², gyr x/y/z rad/s, mag x/y/z). Magnetometer is
    /// zero-filled: the repo found it hurts (hard-iron spikes) and its best models mask it.
    static func imuChannels(_ window: SynchronizedWindow) -> [[Double]] {
        let a = window.linearAccelerationMS2, g = window.rotationRadPerSecond
        let zeros = Array(repeating: 0.0, count: window.count)
        return [a.map(\.x), a.map(\.y), a.map(\.z), g.map(\.x), g.map(\.y), g.map(\.z), zeros, zeros, zeros]
    }

    // MARK: Math

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    /// Population standard deviation (numpy's default).
    static func std(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let m = mean(xs)
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
    }

    /// Linear-interpolated percentile (numpy's default).
    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let pos = Double(s.count - 1) * q / 100
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    /// Strongest normalized autocorrelation lag between 0.7 and 4 Hz.
    static func dominantPeriod(_ xs: [Double], hz: Double) -> (Double, Double) {
        let m = mean(xs)
        let centered = xs.map { $0 - m }
        let energy = centered.map { $0 * $0 }.reduce(0, +)
        guard energy > 1e-9 else { return (0, 0) }
        let minLag = max(1, Int(hz / 4)), maxLag = min(centered.count - 1, Int(hz / 0.7))
        guard minLag < maxLag else { return (0, 0) }
        var best = (lag: 0, r: 0.0)
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<(centered.count - lag) { sum += centered[i] * centered[i + lag] }
            let r = sum / energy
            if r > best.r { best = (lag, r) }
        }
        return best.lag == 0 ? (0, 0) : (hz / Double(best.lag), min(best.r, 1))
    }
}

/// Transparent stand-in for the trained network: physically motivated scores per class from
/// speed (GPS branch), vibration, rotation and step cadence, turned into probabilities by softmax.
nonisolated struct FeatureTransportModel: TransportModeModel {
    let modelID = "crashsafe-shl8-features-v3"

    func probabilities(for f: TransportFeatures) -> [Double] {
        let speed = f.medianSpeedMPS ?? f.gps?[3]
        let straight = f.gps.map { $0[7] < 0.15 } ?? false
        func band(_ x: Double?, _ lo: Double, _ hi: Double, soft: Double) -> Double {
            guard let x else { return 0 }
            if x >= lo && x <= hi { return 1 }
            let d = x < lo ? lo - x : x - hi
            return max(0, 1 - d / soft)
        }
        // Gait: a human-rate rhythm with real amplitude (engine/road vibration doesn't count). A phone in
        // the hand shows the step rate; one in a front pocket swings with one leg and shows the stride
        // rate, half of it (real iPhone data, MotionSense: walking ≈ 0.95 Hz, jogging ≈ 1.35 Hz there).
        // Car vibration can be faintly rhythmic too (median strength 0.26 in real drives) but never this
        // clean (walking 0.46–0.71) and never swings the phone around (stairs: ~2 rad/s, cars: ~0.1).
        let walkRate = max(band(f.cadenceHz, 0.75, 1.15, soft: 0.25), band(f.cadenceHz, 1.5, 2.4, soft: 0.3))
        let runRate = max(band(f.cadenceHz, 1.2, 1.7, soft: 0.25), band(f.cadenceHz, 2.4, 3.6, soft: 0.5))
        // Only a gait rate counts: a gentle 3 Hz rhythm is road vibration, not a run.
        let gaitRate = max(walkRate, f.accelStdMS2 > 3 ? runRate : 0)
        let rhythmic = f.cadenceStrength > 0.4 && gaitRate > 0 && f.accelStdMS2 > 0.5
        let swinging = f.accelStdMS2 > 1.5 && f.gyroMeanRadS > 0.8 && f.cadenceStrength > 0.15
        let stepping = rhythmic || swinging
        let vigorous = f.accelStdMS2 > 5.5
        let quiet = band(f.accelStdMS2, 0, 0.25, soft: 0.5)
        var score = [Double](repeating: 0, count: 8)
        score[TransportClass.still.rawValue] = 3 * quiet * band(f.gyroMeanRadS, 0, 0.15, soft: 0.3)
            + (speed.map { $0 < 0.4 ? 1.5 : $0 > 1.5 ? -4 : -1 } ?? 0)
        score[TransportClass.walk.rawValue] = (stepping ? 2.5 * max(walkRate, rhythmic ? 0 : 0.8) * (vigorous ? 0.4 : 1) : 0)
            + band(f.accelStdMS2, 0.8, 5.5, soft: 1.5) + band(speed, 0.5, 2.3, soft: 1) - (speed.map { $0 > 4 ? 3 : 0 } ?? 0)
        // Running is never gentle (real jogging: under 5.2 m/s² of shake in only 10% of windows); a gentle
        // 3 Hz rhythm is road vibration.
        score[TransportClass.run.rawValue] = (stepping && f.accelStdMS2 > 3 ? 2.5 * runRate * (vigorous ? 1 : 0.5) : 0)
            + band(f.accelStdMS2, 5.5, 15, soft: 1.5) + band(speed, 2.3, 6.5, soft: 1.5) - (speed.map { $0 > 8 ? 3 : 0 } ?? 0)
        // Without a speed, only pedalling (a leg-rate rhythm while the phone turns with the leg) says
        // "bike"; a car's road vibration alone looks much the same (real drives scored "Cycling" otherwise).
        let pedalling = rhythmic && (0.8...1.8).contains(f.cadenceHz) && f.gyroMeanRadS > 0.5
        let bikeMotion = band(f.gyroStdRadS, 0.15, 0.8, soft: 0.4) + band(f.accelStdMS2, 0.6, 3, soft: 1)
        score[TransportClass.bike.rawValue] = 1.6 * band(speed, 3, 9, soft: 2) + bikeMotion * (speed == nil && !pedalling ? 0.4 : 1)
            - (stepping && f.cadenceHz > 1.4 ? 1.5 : 0)
        // Vehicle vibration: some shake, little rotation, no gait.
        let ridingMotion = speed == nil && !stepping && f.gyroMeanRadS < 0.3 ? 0.6 : 0
        score[TransportClass.car.rawValue] = 2.6 * band(speed, 6, 45, soft: 4) + band(f.accelStdMS2, 0.05, 1.2, soft: 1)
            - (stepping ? 1.5 : 0) + (straight ? 0 : 0.3) + ridingMotion
        score[TransportClass.bus.rawValue] = 1.4 * band(speed, 3, 22, soft: 4) + 0.6 * band(f.accelStdMS2, 0.1, 1.2, soft: 1)
            - (stepping ? 1.5 : 0)
        score[TransportClass.train.rawValue] = 1.2 * band(speed, 22, 90, soft: 8) + (straight ? 0.6 : 0)
            + 0.4 * band(f.accelStdMS2, 0.05, 0.6, soft: 0.5) - (stepping ? 2 : 0)
        let gpsCoverage = f.gps?[11] ?? 0
        score[TransportClass.subway.rawValue] = (f.gps == nil || gpsCoverage < 0.3 ? 0.8 : -1)
            * band(f.accelStdMS2, 0.1, 0.8, soft: 0.5) + 0.5 * band(f.gyroMeanRadS, 0, 0.1, soft: 0.2) - (stepping ? 2 : 0)
        return softmax(score, temperature: 0.45)
    }

    func softmax(_ xs: [Double], temperature: Double) -> [Double] {
        let m = xs.max() ?? 0
        let e = xs.map { exp(($0 - m) / temperature) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }
}
