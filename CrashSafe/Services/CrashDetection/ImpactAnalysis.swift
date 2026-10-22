import Foundation

/// How hard the hit was and how quickly the car stopped, measured by the phone's accelerometer
/// and GPS around the impact. An estimate from a phone in the cabin, not a vehicle crash recorder.
nonisolated struct ImpactReport: Codable, Equatable, Sendable {
    nonisolated enum Severity: String, Codable, Sendable {
        case minor, moderate, severe

        var label: String {
            switch self {
            case .minor: "Minor"
            case .moderate: "Moderate"
            case .severe: "Severe"
            }
        }
    }

    /// Highest acceleration in the impact pulse (gravity removed), g.
    var peakG: Double
    /// How long the hit lasted: the contiguous pulse around the peak.
    var pulseDuration: TimeInterval
    /// Speed change during the pulse, from integrating the acceleration vector, m/s.
    var deltaVMPS: Double
    /// GPS speed just before the hit, m/s.
    var preImpactSpeedMPS: Double?
    /// GPS speed a few seconds after, m/s.
    var postImpactSpeedMPS: Double?
    /// From the hit until the car was stopped.
    var timeToStop: TimeInterval?
    /// What `timeToStop` is based on: "gps" (speed under 0.5 m/s) or "motion" (the phone settled).
    var stopBasis: String?
    /// Average deceleration from the pre-impact speed to a stop, g.
    var averageStopDecelerationG: Double?
    var severity: Severity
    var isSimulated: Bool

    var deltaVMPH: Double { deltaVMPS * 2.23694 }
    var preImpactSpeedMPH: Double? { preImpactSpeedMPS.map { $0 * 2.23694 } }
}

nonisolated enum ImpactAnalyzer {
    /// Δv bands (m/s): under ~7 mph minor; ~7–16 mph moderate; above ~16 mph (≈25 km/h) severe —
    /// roughly where crash-injury risk curves rise sharply. Peak g above 20 also counts as severe.
    static let moderateDeltaV = 3.0
    static let severeDeltaV = 7.0

    /// Analyzes the history around `impactUptime`. Needs motion from 0.5 s before to 1 s after.
    static func analyze(history: SensorHistory, impactUptime t: TimeInterval, isSimulated: Bool = false) -> ImpactReport? {
        let samples = history.motion(from: t - 1, to: t + 10)
        let around = samples.filter { abs($0.uptime - t) <= 0.5 }
        guard let peak = around.max(by: { $0.accelerationG.magnitude < $1.accelerationG.magnitude }),
              samples.contains(where: { $0.uptime >= t + 1 }) else { return nil }
        let peakG = peak.accelerationG.magnitude

        // The pulse: contiguous samples around the peak above max(0.8 g, 20% of the peak).
        let threshold = max(0.8, peakG * 0.2)
        guard let peakIndex = samples.firstIndex(of: peak) else { return nil }
        var lo = peakIndex, hi = peakIndex
        while lo > 0, samples[lo - 1].accelerationG.magnitude >= threshold { lo -= 1 }
        while hi + 1 < samples.count, samples[hi + 1].accelerationG.magnitude >= threshold { hi += 1 }
        // Include one sample either side so the ramp into and out of the pulse is integrated too.
        let pulse = Array(samples[max(lo - 1, 0)...min(hi + 1, samples.count - 1)])

        // Δv = |∫ a dt| over the pulse (vector integral, trapezoids), in m/s.
        var dv = SensorVector.zero
        for (a, b) in zip(pulse, pulse.dropFirst()) {
            let dt = b.uptime - a.uptime
            dv = dv + (a.accelerationG + b.accelerationG) * (0.5 * dt * SensorVector.standardGravity)
        }
        if pulse.count == 1 { dv = peak.accelerationG * (0.01 * SensorVector.standardGravity) }
        let pulseDuration = max((pulse.last?.uptime ?? t) - (pulse.first?.uptime ?? t), 0.01)
        let pulseEnd = pulse.last?.uptime ?? t

        let fixes = history.locations(from: t - 6, to: t + 30)
        let pre = median(fixes.filter { $0.uptime >= t - 4 && $0.uptime <= t - 0.2 && reliable($0) }.map(\.speedMPS))
        let post = median(fixes.filter { $0.uptime >= t + 2 && $0.uptime <= t + 8 && reliable($0) }.map(\.speedMPS))

        var timeToStop: TimeInterval?
        var stopBasis: String?
        if let stopped = fixes.first(where: { $0.uptime > t && reliable($0) && $0.speedMPS < 0.5 }) {
            timeToStop = max(stopped.uptime - t, pulseDuration)
            stopBasis = "gps"
        } else if let settled = settleTime(samples.filter { $0.uptime > pulseEnd }) {
            timeToStop = max(settled - t, pulseDuration)
            stopBasis = "motion"
        }
        let decel: Double? = if let pre, let timeToStop, timeToStop > 0, pre > 0.5 {
            pre / timeToStop / SensorVector.standardGravity
        } else { nil }

        let deltaV = dv.magnitude
        let severity: ImpactReport.Severity =
            deltaV >= severeDeltaV || peakG >= 20 ? .severe : deltaV >= moderateDeltaV || peakG >= 8 ? .moderate : .minor
        return ImpactReport(peakG: peakG, pulseDuration: pulseDuration, deltaVMPS: deltaV,
                            preImpactSpeedMPS: pre, postImpactSpeedMPS: post, timeToStop: timeToStop,
                            stopBasis: stopBasis, averageStopDecelerationG: decel, severity: severity,
                            isSimulated: isSimulated)
    }

    /// First time the 1 s rolling RMS of acceleration drops under 0.08 g (the phone, and so the car, settled).
    static func settleTime(_ after: [MotionSample]) -> TimeInterval? {
        var window: [MotionSample] = []
        for sample in after {
            window.append(sample)
            window.removeAll { sample.uptime - $0.uptime > 1 }
            guard let first = window.first, sample.uptime - first.uptime >= 0.9 else { continue }
            let rms = (window.map { $0.accelerationG.magnitude * $0.accelerationG.magnitude }.reduce(0, +) / Double(window.count)).squareRoot()
            if rms < 0.08 { return first.uptime }
        }
        return nil
    }

    static func reliable(_ fix: LocationSample) -> Bool {
        fix.isValid && fix.speedMPS >= 0 && fix.speedAccuracy >= 0 && fix.speedAccuracy <= 3 &&
            fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 50
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// A synthetic crash run through the real analysis, for test crashes: 35 mph, a 100 ms
    /// half-sine pulse peaking at 10 g (Δv ≈ 6.2 m/s ≈ 14 mph), then braking to a stop.
    static func simulatedReport(now uptime: TimeInterval = 1_000) -> ImpactReport {
        var history = SensorHistory()
        let t0 = uptime - 15
        let impact = uptime - 8
        let pulse = 0.10
        let preSpeed = 15.6 // m/s ≈ 35 mph
        var step = 0
        var time = t0
        while time <= uptime {
            var a = SensorVector(x: 0, y: 0.03 * sin(time * 7), z: 0.02)
            if time >= impact && time <= impact + pulse {
                let g = 10 * sin(Double.pi * (time - impact) / pulse)
                a = SensorVector(x: 0, y: -g, z: 0.1 * g)
            } else if time > impact + pulse && time < impact + 2.6 {
                a = SensorVector(x: 0, y: -0.38 + 0.04 * sin(time * 11), z: 0.05)
            } else if time >= impact + 2.6 {
                a = SensorVector(x: 0.003, y: 0.002, z: 0.004)
            }
            history.append(.motion(MotionSample(uptime: time, date: Date(timeIntervalSinceReferenceDate: time), accelerationG: a,
                                                gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)))
            if step % 100 == 0 {
                let speed: Double = time < impact ? preSpeed : max(0, 9 - (time - impact) * 3.6)
                history.append(.location(LocationSample(uptime: time, date: Date(timeIntervalSinceReferenceDate: time),
                                                        latitude: 45.5, longitude: -122.6, horizontalAccuracy: 5,
                                                        speedMPS: speed, speedAccuracy: 0.5)))
            }
            step += 1
            time = t0 + Double(step) * 0.01
        }
        return analyze(history: history, impactUptime: impact, isSimulated: true)
            ?? ImpactReport(peakG: 10, pulseDuration: pulse, deltaVMPS: 6.2, preImpactSpeedMPS: preSpeed,
                            postImpactSpeedMPS: 0, timeToStop: 2.5, stopBasis: "gps", averageStopDecelerationG: 0.64,
                            severity: .moderate, isSimulated: true)
    }
}
