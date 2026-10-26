package org.cac.crashsafe.core.sensors

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Rolling, synchronized sensor history: full acceleration and gravity vectors, rotation, and GPS,
 * kept on the device for analyzing an event (impact metrics, transport mode, harsh events).
 * Bounded memory; nothing here is saved to disk or uploaded.
 */
class SensorHistory {
    val motion = SensorRing<MotionSample>(motionCapacity)
    val locations = SensorRing<LocationSample>(locationCapacity)
    private var lastMotion: Double? = null
    private var lastLocation: Double? = null

    val latestMotionUptime: Double? get() = lastMotion

    /** Keeps only valid, strictly increasing samples (the same rule as `SensorHub` and `CrashPipeline`). */
    fun append(reading: SensorReading): Boolean {
        when (reading) {
            is SensorReading.Motion -> {
                val sample = reading.sample
                if (!sample.isValid || !(lastMotion?.let { sample.uptime > it } ?: true)) return false
                lastMotion = sample.uptime
                motion.append(sample)
            }
            is SensorReading.Location -> {
                val fix = reading.sample
                if (!fix.isValid || !(lastLocation?.let { fix.uptime > it } ?: true)) return false
                lastLocation = fix.uptime
                locations.append(fix)
            }
        }
        return true
    }

    fun motion(from: Double, to: Double): List<MotionSample> = motion.values.filter { it.uptime >= from && it.uptime <= to }

    fun locations(from: Double, to: Double): List<LocationSample> = locations.values.filter { it.uptime >= from && it.uptime <= to }

    /**
     * A uniformly sampled window ending at `end`, or null when the history doesn't fully cover it
     * or has a gap — the analysis fails closed instead of inventing samples.
     */
    fun window(endingAt: Double, duration: Double, hz: Double = SynchronizedWindow.contractHz,
               maximumGap: Double = 0.25): SynchronizedWindow? {
        val end = endingAt
        if (hz <= 0 || duration <= 0 || !end.isFinite()) return null
        val count = (duration * hz).roundToInt()
        val start = end - (count - 1) / hz
        val samples = motion(start - maximumGap, end + maximumGap)
        val first = samples.firstOrNull() ?: return null
        val last = samples.last()
        if (first.uptime > start + 0.5 / hz || last.uptime < end - 0.5 / hz) return null
        if (samples.zipWithNext().any { (a, b) -> b.uptime - a.uptime > maximumGap }) return null

        val linear = ArrayList<SensorVector>(count)
        val gravity = ArrayList<SensorVector>(count)
        val rotation = ArrayList<SensorVector>(count)
        var j = 0
        for (i in 0 until count) {
            val t = start + i / hz
            while (j + 1 < samples.size && samples[j + 1].uptime < t) j++
            val a = samples[j]
            val b = samples[minOf(j + 1, samples.size - 1)]
            val span = b.uptime - a.uptime
            val f = if (span > 0) ((t - a.uptime) / span).coerceIn(0.0, 1.0) else 0.0
            linear.add(lerp(a.accelerationG, b.accelerationG, f) * SensorVector.standardGravity)
            gravity.add(lerp(a.gravityG, b.gravityG, f))
            rotation.add(lerp(a.rotationRate, b.rotationRate, f))
        }
        val fixes = locations(start - 3, end + 0.5)
        val speeds = (0 until count).map { speed(start + it / hz, fixes) }
        return SynchronizedWindow(hz = hz, startUptime = start, linearAccelerationMS2 = linear,
            gravityG = gravity, rotationRadPerSecond = rotation, speedMPS = speeds,
            fixes = fixes.filter { it.uptime >= start - 0.5 && it.uptime <= end + 0.5 })
    }

    companion object {
        /** ~32 s of motion at 100 Hz. */
        const val motionCapacity = 3_200
        /** ~4 min of GPS at 1 Hz. */
        const val locationCapacity = 240

        /** GPS speed at `time`: interpolated between reliable fixes, or the nearest reliable fix within 2 s. */
        fun speed(time: Double, fixes: List<LocationSample>): Double? {
            val reliable = fixes.filter {
                it.isValid && it.speedMPS >= 0 && it.speedAccuracy >= 0 && it.speedAccuracy <= 3 &&
                    it.horizontalAccuracy >= 0 && it.horizontalAccuracy <= 50
            }
            val before = reliable.lastOrNull { it.uptime <= time }
            val after = reliable.firstOrNull { it.uptime >= time }
            if (before != null && after != null && after.uptime - before.uptime <= 3) {
                val span = after.uptime - before.uptime
                val f = if (span > 0) (time - before.uptime) / span else 0.0
                return before.speedMPS + (after.speedMPS - before.speedMPS) * f
            }
            val nearest = reliable.minByOrNull { abs(it.uptime - time) } ?: return null
            if (abs(nearest.uptime - time) > 2) return null
            return nearest.speedMPS
        }

        private fun lerp(a: SensorVector, b: SensorVector, f: Double) =
            SensorVector(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f)
    }
}

/**
 * Uniformly sampled, synchronized slice of the history: the input contract shared by the
 * transport-mode classifier, the harsh-event rules and the backend (`Backend/rag/motion_intel.py`).
 */
data class SynchronizedWindow(
    val hz: Double,
    val startUptime: Double,
    /** Gravity removed, m/s² (device frame). */
    val linearAccelerationMS2: List<SensorVector>,
    val gravityG: List<SensorVector>,
    val rotationRadPerSecond: List<SensorVector>,
    /** Per sample; null where no reliable GPS speed is near. */
    val speedMPS: List<Double?>,
    val fixes: List<LocationSample>,
) {
    val count: Int get() = linearAccelerationMS2.size
    val duration: Double get() = count / hz

    companion object {
        /** The transport repo's IMU contract: 50 Hz, 250 samples (5 s). */
        const val contractHz = 50.0
        const val contractSamples = 250
    }
}
