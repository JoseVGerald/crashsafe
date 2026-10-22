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
