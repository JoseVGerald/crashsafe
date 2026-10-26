package org.cac.crashsafe.core.sensors

import kotlinx.serialization.Serializable
import kotlin.math.sqrt

/** Physical units are preserved here. Classifier normalization belongs in its own adapter. */
@Serializable
data class SensorVector(val x: Double, val y: Double, val z: Double) {
    val magnitude: Double get() = sqrt(x * x + y * y + z * z)
    val isFinite: Boolean get() = x.isFinite() && y.isFinite() && z.isFinite() && magnitude.isFinite()

    operator fun plus(other: SensorVector) = SensorVector(x + other.x, y + other.y, z + other.z)
    operator fun minus(other: SensorVector) = SensorVector(x - other.x, y - other.y, z - other.z)
    operator fun times(scale: Double) = SensorVector(x * scale, y * scale, z * scale)
    fun dot(other: SensorVector): Double = x * other.x + y * other.y + z * other.z

    companion object {
        val zero = SensorVector(0.0, 0.0, 0.0)
        const val standardGravity = 9.80665
    }
}

/**
 * One reading of the phone's motion, in Core Motion's conventions (the iOS app's, shared with the backend):
 * user acceleration and gravity in g, gravity pointing down (flat, face up: (0, 0, -1)), rotation in rad/s.
 * `AndroidMotionSource` converts Android's sensors into this frame.
 */
@Serializable
data class MotionSample(
    /** Monotonic seconds since boot. Use for durations and stream alignment. */
    val uptime: Double,
    /** Wall clock, seconds since 1970. */
    val date: Double,
    val accelerationG: SensorVector,
    val gravityG: SensorVector,
    /** Radians per second. */
    val rotationRate: SensorVector,
) {
    val totalAccelerationG: SensorVector get() = accelerationG + gravityG
    val isValid: Boolean
        get() = uptime.isFinite() && uptime >= 0 && date.isFinite() &&
            accelerationG.isFinite && gravityG.isFinite && rotationRate.isFinite
}

@Serializable
data class LocationSample(
    val uptime: Double,
    val date: Double,
    val latitude: Double,
    val longitude: Double,
    /** Meters; negative means unavailable. */
    val horizontalAccuracy: Double,
    /** Meters per second; negative means unavailable. */
    val speedMPS: Double,
    /** Meters per second; negative means unavailable. */
    val speedAccuracy: Double,
) {
    val isValid: Boolean
        get() = uptime.isFinite() && uptime >= 0 && date.isFinite() &&
            latitude.isFinite() && latitude in -90.0..90.0 &&
            longitude.isFinite() && longitude in -180.0..180.0 &&
            horizontalAccuracy.isFinite() && speedMPS.isFinite() && speedAccuracy.isFinite()

    fun hasReliableSpeed(time: Double, maximumAge: Double = 2.0): Boolean =
        isValid && uptime <= time && time - uptime <= maximumAge &&
            horizontalAccuracy >= 0 && horizontalAccuracy <= 50 &&
            speedMPS >= 0 && speedAccuracy >= 0 && speedAccuracy <= 3
}

enum class SensorState { stopped, starting, active, unavailable, permissionDenied, interrupted, stale }

data class SensorHealth(
    val state: SensorState = SensorState.stopped,
    val requestedHz: Double = 100.0,
    val measuredHz: Double = 0.0,
    val rejectedMotionSamples: Int = 0,
    val rejectedLocationSamples: Int = 0,
    val motionGaps: Int = 0,
    val locationUnavailable: Boolean = false,
)

sealed interface SensorReading {
    val uptime: Double

    data class Motion(val sample: MotionSample) : SensorReading {
        override val uptime: Double get() = sample.uptime
    }

    data class Location(val sample: LocationSample) : SensorReading {
        override val uptime: Double get() = sample.uptime
    }

    /** The same reading moved in time (for replaying a clip on the live clock). */
    fun shifted(offset: Double, dateOffset: Double? = null): SensorReading {
        val d = dateOffset ?: offset
        return when (this) {
            is Motion -> Motion(sample.copy(uptime = sample.uptime + offset, date = sample.date + d))
            is Location -> Location(sample.copy(uptime = sample.uptime + offset, date = sample.date + d))
        }
    }
}

/** Fixed storage; a long trip cannot grow the detector's memory indefinitely. */
class SensorRing<T : Any>(capacity: Int) {
    private val storage = arrayOfNulls<Any>(capacity)
    private var next = 0
    var count = 0
        private set

    init {
        require(capacity > 0)
    }

    fun append(element: T) {
        storage[next] = element
        next = (next + 1) % storage.size
        count = minOf(count + 1, storage.size)
    }

    @Suppress("UNCHECKED_CAST")
    val values: List<T>
        get() {
            val start = if (count == storage.size) next else 0
            return (0 until count).map { storage[(start + it) % storage.size] as T }
        }

    val last: T?
        @Suppress("UNCHECKED_CAST")
        get() = if (count == 0) null else storage[(next - 1 + storage.size) % storage.size] as T
}
