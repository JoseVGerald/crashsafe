package org.cac.crashsafe.core.sensors

import org.cac.crashsafe.core.crash.CrashEvaluationConfiguration
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The math behind the Sensor Lab screen: how the phone is tilted, how hard it is being shaken or
 * turned, and how fast GPS says it is going. Pure values, so the same numbers are unit-tested
 * on a computer and replayed against recorded clips.
 *
 * Device frame: x to the right of the screen, y toward the top, z out of the screen.
 * Gravity is reported pointing down (lying flat face up it reads (0, 0, −1) g).
 */
object SensorLabMath {
    data class Tilt(
        /** Top edge raised (+) or lowered (−) from level, degrees. 90 = standing upright. */
        val pitch: Double,
        /** Right edge lowered (+) or raised (−), degrees. */
        val roll: Double,
        /** Angle between the screen and the sky: 0 = flat face up, 90 = upright, 180 = face down. */
        val fromFlat: Double,
    ) {
        /**
         * Where a bubble level's bubble sits, in a unit circle (x right, y down, as on screen).
         * Reaches the edge at 45° of tilt.
         */
        val bubble: Pair<Double, Double>
            get() {
                val r = sin(fromFlat * PI / 180)
                if (r <= 1e-9) return 0.0 to 0.0
                // Projection of "up" onto the screen: the bubble floats toward the raised edge.
                val px = -sin(roll * PI / 180)
                val py = -sin(pitch * PI / 180)
                val scale = minOf(1.0, r / sin(PI / 4)) / maxOf(1e-9, sqrt(px * px + py * py))
                return px * scale to py * scale
            }
    }

    fun tilt(gravity: SensorVector): Tilt? {
        val m = gravity.magnitude
        if (!gravity.isFinite || m <= 0.2) return null
        val x = gravity.x / m
        val y = gravity.y / m
        val z = gravity.z / m
        fun degrees(r: Double) = r * 180 / PI
        return Tilt(pitch = degrees(asin((-y).coerceIn(-1.0, 1.0))),
            roll = degrees(asin(x.coerceIn(-1.0, 1.0))),
            fromFlat = degrees(acos((-z).coerceIn(-1.0, 1.0))))
    }

    /**
     * Splits user acceleration (g) into the part along gravity (bumps, potholes, drops) and the part
     * across it (braking, speeding up, turning), whichever way the phone is held or mounted.
     */
    fun split(a: SensorVector, gravity: SensorVector): Pair<Double, Double> {
        val m = gravity.magnitude
        if (m <= 0.2) return a.magnitude to 0.0
        val down = gravity * (1 / m)
        val along = a.dot(down)
        return (a - down * along).magnitude to abs(along)
    }

    /** Speeding up (+) or slowing down (−), in g, from two GPS fixes 0.5–5 s apart. */
    fun longitudinalG(from: LocationSample, to: LocationSample): Double? {
        val dt = to.uptime - from.uptime
        if (!from.isValid || !to.isValid || from.speedMPS < 0 || to.speedMPS < 0 || dt < 0.5 || dt > 5) return null
        return (to.speedMPS - from.speedMPS) / dt / SensorVector.standardGravity
    }

    /** GPS course (degrees, 0 = north) as a compass word. */
    fun compass(degrees: Double): String {
        if (!degrees.isFinite() || degrees < 0) return "–"
        val names = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")
        return names[(degrees / 45).roundToInt() % 8]
    }
}

/** A quick change in motion: user acceleration rising over a threshold and falling back. */
data class Jolt(
    val uptime: Double,
    val date: Double,
    val peakG: Double,
    val duration: Double,
    val peakRotation: Double,
    val peakJerk: Double,
    val kind: Kind,
) {
    enum class Kind(val title: String) {
        /** Strong enough that the crash detector would examine it (`CrashEvaluationConfiguration.candidateG`). */
        crashLevel("Crash-level hit"),
        /** A hit after a moment of free fall: what dropping the phone looks like. */
        drop("Phone drop"),
        hard("Hard jolt"),
        bump("Bump"),
    }
}

/** Finds jolts in a live motion stream and tracks jerk (how fast acceleration changes, g/s). */
class JoltTracker {
    var threshold = 0.5
    var hardG = 1.5
    var crashG = CrashEvaluationConfiguration().candidateG
    val jolts = mutableListOf<Jolt>()
    /** Smoothed jerk, g/s. */
    var jerk = 0.0
        private set
    private var open: Jolt? = null
    private var previous: MotionSample? = null
    private var freeFallStart: Double? = null
    private var lastFreeFall: Pair<Double, Double>? = null

    /** Returns the jolt that just ended, if any. */
    fun add(s: MotionSample): Jolt? {
        if (!s.isValid) return null
        try {
            var sampleJerk = 0.0
            val p = previous
            if (p != null && s.uptime > p.uptime) {
                sampleJerk = (s.accelerationG - p.accelerationG).magnitude / (s.uptime - p.uptime)
                jerk += (sampleJerk - jerk) * 0.2
            }
            // Free fall: the accelerometer reads almost nothing (the same 0.25 g rule as the evaluator).
            if (s.totalAccelerationG.magnitude < 0.25) {
                if (freeFallStart == null) freeFallStart = s.uptime
            } else {
                freeFallStart?.let { start ->
                    lastFreeFall = start to s.uptime
                    freeFallStart = null
                }
            }
            val g = s.accelerationG.magnitude
            if (g >= threshold && freeFallStart == null) {
                val current = open
                open = if (current == null) {
                    Jolt(uptime = s.uptime, date = s.date, peakG = g, duration = 0.0, peakRotation = s.rotationRate.magnitude,
                        peakJerk = sampleJerk, kind = Jolt.Kind.bump)
                } else {
                    current.copy(peakG = maxOf(current.peakG, g),
                        peakRotation = maxOf(current.peakRotation, s.rotationRate.magnitude),
                        peakJerk = maxOf(current.peakJerk, sampleJerk),
                        duration = s.uptime - current.uptime)
                }
                return null
            }
            val jolt = open ?: return null
            open = null
            val fellFirst = lastFreeFall?.let { (start, end) -> jolt.uptime - end < 0.1 && end - start >= 0.06 } ?: false
            val kind = when {
                fellFirst -> Jolt.Kind.drop
                jolt.peakG >= crashG -> Jolt.Kind.crashLevel
                jolt.peakG >= hardG -> Jolt.Kind.hard
                else -> Jolt.Kind.bump
            }
            val finished = jolt.copy(kind = kind)
            jolts.add(finished)
            if (jolts.size > 30) repeat(jolts.size - 30) { jolts.removeAt(0) }
            return finished
        } finally {
            previous = s
        }
    }

    fun reset() {
        jolts.clear()
        jerk = 0.0
        open = null
        previous = null
        freeFallStart = null
        lastFreeFall = null
    }
}

/**
 * CSV for recordings made in the Sensor Lab and clips replayed into the app.
 * Motion rows fill the motion columns; GPS rows fill only speed and accuracy — never coordinates,
 * so a shared recording doesn't reveal where it was made.
 */
object SensorCSV {
    const val header = "t,ax,ay,az,gx,gy,gz,rx,ry,rz,speed,speed_acc,h_acc"

    fun encode(readings: List<SensorReading>): String {
        val origin = readings.minOfOrNull { it.uptime } ?: 0.0
        val builder = StringBuilder(header).append('\n')
        fun f(x: Double) = String.format(Locale.US, "%.5f", x)
        for (reading in readings) {
            when (reading) {
                is SensorReading.Motion -> {
                    val m = reading.sample
                    val a = m.accelerationG
                    val g = m.gravityG
                    val r = m.rotationRate
                    builder.append(listOf(f(m.uptime - origin), f(a.x), f(a.y), f(a.z), f(g.x), f(g.y), f(g.z),
                        f(r.x), f(r.y), f(r.z), "", "", "").joinToString(","))
                }
                is SensorReading.Location -> {
                    val l = reading.sample
                    builder.append(listOf(f(l.uptime - origin), "", "", "", "", "", "", "", "", "",
                        f(l.speedMPS), f(l.speedAccuracy), f(l.horizontalAccuracy)).joinToString(","))
                }
            }
            builder.append('\n')
        }
        return builder.toString()
    }

    /** Readings with uptimes starting at `start`. Rows that don't parse are skipped. */
    fun decode(text: String, start: Double = 0.0, date: Double = 978_307_200.0): List<SensorReading> {
        val out = mutableListOf<SensorReading>()
        for (line in text.lineSequence().drop(1)) {
            if (line.isBlank()) continue
            val cells = line.split(",").map { it.trim().toDoubleOrNull() }
            if (cells.size < 13) continue
            val t = cells[0] ?: continue
            if (!t.isFinite()) continue
            val whenDate = date + t
            val motion = cells.subList(1, 10)
            if (motion.all { it != null }) {
                val v = motion.map { it!! }
                out.add(SensorReading.Motion(MotionSample(uptime = start + t, date = whenDate,
                    accelerationG = SensorVector(v[0], v[1], v[2]), gravityG = SensorVector(v[3], v[4], v[5]),
                    rotationRate = SensorVector(v[6], v[7], v[8]))))
            } else {
                val speed = cells[10]
                val speedAccuracy = cells[11]
                val h = cells[12]
                if (speed != null && speedAccuracy != null && h != null) {
                    out.add(SensorReading.Location(LocationSample(uptime = start + t, date = whenDate, latitude = 0.0,
                        longitude = 0.0, horizontalAccuracy = h, speedMPS = speed, speedAccuracy = speedAccuracy)))
                }
            }
        }
        return out
    }
}
