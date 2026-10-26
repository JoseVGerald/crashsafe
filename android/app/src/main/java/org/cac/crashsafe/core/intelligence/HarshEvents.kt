package org.cac.crashsafe.core.intelligence

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorVector
import org.cac.crashsafe.core.sensors.SynchronizedWindow
import kotlin.math.abs
import kotlin.math.max

/**
 * Port of the transport repo's rule-based harsh-driving detector (src/behavior/events.py) for the
 * two longitudinal events. The repo projects acceleration onto a mount-dependent heading axis; the
 * phone's mount is unknown here, so longitudinal acceleration comes from the GPS speed change
 * instead. Like the backend adapter, cornering, instability and speeding (fixed threshold, no posted
 * limit) are not reported. No event decides a crash or fault.
 */
@Serializable
data class HarshEvent(
    val kind: Kind,
    /** Seconds from the start of the analyzed window. */
    val start: Double,
    val end: Double,
    /** 0…1 */
    val severity: Double,
) {
    @Serializable
    enum class Kind(val raw: String) {
        @SerialName("harsh_brake") harshBrake("harsh_brake"),
        @SerialName("harsh_accel") harshAccel("harsh_accel"),
    }
}

class HarshEventDetector(
    // EventConfig defaults from events.py, in g.
    val brakeLowG: Double = 0.25,
    val brakeHighG: Double = 0.45,
    val accelLowG: Double = 0.30,
    val accelHighG: Double = 0.50,
    val minDuration: Double = 1.0,
    val mergeGap: Double = 1.5,
) {
    fun detect(window: SynchronizedWindow): List<HarshEvent> {
        val n = window.count
        if (n <= 2) return emptyList()
        val half = max(1, (window.hz / 2).toInt()) // central difference over ~1 s
        val events = mutableListOf<HarshEvent>()
        var active: HarshEvent? = null

        fun close(t: Double) {
            val event = active ?: return
            val closed = event.copy(end = t)
            if (closed.end - closed.start >= minDuration) events.add(closed)
            active = null
        }

        for (i in 0 until n) {
            val t = i / window.hz
            var kind: HarshEvent.Kind? = null
            var severity = 0.0
            val a = window.speedMPS[max(0, i - half)]
            val b = window.speedMPS[minOf(n - 1, i + half)]
            if (a != null && b != null) {
                val dt = (minOf(n - 1, i + half) - max(0, i - half)) / window.hz
                val signed = if (dt > 0) (b - a) / dt / SensorVector.standardGravity else 0.0
                if (signed <= -brakeLowG) {
                    kind = HarshEvent.Kind.harshBrake
                    severity = severity(-signed, brakeLowG, brakeHighG)
                } else if (signed >= accelLowG) {
                    kind = HarshEvent.Kind.harshAccel
                    severity = severity(signed, accelLowG, accelHighG) * 0.8
                }
            }
            if (kind != null) {
                val current = active
                if (current != null && current.kind == kind) {
                    active = current.copy(end = t, severity = max(current.severity, severity))
                } else {
                    close(t)
                    active = HarshEvent(kind = kind, start = t, end = t, severity = severity)
                }
            } else {
                close(t)
            }
        }
        close(n / window.hz)

        val merged = mutableListOf<HarshEvent>()
        for (event in events) {
            val last = merged.lastOrNull()
            if (last != null && last.kind == event.kind && event.start - last.end <= mergeGap) {
                merged[merged.size - 1] = last.copy(end = event.end, severity = max(last.severity, event.severity))
            } else {
                merged.add(event)
            }
        }
        return merged
    }

    companion object {
        fun severity(x: Double, lo: Double, hi: Double): Double = ((x - lo) / max(hi - lo, 1e-6)).coerceIn(0.0, 1.0)
    }
}

/**
 * Live hard-braking / hard-acceleration detector from the phone's own motion, whatever way it sits.
 *
 * GPS alone (1 fix a second, smoothed by the chip) missed real hard stops. Measured on the labeled
 * driverBehaviorDataset trips: aggressive braking shows 0.30–0.50 g of horizontal acceleration for
 * 0.7–2 s while the car barely turns (≤ 0.10 rad/s about vertical); hard turns and lane changes reach
 * similar g but turn at 0.17–0.74 rad/s. So: horizontal g ≥ `thresholdG` for ≥ `minDuration` with
 * turn rate under `maxYawRate`. Whether it was a brake or a speed-up comes from GPS speed.
 */
class LongitudinalEventDetector(
    val thresholdG: Double = 0.25,
    val minDuration: Double = 0.7,
    val maxYawRate: Double = 0.10,
    /** One event per this many seconds. */
    val refractory: Double = 3.0,
) {
    private data class Accel(val t: Double, val x: Double, val y: Double, val z: Double)
    private data class Yaw(val t: Double, val yaw: Double)

    private val accelWindow = ArrayDeque<Accel>()
    private val yawWindow = ArrayDeque<Yaw>()
    private var aboveSince: Double? = null
    private var peak = 0.0
    private var lastEvent = Double.NEGATIVE_INFINITY

    /** Returns the peak horizontal g when a hard longitudinal event has just been confirmed. */
    fun add(s: MotionSample): Double? {
        if (!s.isValid) return null
        val t = s.uptime
        val g = s.gravityG
        val m = g.magnitude
        if (m <= 0.2) return null
        val down = g * (1 / m)
        val a = s.accelerationG
        val horizontal = a - down * a.dot(down)
        accelWindow.addLast(Accel(t, horizontal.x, horizontal.y, horizontal.z))
        accelWindow.removeAll { t - it.t > 0.5 }
        yawWindow.addLast(Yaw(t, abs(s.rotationRate.dot(down))))
        yawWindow.removeAll { t - it.t > 1.0 }
        // 0.5 s average of the horizontal vector (vibration cancels, braking doesn't).
        val n = accelWindow.size.toDouble()
        val avg = SensorVector(accelWindow.sumOf { it.x } / n, accelWindow.sumOf { it.y } / n,
            accelWindow.sumOf { it.z } / n).magnitude
        val yaw = yawWindow.sumOf { it.yaw } / yawWindow.size
        if (avg < thresholdG || yaw >= maxYawRate) {
            aboveSince = null
            peak = 0.0
            return null
        }
        val since = aboveSince ?: t.also { aboveSince = it }
        peak = max(peak, avg)
        if (t - since < minDuration || t - lastEvent < refractory) return null
        lastEvent = t
        val result = peak
        aboveSince = null
        peak = 0.0
        return result
    }
}
