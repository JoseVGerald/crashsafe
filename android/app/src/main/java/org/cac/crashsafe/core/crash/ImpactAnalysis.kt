package org.cac.crashsafe.core.crash

import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHistory
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorVector
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * How hard the hit was and how quickly the car stopped, measured by the phone's accelerometer
 * and GPS around the impact. An estimate from a phone in the cabin, not a vehicle crash recorder.
 */
@Serializable
data class ImpactReport(
    /** Highest acceleration in the impact pulse (gravity removed), g. */
    val peakG: Double,
    /** How long the hit lasted: the contiguous pulse around the peak. */
    val pulseDuration: Double,
    /** Speed change during the pulse, from integrating the acceleration vector, m/s. */
    val deltaVMPS: Double,
    /** GPS speed just before the hit, m/s. */
    val preImpactSpeedMPS: Double? = null,
    /** GPS speed a few seconds after, m/s. */
    val postImpactSpeedMPS: Double? = null,
    /** From the hit until the car was stopped. */
    val timeToStop: Double? = null,
    /** What `timeToStop` is based on: "gps" (speed under 0.5 m/s) or "motion" (the phone settled). */
    val stopBasis: String? = null,
    /** Average deceleration from the pre-impact speed to a stop, g. */
    val averageStopDecelerationG: Double? = null,
    val severity: Severity,
    val isSimulated: Boolean,
) {
    @Serializable
    enum class Severity(val label: String) { minor("Minor"), moderate("Moderate"), severe("Severe") }

    val deltaVMPH: Double get() = deltaVMPS * 2.23694
    val preImpactSpeedMPH: Double? get() = preImpactSpeedMPS?.let { it * 2.23694 }
}

object ImpactAnalyzer {
    /**
     * Δv bands (m/s): under ~7 mph minor; ~7–16 mph moderate; above ~16 mph (≈25 km/h) severe —
     * roughly where crash-injury risk curves rise sharply. Peak g above 20 also counts as severe.
     */
    const val moderateDeltaV = 3.0
    const val severeDeltaV = 7.0

    /** Analyzes the history around `impactUptime`. Needs motion from 0.5 s before to 1 s after. */
    fun analyze(history: SensorHistory, impactUptime: Double, isSimulated: Boolean = false): ImpactReport? {
        val t = impactUptime
        val samples = history.motion(t - 1, t + 10)
        val around = samples.filter { abs(it.uptime - t) <= 0.5 }
        val peak = around.maxByOrNull { it.accelerationG.magnitude } ?: return null
        if (samples.none { it.uptime >= t + 1 }) return null
        val peakG = peak.accelerationG.magnitude

        // The pulse: contiguous samples around the peak above max(0.8 g, 20% of the peak).
        val threshold = max(0.8, peakG * 0.2)
        val peakIndex = samples.indexOf(peak)
        if (peakIndex < 0) return null
        var lo = peakIndex
        var hi = peakIndex
        while (lo > 0 && samples[lo - 1].accelerationG.magnitude >= threshold) lo--
        while (hi + 1 < samples.size && samples[hi + 1].accelerationG.magnitude >= threshold) hi++
        // Include one sample either side so the ramp into and out of the pulse is integrated too.
        val pulse = samples.subList(max(lo - 1, 0), minOf(hi + 1, samples.size - 1) + 1)

        // Δv = |∫ a dt| over the pulse (vector integral, trapezoids), in m/s.
        var dv = SensorVector.zero
        for ((a, b) in pulse.zipWithNext()) {
            val dt = b.uptime - a.uptime
            dv += (a.accelerationG + b.accelerationG) * (0.5 * dt * SensorVector.standardGravity)
        }
        if (pulse.size == 1) dv = peak.accelerationG * (0.01 * SensorVector.standardGravity)
        val pulseDuration = max((pulse.lastOrNull()?.uptime ?: t) - (pulse.firstOrNull()?.uptime ?: t), 0.01)
        val pulseEnd = pulse.lastOrNull()?.uptime ?: t

        val fixes = history.locations(t - 6, t + 30)
        val pre = median(fixes.filter { it.uptime >= t - 4 && it.uptime <= t - 0.2 && reliable(it) }.map { it.speedMPS })
        val post = median(fixes.filter { it.uptime >= t + 2 && it.uptime <= t + 8 && reliable(it) }.map { it.speedMPS })

        var timeToStop: Double? = null
        var stopBasis: String? = null
        val stopped = fixes.firstOrNull { it.uptime > t && reliable(it) && it.speedMPS < 0.5 }
        if (stopped != null) {
            timeToStop = max(stopped.uptime - t, pulseDuration)
            stopBasis = "gps"
        } else {
            val settled = settleTime(samples.filter { it.uptime > pulseEnd })
            if (settled != null) {
                timeToStop = max(settled - t, pulseDuration)
                stopBasis = "motion"
            }
        }
        val decel = if (pre != null && timeToStop != null && timeToStop > 0 && pre > 0.5) {
            pre / timeToStop / SensorVector.standardGravity
        } else null

        val deltaV = dv.magnitude
        val severity = when {
            deltaV >= severeDeltaV || peakG >= 20 -> ImpactReport.Severity.severe
            deltaV >= moderateDeltaV || peakG >= 8 -> ImpactReport.Severity.moderate
            else -> ImpactReport.Severity.minor
        }
        return ImpactReport(peakG = peakG, pulseDuration = pulseDuration, deltaVMPS = deltaV,
            preImpactSpeedMPS = pre, postImpactSpeedMPS = post, timeToStop = timeToStop,
            stopBasis = stopBasis, averageStopDecelerationG = decel, severity = severity, isSimulated = isSimulated)
    }

    /** First time the 1 s rolling RMS of acceleration drops under 0.08 g (the phone, and so the car, settled). */
    fun settleTime(after: List<MotionSample>): Double? {
        val window = ArrayDeque<MotionSample>()
        for (sample in after) {
            window.addLast(sample)
            while (window.isNotEmpty() && sample.uptime - window.first().uptime > 1) window.removeFirst()
            val first = window.firstOrNull() ?: continue
            if (sample.uptime - first.uptime < 0.9) continue
            val rms = sqrt(window.sumOf { it.accelerationG.magnitude * it.accelerationG.magnitude } / window.size)
            if (rms < 0.08) return first.uptime
        }
        return null
    }

    fun reliable(fix: LocationSample): Boolean =
        fix.isValid && fix.speedMPS >= 0 && fix.speedAccuracy >= 0 && fix.speedAccuracy <= 3 &&
            fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 50

    fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 0) (sorted[mid - 1] + sorted[mid]) / 2 else sorted[mid]
    }

    /**
     * A synthetic crash run through the real analysis, for test crashes: 35 mph, a 100 ms
     * half-sine pulse peaking at 10 g (Δv ≈ 6.2 m/s ≈ 14 mph), then braking to a stop.
     */
    fun simulatedReport(now: Double = 1_000.0): ImpactReport {
        val history = SensorHistory()
        val t0 = now - 15
        val impact = now - 8
        val pulse = 0.10
        val preSpeed = 15.6 // m/s ≈ 35 mph
        var step = 0
        var time = t0
        while (time <= now) {
            var a = SensorVector(0.0, 0.03 * sin(time * 7), 0.02)
            if (time >= impact && time <= impact + pulse) {
                val g = 10 * sin(PI * (time - impact) / pulse)
                a = SensorVector(0.0, -g, 0.1 * g)
            } else if (time > impact + pulse && time < impact + 2.6) {
                a = SensorVector(0.0, -0.38 + 0.04 * sin(time * 11), 0.05)
            } else if (time >= impact + 2.6) {
                a = SensorVector(0.003, 0.002, 0.004)
            }
            history.append(SensorReading.Motion(MotionSample(uptime = time, date = time, accelerationG = a,
                gravityG = SensorVector(0.0, 0.0, -1.0), rotationRate = SensorVector.zero)))
            if (step % 100 == 0) {
                val speed = if (time < impact) preSpeed else max(0.0, 9 - (time - impact) * 3.6)
                history.append(SensorReading.Location(LocationSample(uptime = time, date = time,
                    latitude = 45.5, longitude = -122.6, horizontalAccuracy = 5.0, speedMPS = speed, speedAccuracy = 0.5)))
            }
            step++
            time = t0 + step * 0.01
        }
        return analyze(history, impact, isSimulated = true)
            ?: ImpactReport(peakG = 10.0, pulseDuration = pulse, deltaVMPS = 6.2, preImpactSpeedMPS = preSpeed,
                postImpactSpeedMPS = 0.0, timeToStop = 2.5, stopBasis = "gps", averageStopDecelerationG = 0.64,
                severity = ImpactReport.Severity.moderate, isSimulated = true)
    }
}
