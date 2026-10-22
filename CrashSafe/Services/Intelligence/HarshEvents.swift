import Foundation

/// Port of the transport repo's rule-based harsh-driving detector (src/behavior/events.py) for the
/// two longitudinal events. The repo projects acceleration onto a mount-dependent heading axis; the
/// phone's mount is unknown here, so longitudinal acceleration comes from the GPS speed change
/// instead. Like the backend adapter, cornering, instability and speeding (fixed threshold, no posted
/// limit) are not reported. No event decides a crash or fault.
nonisolated struct HarshEvent: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case harshBrake = "harsh_brake", harshAccel = "harsh_accel" }

    var kind: Kind
    /// Seconds from the start of the analyzed window.
    var start: Double
    var end: Double
    /// 0…1
    var severity: Double
}

nonisolated struct HarshEventDetector: Sendable {
    // EventConfig defaults from events.py, in g.
    var brakeLowG = 0.25
    var brakeHighG = 0.45
    var accelLowG = 0.30
    var accelHighG = 0.50
    var minDuration = 1.0
    var mergeGap = 1.5

    func detect(in window: SynchronizedWindow) -> [HarshEvent] {
        let n = window.count
        guard n > 2 else { return [] }
        let half = max(1, Int(window.hz / 2)) // central difference over ~1 s
        var events: [HarshEvent] = []
        var active: HarshEvent?

        func close(_ t: Double) {
            guard var event = active else { return }
            event.end = t
            if event.end - event.start >= minDuration { events.append(event) }
            active = nil
        }

        for i in 0..<n {
            let t = Double(i) / window.hz
            var kind: HarshEvent.Kind?
            var severity = 0.0
            if let a = window.speedMPS[max(0, i - half)], let b = window.speedMPS[min(n - 1, i + half)] {
                let dt = Double(min(n - 1, i + half) - max(0, i - half)) / window.hz
                let signed = dt > 0 ? (b - a) / dt / SensorVector.standardGravity : 0
                if signed <= -brakeLowG {
                    kind = .harshBrake
                    severity = Self.severity(-signed, brakeLowG, brakeHighG)
                } else if signed >= accelLowG {
                    kind = .harshAccel
                    severity = Self.severity(signed, accelLowG, accelHighG) * 0.8
                }
            }
            if let kind {
                if var current = active, current.kind == kind {
                    current.end = t
                    current.severity = max(current.severity, severity)
                    active = current
                } else {
                    close(t)
                    active = HarshEvent(kind: kind, start: t, end: t, severity: severity)
                }
            } else {
                close(t)
            }
        }
        close(Double(n) / window.hz)

        var merged: [HarshEvent] = []
        for event in events {
            if let last = merged.last, last.kind == event.kind, event.start - last.end <= mergeGap {
                merged[merged.count - 1].end = event.end
                merged[merged.count - 1].severity = max(last.severity, event.severity)
            } else {
                merged.append(event)
            }
        }
        return merged
    }

    static func severity(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max((x - lo) / max(hi - lo, 1e-6), 0), 1)
    }
}

/// Live hard-braking / hard-acceleration detector from the phone's own motion, whatever way it sits.
///
/// GPS alone (1 fix a second, smoothed by the chip) missed real hard stops. Measured on the labeled
/// driverBehaviorDataset trips: aggressive braking shows 0.30–0.50 g of horizontal acceleration for
/// 0.7–2 s while the car barely turns (≤ 0.10 rad/s about vertical); hard turns and lane changes reach
/// similar g but turn at 0.17–0.74 rad/s. So: horizontal g ≥ `thresholdG` for ≥ `minDuration` with
/// turn rate under `maxYawRate`. Whether it was a brake or a speed-up comes from GPS speed.
/// Tuned on trips 16–17, checked on 20–21: 11 of 12 labeled hard brakes, 0 of 31 aggressive turns and
/// lane changes, 0 of 14 gentle maneuvers, 1 other trigger in 51 min (StressLab report).
nonisolated struct LongitudinalEventDetector: Sendable {
    var thresholdG = 0.25
    var minDuration = 0.7
    var maxYawRate = 0.10
    /// One event per this many seconds.
    var refractory = 3.0

    private var accelWindow: [(t: Double, x: Double, y: Double, z: Double)] = []
    private var yawWindow: [(t: Double, yaw: Double)] = []
    private var aboveSince: Double?
    private var peak = 0.0
    private var lastEvent = -Double.infinity

    init() {}

    /// Returns the peak horizontal g when a hard longitudinal event has just been confirmed.
    mutating func add(_ s: MotionSample) -> Double? {
        guard s.isValid else { return nil }
        let t = s.uptime
        let g = s.gravityG
        let m = g.magnitude
        guard m > 0.2 else { return nil }
        let down = g * (1 / m)
        let a = s.accelerationG
        let horizontal = a - down * a.dot(down)
        accelWindow.append((t, horizontal.x, horizontal.y, horizontal.z))
        accelWindow.removeAll { t - $0.t > 0.5 }
        yawWindow.append((t, abs(s.rotationRate.dot(down))))
        yawWindow.removeAll { t - $0.t > 1.0 }
        // 0.5 s average of the horizontal vector (vibration cancels, braking doesn't).
        let n = Double(accelWindow.count)
        let avg = SensorVector(x: accelWindow.reduce(0) { $0 + $1.x } / n, y: accelWindow.reduce(0) { $0 + $1.y } / n,
                               z: accelWindow.reduce(0) { $0 + $1.z } / n).magnitude
        let yaw = yawWindow.reduce(0) { $0 + $1.yaw } / Double(yawWindow.count)
        guard avg >= thresholdG, yaw < maxYawRate else {
            aboveSince = nil
            peak = 0
            return nil
        }
        if aboveSince == nil { aboveSince = t }
        peak = max(peak, avg)
        guard t - aboveSince! >= minDuration, t - lastEvent >= refractory else { return nil }
        lastEvent = t
        let result = peak
        aboveSince = nil
        peak = 0
        return result
    }
}
