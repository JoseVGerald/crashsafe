import Foundation

/// Physical units are preserved here. Classifier normalization belongs in its own adapter.
nonisolated struct SensorVector: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = SensorVector(x: 0, y: 0, z: 0)
    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && magnitude.isFinite }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }
}

nonisolated struct MotionSample: Codable, Equatable, Sendable {
    /// Core Motion's monotonic seconds since boot. Use for durations and stream alignment.
    var uptime: TimeInterval
    var date: Date
    var accelerationG: SensorVector
    var gravityG: SensorVector
    var rotationRate: SensorVector // radians / second

    var totalAccelerationG: SensorVector { accelerationG + gravityG }
    var isValid: Bool {
        uptime.isFinite && uptime >= 0 && date.timeIntervalSince1970.isFinite &&
        accelerationG.isFinite && gravityG.isFinite && rotationRate.isFinite
    }
}

nonisolated struct LocationSample: Codable, Equatable, Sendable {
    var uptime: TimeInterval
    var date: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double // meters; negative means unavailable
    var speedMPS: Double // meters / second; negative means unavailable
    var speedAccuracy: Double // meters / second; negative means unavailable

    var isValid: Bool {
        uptime.isFinite && uptime >= 0 && date.timeIntervalSince1970.isFinite &&
        latitude.isFinite && (-90...90).contains(latitude) &&
        longitude.isFinite && (-180...180).contains(longitude) &&
        horizontalAccuracy.isFinite && speedMPS.isFinite && speedAccuracy.isFinite
    }

    func hasReliableSpeed(at time: TimeInterval, maximumAge: TimeInterval = 2) -> Bool {
        isValid && uptime <= time && time - uptime <= maximumAge &&
        horizontalAccuracy >= 0 && horizontalAccuracy <= 50 &&
        speedMPS >= 0 && speedAccuracy >= 0 && speedAccuracy <= 3
    }
}

nonisolated enum SensorState: String, Sendable {
    case stopped, starting, active, unavailable, permissionDenied, interrupted, stale
}

nonisolated struct SensorHealth: Equatable, Sendable {
    var state: SensorState = .stopped
    var requestedHz: Double = 100
    var measuredHz: Double = 0
    var rejectedMotionSamples = 0
    var rejectedLocationSamples = 0
    var motionGaps = 0
    var locationUnavailable = false
}

nonisolated enum SensorReading: Sendable {
    case motion(MotionSample)
    case location(LocationSample)
}
