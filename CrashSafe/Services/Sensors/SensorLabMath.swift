import Foundation

/// The math behind the Sensor Lab screen: how the phone is tilted, how hard it is being shaken or
/// turned, and how fast GPS says it is going. Pure value types, so the same numbers are unit-tested
/// on a Mac and replayed against recorded clips.
///
/// Core Motion's device frame: x to the right of the screen, y toward the top, z out of the screen.
/// Gravity is reported pointing down (lying flat face up it reads (0, 0, −1) g).
nonisolated enum SensorLabMath {
    nonisolated struct Tilt: Equatable, Sendable {
        /// Top edge raised (+) or lowered (−) from level, degrees. 90 = standing upright.
        var pitch: Double
        /// Right edge lowered (+) or raised (−), degrees.
        var roll: Double
        /// Angle between the screen and the sky: 0 = flat face up, 90 = upright, 180 = face down.
        var fromFlat: Double
        /// Where a bubble level's bubble sits, in a unit circle (x right, y down, as on screen).
        /// Reaches the edge at 45° of tilt.
        var bubble: (x: Double, y: Double) {
            let r = sin(fromFlat * .pi / 180)
            guard r > 1e-9 else { return (0, 0) }
            // Projection of "up" onto the screen: the bubble floats toward the raised edge.
            let px = -sin(roll * .pi / 180), py = -sin(pitch * .pi / 180)
            let scale = min(1, r / sin(.pi / 4)) / max(1e-9, (px * px + py * py).squareRoot())
            return (px * scale, py * scale)
        }
    }

    static func tilt(gravity g: SensorVector) -> Tilt? {
        let m = g.magnitude
        guard g.isFinite, m > 0.2 else { return nil }
        let x = g.x / m, y = g.y / m, z = g.z / m
        func degrees(_ r: Double) -> Double { r * 180 / .pi }
        return Tilt(pitch: degrees(asin(max(-1, min(1, -y)))),
                    roll: degrees(asin(max(-1, min(1, x)))),
                    fromFlat: degrees(acos(max(-1, min(1, -z)))))
    }

    /// Splits user acceleration (g) into the part along gravity (bumps, potholes, drops) and the part
    /// across it (braking, speeding up, turning), whichever way the phone is held or mounted.
    static func split(_ a: SensorVector, gravity g: SensorVector) -> (horizontal: Double, vertical: Double) {
        let m = g.magnitude
        guard m > 0.2 else { return (a.magnitude, 0) }
        let down = g * (1 / m)
        let along = a.dot(down)
        return ((a - down * along).magnitude, abs(along))
    }

    /// Speeding up (+) or slowing down (−), in g, from two GPS fixes 0.5–5 s apart.
    static func longitudinalG(from a: LocationSample, to b: LocationSample) -> Double? {
        let dt = b.uptime - a.uptime
        guard a.isValid, b.isValid, a.speedMPS >= 0, b.speedMPS >= 0, dt >= 0.5, dt <= 5 else { return nil }
        return (b.speedMPS - a.speedMPS) / dt / SensorVector.standardGravity
    }

    /// GPS course (degrees, 0 = north) as a compass word.
    static func compass(_ degrees: Double) -> String {
        guard degrees.isFinite, degrees >= 0 else { return "–" }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((degrees / 45).rounded()) % 8]
    }
}

/// A quick change in motion: user acceleration rising over a threshold and falling back.
nonisolated struct Jolt: Equatable, Sendable, Identifiable {
    nonisolated enum Kind: String, Sendable {
        /// Strong enough that the crash detector would examine it (`CrashEvaluationConfiguration.candidateG`).
        case crashLevel
        /// A hit after a moment of free fall: what dropping the phone looks like.
        case drop
        case hard
        case bump

        var title: String {
            switch self {
            case .crashLevel: "Crash-level hit"
            case .drop: "Phone drop"
            case .hard: "Hard jolt"
            case .bump: "Bump"
            }
        }
    }

    var id: TimeInterval { uptime }
    var uptime: TimeInterval
    var date: Date
    var peakG: Double
    var duration: TimeInterval
    var peakRotation: Double
    var peakJerk: Double
    var kind: Kind
}

/// Finds jolts in a live motion stream and tracks jerk (how fast acceleration changes, g/s).
nonisolated struct JoltTracker: Sendable {
    var threshold = 0.5
    var hardG = 1.5
    var crashG = CrashEvaluationConfiguration().candidateG
    private(set) var jolts: [Jolt] = []
    /// Smoothed jerk, g/s.
    private(set) var jerk = 0.0
    private var open: Jolt?
    private var previous: MotionSample?
    private var freeFallStart: TimeInterval?
    private var lastFreeFall: (start: TimeInterval, end: TimeInterval)?

    init() {}

    /// Returns the jolt that just ended, if any.
    @discardableResult
    mutating func add(_ s: MotionSample) -> Jolt? {
        guard s.isValid else { return nil }
        defer { previous = s }
        var sampleJerk = 0.0
        if let p = previous, s.uptime > p.uptime {
            sampleJerk = (s.accelerationG - p.accelerationG).magnitude / (s.uptime - p.uptime)
            jerk += (sampleJerk - jerk) * 0.2
        }
        // Free fall: the accelerometer reads almost nothing (the same 0.25 g rule as the evaluator).
        if s.totalAccelerationG.magnitude < 0.25 {
            if freeFallStart == nil { freeFallStart = s.uptime }
        } else if let start = freeFallStart {
            lastFreeFall = (start, s.uptime)
            freeFallStart = nil
        }
        let g = s.accelerationG.magnitude
        if g >= threshold, freeFallStart == nil {
            if open == nil {
                open = Jolt(uptime: s.uptime, date: s.date, peakG: g, duration: 0, peakRotation: s.rotationRate.magnitude,
                            peakJerk: sampleJerk, kind: .bump)
            } else {
                open!.peakG = max(open!.peakG, g)
                open!.peakRotation = max(open!.peakRotation, s.rotationRate.magnitude)
                open!.peakJerk = max(open!.peakJerk, sampleJerk)
                open!.duration = s.uptime - open!.uptime
            }
            return nil
        }
        guard var jolt = open else { return nil }
        open = nil
        let fellFirst = lastFreeFall.map { jolt.uptime - $0.end < 0.1 && $0.end - $0.start >= 0.06 } ?? false
        jolt.kind = fellFirst ? .drop : jolt.peakG >= crashG ? .crashLevel : jolt.peakG >= hardG ? .hard : .bump
        jolts.append(jolt)
        if jolts.count > 30 { jolts.removeFirst(jolts.count - 30) }
        return jolt
    }

    mutating func reset() { self = JoltTracker() }
}

/// CSV for recordings made in the Sensor Lab and clips replayed into the simulator.
/// Motion rows fill the motion columns; GPS rows fill only speed and accuracy — never coordinates,
/// so a shared recording doesn't reveal where it was made.
nonisolated enum SensorCSV {
    static let header = "t,ax,ay,az,gx,gy,gz,rx,ry,rz,speed,speed_acc,h_acc"

    static func encode(_ readings: [SensorReading]) -> String {
        let origin = readings.lazy.map(\.uptime).min() ?? 0
        var lines = [header]
        lines.reserveCapacity(readings.count + 1)
        func f(_ x: Double) -> String { String(format: "%.5f", x) }
        for reading in readings {
            switch reading {
            case .motion(let m):
                let a = m.accelerationG, g = m.gravityG, r = m.rotationRate
                lines.append([f(m.uptime - origin), f(a.x), f(a.y), f(a.z), f(g.x), f(g.y), f(g.z), f(r.x), f(r.y), f(r.z), "", "", ""]
                    .joined(separator: ","))
            case .location(let l):
                lines.append([f(l.uptime - origin), "", "", "", "", "", "", "", "", "", f(l.speedMPS), f(l.speedAccuracy), f(l.horizontalAccuracy)]
                    .joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Readings with uptimes starting at `start`. Rows that don't parse are skipped.
    static func decode(_ text: String, start: TimeInterval = 0, date: Date = Date(timeIntervalSinceReferenceDate: 0)) -> [SensorReading] {
        var out: [SensorReading] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            guard cells.count >= 13, let t = cells[0], t.isFinite else { continue }
            let when = date.addingTimeInterval(t)
            if let ax = cells[1], let ay = cells[2], let az = cells[3], let gx = cells[4], let gy = cells[5], let gz = cells[6],
               let rx = cells[7], let ry = cells[8], let rz = cells[9] {
                out.append(.motion(MotionSample(uptime: start + t, date: when, accelerationG: SensorVector(x: ax, y: ay, z: az),
                                                gravityG: SensorVector(x: gx, y: gy, z: gz), rotationRate: SensorVector(x: rx, y: ry, z: rz))))
            } else if let speed = cells[10], let speedAccuracy = cells[11], let h = cells[12] {
                out.append(.location(LocationSample(uptime: start + t, date: when, latitude: 0, longitude: 0, horizontalAccuracy: h,
                                                    speedMPS: speed, speedAccuracy: speedAccuracy)))
            }
        }
        return out
    }
}

nonisolated extension SensorReading {
    var uptime: TimeInterval {
        switch self {
        case .motion(let m): m.uptime
        case .location(let l): l.uptime
        }
    }

    /// The same reading moved in time (for replaying a clip on the live clock).
    func shifted(by offset: TimeInterval, dateOffset: TimeInterval? = nil) -> SensorReading {
        let d = dateOffset ?? offset
        switch self {
        case .motion(var m):
            m.uptime += offset; m.date = m.date.addingTimeInterval(d)
            return .motion(m)
        case .location(var l):
            l.uptime += offset; l.date = l.date.addingTimeInterval(d)
            return .location(l)
        }
    }
}
