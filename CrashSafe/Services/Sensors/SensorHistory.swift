import Foundation

/// Rolling, synchronized sensor history: full acceleration and gravity vectors, rotation, and GPS,
/// kept on the device for analyzing an event (impact metrics, transport mode, harsh events).
/// Bounded memory; nothing here is saved to disk or uploaded.
nonisolated struct SensorHistory: Sendable {
    /// ~32 s of motion at 100 Hz.
    static let motionCapacity = 3_200
    /// ~4 min of GPS at 1 Hz.
    static let locationCapacity = 240

    private(set) var motion = SensorRing<MotionSample>(capacity: SensorHistory.motionCapacity)
    private(set) var locations = SensorRing<LocationSample>(capacity: SensorHistory.locationCapacity)
    private var lastMotion: TimeInterval?
    private var lastLocation: TimeInterval?

    init() {}

    var latestMotionUptime: TimeInterval? { lastMotion }

    /// Keeps only valid, strictly increasing samples (the same rule as `SensorHub` and `CrashPipeline`).
    @discardableResult
    mutating func append(_ reading: SensorReading) -> Bool {
        switch reading {
        case .motion(let sample):
            guard sample.isValid, lastMotion.map({ sample.uptime > $0 }) ?? true else { return false }
            lastMotion = sample.uptime
            motion.append(sample)
        case .location(let fix):
            guard fix.isValid, lastLocation.map({ fix.uptime > $0 }) ?? true else { return false }
            lastLocation = fix.uptime
            locations.append(fix)
        }
        return true
    }

    func motion(from start: TimeInterval, to end: TimeInterval) -> [MotionSample] {
        motion.values.filter { $0.uptime >= start && $0.uptime <= end }
    }

    func locations(from start: TimeInterval, to end: TimeInterval) -> [LocationSample] {
        locations.values.filter { $0.uptime >= start && $0.uptime <= end }
    }

    /// A uniformly sampled window ending at `end`, or nil when the history doesn't fully cover it
    /// or has a gap — the analysis fails closed instead of inventing samples.
    func window(endingAt end: TimeInterval, duration: TimeInterval, hz: Double = SynchronizedWindow.contractHz,
                maximumGap: TimeInterval = 0.25) -> SynchronizedWindow? {
        guard hz > 0, duration > 0, end.isFinite else { return nil }
        let count = Int((duration * hz).rounded())
        let start = end - Double(count - 1) / hz
        let samples = motion(from: start - maximumGap, to: end + maximumGap)
        guard let first = samples.first, let last = samples.last,
              first.uptime <= start + 0.5 / hz, last.uptime >= end - 0.5 / hz,
              !zip(samples, samples.dropFirst()).contains(where: { $1.uptime - $0.uptime > maximumGap }) else { return nil }

        var linear: [SensorVector] = [], gravity: [SensorVector] = [], rotation: [SensorVector] = []
        linear.reserveCapacity(count); gravity.reserveCapacity(count); rotation.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = start + Double(i) / hz
            while j + 1 < samples.count && samples[j + 1].uptime < t { j += 1 }
            let a = samples[j], b = samples[min(j + 1, samples.count - 1)]
            let span = b.uptime - a.uptime
            let f = span > 0 ? min(max((t - a.uptime) / span, 0), 1) : 0
            linear.append(Self.lerp(a.accelerationG, b.accelerationG, f) * SensorVector.standardGravity)
            gravity.append(Self.lerp(a.gravityG, b.gravityG, f))
            rotation.append(Self.lerp(a.rotationRate, b.rotationRate, f))
        }
        let fixes = locations(from: start - 3, to: end + 0.5)
        let speeds = (0..<count).map { Self.speed(at: start + Double($0) / hz, fixes: fixes) }
        return SynchronizedWindow(hz: hz, startUptime: start, linearAccelerationMS2: linear,
                                  gravityG: gravity, rotationRadPerSecond: rotation, speedMPS: speeds,
                                  fixes: fixes.filter { $0.uptime >= start - 0.5 && $0.uptime <= end + 0.5 })
    }

    /// GPS speed at `time`: interpolated between reliable fixes, or the nearest reliable fix within 2 s.
    static func speed(at time: TimeInterval, fixes: [LocationSample]) -> Double? {
        let reliable = fixes.filter { $0.isValid && $0.speedMPS >= 0 && $0.speedAccuracy >= 0 && $0.speedAccuracy <= 3 &&
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        if let before = reliable.last(where: { $0.uptime <= time }), let after = reliable.first(where: { $0.uptime >= time }),
           after.uptime - before.uptime <= 3 {
            let span = after.uptime - before.uptime
            let f = span > 0 ? (time - before.uptime) / span : 0
            return before.speedMPS + (after.speedMPS - before.speedMPS) * f
        }
        let nearest = reliable.min { abs($0.uptime - time) < abs($1.uptime - time) }
        guard let nearest, abs(nearest.uptime - time) <= 2 else { return nil }
        return nearest.speedMPS
    }

    private static func lerp(_ a: SensorVector, _ b: SensorVector, _ f: Double) -> SensorVector {
        SensorVector(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f)
    }
}

/// Uniformly sampled, synchronized slice of the history: the input contract shared by the
/// transport-mode classifier, the harsh-event rules and the backend (`Backend/rag/motion_intel.py`).
nonisolated struct SynchronizedWindow: Sendable, Equatable {
    /// The transport repo's IMU contract: 50 Hz, 250 samples (5 s).
    static let contractHz = 50.0
    static let contractSamples = 250

    var hz: Double
    var startUptime: TimeInterval
    /// Gravity removed, m/s² (device frame).
    var linearAccelerationMS2: [SensorVector]
    var gravityG: [SensorVector]
    var rotationRadPerSecond: [SensorVector]
    /// Per sample; nil where no reliable GPS speed is near.
    var speedMPS: [Double?]
    var fixes: [LocationSample]

    var count: Int { linearAccelerationMS2.count }
    var duration: TimeInterval { Double(count) / hz }
}

nonisolated extension SensorVector {
    static let standardGravity = 9.80665

    static func * (lhs: SensorVector, rhs: Double) -> SensorVector {
        SensorVector(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func - (lhs: SensorVector, rhs: SensorVector) -> SensorVector {
        SensorVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    func dot(_ other: SensorVector) -> Double { x * other.x + y * other.y + z * other.z }
}
