package org.cac.crashsafe.core.crash

import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHistory
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorVector
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Repeatable pseudo-random numbers (SplitMix64), so a stress-test run can be reproduced exactly.
 * Draws use the same algorithms as Swift's `Double.random(in:using:)` and `Int.random(in:using:)`,
 * so a seed produces the same scenarios as the iOS app's StressLab.
 */
class SeededGenerator(seed: Long) {
    private var state: Long = seed

    fun next(): Long {
        state += -0x61c8864680b583ebL // 0x9E3779B97F4A7C15
        var z = state
        z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L // 0xBF58476D1CE4E5B9
        z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L // 0x94D049BB133111EB
        return z xor (z ushr 31)
    }

    /** Lemire's nearly divisionless bounded draw, as Swift's `next(upperBound:)` (unsigned 64-bit). */
    fun next(upperBound: Long): Long {
        var random = next()
        var low = random * upperBound
        if (java.lang.Long.compareUnsigned(low, upperBound) < 0) {
            val t = java.lang.Long.remainderUnsigned(-upperBound, upperBound)
            while (java.lang.Long.compareUnsigned(low, t) < 0) {
                random = next()
                low = random * upperBound
            }
        }
        return unsignedMultiplyHigh(random, upperBound)
    }

    /** `Double.random(in: lower...upper, using:)`. */
    fun uniform(lower: Double, upper: Double): Double {
        val maxSignificand = 1L shl 53
        val rand = next(maxSignificand + 1)
        if (rand == maxSignificand) return upper
        return (upper - lower) * (rand.toDouble() * ULP_HALF) + lower
    }

    /** `Double.random(in: 0..<1, using:)`. */
    fun unit(): Double {
        while (true) {
            val rand = next() and ((1L shl 53) - 1)
            val value = rand.toDouble() * ULP_HALF
            if (value != 1.0) return value
        }
    }

    /** `Int.random(in: 0..<upper, using:)`. */
    fun int(upper: Int): Int = next(upper.toLong()).toInt()

    /** Standard normal (Box–Muller). */
    fun gaussian(): Double {
        val u = max(unit(), 1e-12)
        val v = unit()
        return sqrt(-2 * ln(u)) * cos(2 * PI * v)
    }

    fun chance(p: Double): Boolean = unit() < p

    private companion object {
        /** `Double.ulpOfOne / 2` = 2⁻⁵³. */
        const val ULP_HALF = 1.1102230246251565E-16

        fun unsignedMultiplyHigh(a: Long, b: Long): Long {
            val aLo = a and 0xFFFFFFFFL
            val aHi = a ushr 32
            val bLo = b and 0xFFFFFFFFL
            val bHi = b ushr 32
            val loLo = aLo * bLo
            val hiLo = aHi * bLo
            val loHi = aLo * bHi
            val hiHi = aHi * bHi
            val cross = (loLo ushr 32) + (hiLo and 0xFFFFFFFFL) + loHi
            return hiHi + (hiLo ushr 32) + (cross ushr 32)
        }
    }
}

/**
 * How the phone sits in the car: the device's x (right), y (top) and z (out of the screen) axes,
 * written in the car's frame (x forward, y left, z up).
 */
data class PhoneMount(val name: String, val x: SensorVector, val y: SensorVector, val z: SensorVector) {
    /** A car-frame vector in the phone's frame. */
    fun device(v: SensorVector) = SensorVector(v.dot(x), v.dot(y), v.dot(z))

    /** Core Motion's gravity reading for this mount. */
    val gravity: SensorVector get() = device(SensorVector(0.0, 0.0, -1.0))

    companion object {
        /** Upright in a dash or vent mount, screen facing the driver. */
        val dash = PhoneMount("dash mount", SensorVector(0.0, -1.0, 0.0), SensorVector(0.0, 0.0, 1.0), SensorVector(-1.0, 0.0, 0.0))
        /** Lying flat on the console, top toward the windshield. */
        val console = PhoneMount("flat on console", SensorVector(0.0, -1.0, 0.0), SensorVector(1.0, 0.0, 0.0), SensorVector(0.0, 0.0, 1.0))
        /** In a pants pocket while seated. */
        val pocket = PhoneMount("pocket", SensorVector(0.0, 0.0, 1.0), SensorVector(1.0, 0.0, 0.0), SensorVector(0.0, 1.0, 0.0))
        /** Upright in a cup holder, leaning back. */
        val cupHolder = PhoneMount("cup holder", SensorVector(0.0, -1.0, 0.0),
            SensorVector(-0.342, 0.0, 0.940), SensorVector(-0.940, 0.0, -0.342))
        val standard = listOf(dash, console, pocket, cupHolder)

        /** Any orientation at all. */
        fun random(rng: SeededGenerator): PhoneMount {
            fun unit(v: SensorVector) = v * (1 / max(v.magnitude, 1e-9))
            val a = unit(SensorVector(rng.gaussian(), rng.gaussian(), rng.gaussian()))
            var b = SensorVector(rng.gaussian(), rng.gaussian(), rng.gaussian())
            b = unit(b - a * b.dot(a))
            val c = SensorVector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            return PhoneMount("random", a, b, c)
        }
    }
}

/**
 * One recorded (or generated) event as the phone would sense it: 100 Hz motion and 1 Hz GPS,
 * with the truth attached. Used by the stress test and replayed into the app.
 */
data class SensorScenario(
    val kind: Kind,
    val title: String,
    val readings: List<SensorReading>,
    /** When the event happens (impact, landing, bump), on the readings' clock. */
    val eventUptime: Double,
    /** The car's real speed change in the crash, m/s. */
    val trueDeltaVMPS: Double?,
    val mount: String,
    val detail: String,
) {
    enum class Kind(val title: String) {
        // Crashes: the app should start a check-in.
        frontalCrash("Frontal crash"),
        rearEndedWhileStopped("Rear-ended while stopped"),
        sideImpact("Side impact (T-bone)"),
        lowSpeedCrash("Low-speed crash (fender bender)"),
        // Not crashes: the app should stay quiet.
        phoneDropMoving("Phone dropped while driving"),
        phoneDropParked("Phone dropped while parked"),
        phoneFliesOffMountWhileBraking("Emergency stop, phone flies off mount"),
        pothole("Pothole"),
        speedBump("Speed bump"),
        roughRoad("Rough road / rail crossing"),
        hardBrake("Hard braking"),
        doorSlam("Door slam (phone in door pocket)"),
        phoneTossedOnSeat("Phone tossed onto seat"),
        normalDriving("Normal driving (60 s)");

        val isCrash: Boolean get() = this in listOf(frontalCrash, rearEndedWhileStopped, sideImpact, lowSpeedCrash)
    }
}

/**
 * Builds `SensorScenario`s from simple physics. Every number is drawn from a stated range so the
 * stress test covers the variety of real events rather than one hand-picked example.
 */
class ScenarioFactory(
    val hz: Double = 100.0,
    /** Per-axis accelerometer range, g (phones clip here; older ones ±8 g, newer ±16 g). */
    val saturationG: Double = 16.0,
    val start: Double = 1_000.0,
) {
    /** What the phone senses at one instant, already in the phone's frame. */
    data class PhoneState(val user: SensorVector, val gravity: SensorVector, val rotation: SensorVector)

    /**
     * The core renderer.
     * @param carAccel the car's acceleration at time t (s from start), car frame, g (pulses, braking, bumps).
     * @param yawRate the car's rotation about its vertical axis, rad/s.
     * @param speed the car's true speed (m/s) for GPS.
     * @param loose when the phone isn't moving with the car (falling, tumbling), its own reading.
     */
    fun render(kind: SensorScenario.Kind, duration: Double, eventTime: Double, mount: PhoneMount,
               vibration: Double, gpsLag: Double = 0.7, gpsOutage: ClosedFloatingPointRange<Double>? = null,
               quiet: ClosedFloatingPointRange<Double>? = null,
               hasGPS: Boolean = true, trueDeltaV: Double? = null, detail: String,
               rng: SeededGenerator,
               carAccel: (Double) -> SensorVector, yawRate: (Double) -> Double = { 0.0 },
               speed: (Double) -> Double, loose: ((Double) -> PhoneState?)? = null): SensorScenario {
        val readings = ArrayList<SensorReading>((duration * (hz + 1)).toInt())
        val count = (duration * hz).toInt()
        val gravity = mount.gravity
        // Smooth road sway plus white noise.
        val phases = (0 until 4).map { rng.uniform(0.0, 2 * PI) }
        val gpsPhase = rng.uniform(0.0, 0.99)
        var nextFix = gpsPhase
        var lat = 45.52
        for (k in 0 until count) {
            val t = k / hz
            // Average the continuous signal over the 10 ms sample (how the sensor's own filter behaves),
            // so a 4 ms spike reads as a smaller, wider one — as on a real phone.
            var user = SensorVector.zero
            var rotation = SensorVector.zero
            var g = gravity
            var looseCount = 0
            for (j in 0 until 10) {
                val tj = t - 1 / hz + (j + 0.5) / (10 * hz)
                val state = loose?.invoke(tj)
                if (state != null) {
                    user += state.user
                    rotation += state.rotation
                    g = state.gravity
                    looseCount++
                } else {
                    // Core Motion reports user acceleration opposite to the car's acceleration (its
                    // accelerometer reads −1 g on z lying flat); only magnitudes matter to the evaluator.
                    user += mount.device(carAccel(tj) * -1.0)
                    rotation += mount.device(SensorVector(0.0, 0.0, yawRate(tj)))
                }
            }
            user *= 0.1
            rotation *= 0.1
            if (looseCount == 0) g = gravity
            val sway = SensorVector(0.6 * sin(2 * PI * 1.3 * t + phases[0]), 0.4 * sin(2 * PI * 11 * t + phases[1]),
                0.5 * sin(2 * PI * 15 * t + phases[2]))
            // No road vibration reaches a phone in mid-air.
            val moving = speed(t) > 0.5 && !(quiet?.contains(t) ?: false)
            val level = if (moving) vibration else vibration * 0.15
            user = user + mount.device(sway * level) + SensorVector(rng.gaussian(), rng.gaussian(), rng.gaussian()) * (level * 0.5 + 0.002)
            rotation += SensorVector(rng.gaussian(), rng.gaussian(), rng.gaussian()) * (if (moving) 0.02 else 0.004)
            // Clip the raw accelerometer (user + gravity) at the sensor's range.
            val raw = user + g
            val clipped = SensorVector(raw.x.coerceIn(-saturationG, saturationG), raw.y.coerceIn(-saturationG, saturationG),
                raw.z.coerceIn(-saturationG, saturationG))
            val uptime = start + t
            readings.add(SensorReading.Motion(MotionSample(uptime = uptime, date = uptime,
                accelerationG = clipped - g, gravityG = g, rotationRate = rotation)))
            if (hasGPS && t >= nextFix) {
                nextFix += 1
                lat += speed(t) / 111_320
                if (!(gpsOutage?.contains(t) ?: false)) {
                    val reported = max(0.0, speed(max(0.0, t - gpsLag)) + rng.gaussian() * 0.25)
                    readings.add(SensorReading.Location(LocationSample(uptime = uptime + 0.001, date = uptime,
                        latitude = lat, longitude = -122.68, horizontalAccuracy = rng.uniform(3.0, 12.0),
                        speedMPS = reported, speedAccuracy = rng.uniform(0.3, 1.2))))
                }
            }
        }
        return SensorScenario(kind = kind, title = kind.title, readings = readings, eventUptime = start + eventTime,
            trueDeltaVMPS = trueDeltaV, mount = mount.name, detail = detail)
    }

    // Scenarios

    fun make(kind: SensorScenario.Kind, rng: SeededGenerator): SensorScenario {
        val mount = if (rng.chance(0.6)) PhoneMount.standard[rng.int(4)] else PhoneMount.random(rng)
        val vibration = rng.uniform(0.015, 0.05)
        val te = rng.uniform(4.0, 5.0)
        val g0 = SensorVector.standardGravity
        when (kind) {
            SensorScenario.Kind.frontalCrash, SensorScenario.Kind.lowSpeedCrash -> {
                val low = kind == SensorScenario.Kind.lowSpeedCrash
                val v0 = if (low) rng.uniform(3.0, 8.0) else rng.uniform(8.0, 30.0)
                val dv = if (low) rng.uniform(1.5, min(4.5, v0)) else rng.uniform(3.0, min(20.0, v0 + 4))
                val pulse = if (low) rng.uniform(0.12, 0.25) else rng.uniform(0.07, 0.18)
                val after = max(0.0, v0 - dv)
                val decel = rng.uniform(0.3, 0.7)
                val spin = rng.uniform(0.0, if (low) 1.0 else 4.0)
                val stopAt = te + pulse + after / (decel * g0)
                val outage = if (rng.chance(0.1)) (te + 0.2)..(te + 6) else null
                return render(kind, duration = 12.0, eventTime = te, mount = mount, vibration = vibration, gpsOutage = outage,
                    trueDeltaV = dv,
                    detail = fmt("%.0f mph, Δv %.1f mph, %.0f ms pulse%s", v0 * 2.237, dv * 2.237, pulse * 1000,
                        if (outage == null) "" else ", GPS lost after impact"),
                    rng = rng,
                    carAccel = { t ->
                        val x = -halfSine(t, te, pulse, dv)
                        val braking = if (t > te + pulse && t < stopAt) -decel else 0.0
                        SensorVector(x + braking, 0.0, 0.0)
                    },
                    yawRate = { t -> if (t >= te && t <= te + 0.6) spin * sin(PI * (t - te) / 0.6) else 0.0 },
                    speed = { t ->
                        when {
                            t < te -> v0
                            t < te + pulse -> max(0.0, v0 - halfSineSpeed(t, te, pulse, dv))
                            else -> max(0.0, after - decel * g0 * (t - te - pulse))
                        }
                    })
            }
            SensorScenario.Kind.rearEndedWhileStopped -> {
                val dv = rng.uniform(2.0, 8.0)
                val pulse = rng.uniform(0.09, 0.2)
                val brake = rng.uniform(0.3, 0.8)
                val stopAt = te + pulse + dv / (brake * g0)
                return render(kind, duration = 12.0, eventTime = te, mount = mount, vibration = vibration, trueDeltaV = dv,
                    detail = fmt("stopped, pushed Δv %.1f mph", dv * 2.237), rng = rng,
                    carAccel = { t ->
                        val x = halfSine(t, te, pulse, dv)
                        SensorVector(if (t > te + pulse && t < stopAt) x - brake else x, 0.0, 0.0)
                    },
                    speed = { t ->
                        when {
                            t < te -> 0.0
                            t < te + pulse -> halfSineSpeed(t, te, pulse, dv)
                            else -> max(0.0, dv - brake * g0 * (t - te - pulse))
                        }
                    })
            }
            SensorScenario.Kind.sideImpact -> {
                val v0 = if (rng.chance(0.5)) 0.0 else rng.uniform(3.0, 15.0)
                val dv = rng.uniform(3.0, 10.0)
                val pulse = rng.uniform(0.06, 0.15)
                val spin = rng.uniform(1.0, 5.0)
                val side = if (rng.chance(0.5)) 1.0 else -1.0
                val decel = rng.uniform(0.4, 0.8) * g0
                val lateralStop = te + pulse + dv / decel
                return render(kind, duration = 12.0, eventTime = te, mount = mount, vibration = vibration, trueDeltaV = dv,
                    detail = fmt("%.0f mph, side Δv %.1f mph", v0 * 2.237, dv * 2.237), rng = rng,
                    carAccel = { t ->
                        val y = side * halfSine(t, te, pulse, dv)
                        val slide = if (t > te + pulse && t < lateralStop) -side * decel / g0 else 0.0
                        val braking = if (t > te && v0 > 0 && t < te + v0 / decel) -decel / g0 else 0.0
                        SensorVector(braking, y + slide, 0.0)
                    },
                    yawRate = { t -> if (t >= te && t <= te + 1) side * spin * sin(PI * (t - te)) else 0.0 },
                    speed = { t ->
                        if (t < te) {
                            v0
                        } else {
                            val forward = max(0.0, v0 - decel * (t - te))
                            val sideways = if (t < te + pulse) halfSineSpeed(t, te, pulse, dv)
                            else max(0.0, dv - decel * (t - te - pulse))
                            sqrt(forward * forward + sideways * sideways)
                        }
                    })
            }
            SensorScenario.Kind.phoneDropMoving, SensorScenario.Kind.phoneDropParked -> {
                val v = if (kind == SensorScenario.Kind.phoneDropParked) 0.0 else rng.uniform(5.0, 30.0)
                val height = rng.uniform(0.4, 1.3)
                val hasGPS = kind == SensorScenario.Kind.phoneDropMoving || rng.chance(0.5)
                return drop(kind, speed = { v }, carAccel = { SensorVector.zero }, mount = mount, vibration = vibration, te = te,
                    height = height, hasGPS = hasGPS, extra = fmt("%.0f mph", v * 2.237), rng = rng)
            }
            SensorScenario.Kind.phoneFliesOffMountWhileBraking -> {
                val v0 = rng.uniform(13.0, 30.0)
                val brake = rng.uniform(0.7, 1.0)
                val tb = te - 0.4
                val stopAt = tb + v0 / (brake * g0)
                val height = rng.uniform(0.3, 0.8)
                return drop(kind, speed = { t -> if (t < tb) v0 else max(0.0, v0 - brake * g0 * (t - tb)) },
                    carAccel = { t -> SensorVector(if (t > tb && t < stopAt) -brake else 0.0, 0.0, 0.0) },
                    mount = mount, vibration = vibration, te = te, height = height, hasGPS = true,
                    extra = fmt("%.0f mph, %.1f g stop", v0 * 2.237, brake), rng = rng)
            }
            SensorScenario.Kind.pothole, SensorScenario.Kind.speedBump, SensorScenario.Kind.roughRoad -> {
                val v = if (kind == SensorScenario.Kind.speedBump) rng.uniform(3.0, 9.0) else rng.uniform(8.0, 25.0)
                val peak = when (kind) {
                    SensorScenario.Kind.pothole -> rng.uniform(2.0, 7.0)
                    SensorScenario.Kind.speedBump -> rng.uniform(1.0, 3.0)
                    else -> rng.uniform(1.0, 3.0)
                }
                val width = when (kind) {
                    SensorScenario.Kind.pothole -> rng.uniform(0.015, 0.05)
                    SensorScenario.Kind.speedBump -> rng.uniform(0.1, 0.2)
                    else -> rng.uniform(0.02, 0.05)
                }
                val wheelbase = 2.7 / max(v, 1.0)
                var hits = mutableListOf(te)
                if (kind == SensorScenario.Kind.speedBump || kind == SensorScenario.Kind.pothole) hits.add(te + wheelbase)
                if (kind == SensorScenario.Kind.roughRoad) hits = (0 until 12).map { te + it * rng.uniform(0.12, 0.25) }.toMutableList()
                val finalHits = hits.toList()
                return render(kind, duration = 10.0, eventTime = te, mount = mount, vibration = vibration,
                    detail = fmt("%.0f mph, %.1f g, %.0f ms", v * 2.237, peak, width * 1000), rng = rng,
                    carAccel = { t ->
                        var z = 0.0
                        finalHits.forEachIndexed { i, h ->
                            if (t >= h && t <= h + width) z += (if (i == 0) peak else peak * 0.7) * sin(PI * (t - h) / width)
                        }
                        // The suspension rebounds for a second.
                        val first = finalHits.firstOrNull()
                        if (first != null && t > first) z += 0.25 * peak * exp(-(t - first) * 3) * sin(2 * PI * 1.5 * (t - first)) * 0.3
                        SensorVector(0.0, 0.0, z)
                    },
                    speed = { v })
            }
            SensorScenario.Kind.hardBrake -> {
                val v0 = rng.uniform(12.0, 30.0)
                val brake = rng.uniform(0.6, 1.05)
                val stopAt = te + v0 / (brake * g0)
                return render(kind, duration = 12.0, eventTime = te, mount = mount, vibration = vibration,
                    detail = fmt("%.0f mph to 0 at %.2f g", v0 * 2.237, brake), rng = rng,
                    carAccel = { t -> SensorVector(if (t > te && t < stopAt) -brake else 0.0, 0.0, 0.0) },
                    speed = { t -> if (t < te) v0 else max(0.0, v0 - brake * g0 * (t - te)) })
            }
            SensorScenario.Kind.doorSlam -> {
                val peak = rng.uniform(3.0, 9.0)
                val width = rng.uniform(0.008, 0.03)
                val hasGPS = rng.chance(0.7)
                return render(kind, duration = 10.0, eventTime = te, mount = PhoneMount.pocket, vibration = vibration, hasGPS = hasGPS,
                    detail = fmt("%.1f g, %.0f ms", peak, width * 1000), rng = rng,
                    carAccel = { t ->
                        if (t < te || t > te + 0.3) {
                            SensorVector.zero
                        } else {
                            val hit = if (t <= te + width) peak * sin(PI * (t - te) / width) else 0.0
                            val rattle = 0.4 * exp(-(t - te) * 20) * sin(2 * PI * 25 * (t - te))
                            SensorVector(0.0, hit + rattle, 0.0)
                        }
                    },
                    speed = { 0.0 })
            }
            SensorScenario.Kind.phoneTossedOnSeat -> {
                val v = if (rng.chance(0.5)) 0.0 else rng.uniform(5.0, 25.0)
                val height = rng.uniform(0.05, 0.2)
                val landingPeak = rng.uniform(1.5, 5.0)
                val landingWidth = rng.uniform(0.03, 0.07)
                return drop(kind, speed = { v }, carAccel = { SensorVector.zero }, mount = mount, vibration = vibration, te = te,
                    height = height, hasGPS = true, landingPeak = landingPeak, landingWidth = landingWidth,
                    extra = fmt("%.0f mph, soft landing", v * 2.237), rng = rng)
            }
            SensorScenario.Kind.normalDriving -> {
                val base = rng.uniform(8.0, 25.0)
                data class Event(val at: Double, val dur: Double, val g: Double, val lateral: Boolean)
                val events = (0 until 8).map {
                    val at = rng.uniform(2.0, 56.0)
                    val dur = rng.uniform(1.5, 4.0)
                    val g = rng.uniform(-0.45, 0.35)
                    Event(at, dur, g, rng.chance(0.5))
                }
                return render(kind, duration = 60.0, eventTime = 30.0, mount = mount, vibration = vibration,
                    detail = fmt("%.0f mph, braking, turns", base * 2.237), rng = rng,
                    carAccel = { t ->
                        var a = SensorVector.zero
                        for (e in events) {
                            if (t >= e.at && t <= e.at + e.dur) {
                                val shape = sin(PI * (t - e.at) / e.dur)
                                a += if (e.lateral) SensorVector(0.0, e.g * shape, 0.0) else SensorVector(e.g * shape, 0.0, 0.0)
                            }
                        }
                        a
                    },
                    yawRate = { t -> events.filter { it.lateral && t >= it.at && t <= it.at + it.dur }.sumOf { it.g * 0.8 } },
                    speed = { t ->
                        var v = base
                        for (e in events) {
                            if (!e.lateral && t > e.at) v += e.g * g0 * (min(t, e.at + e.dur) - e.at) * 2 / PI
                        }
                        max(0.0, v)
                    })
            }
        }
    }

    /** The phone leaves its spot, falls `height` meters tumbling, hits the floor and lies still. */
    private fun drop(kind: SensorScenario.Kind, speed: (Double) -> Double, carAccel: (Double) -> SensorVector,
                     mount: PhoneMount, vibration: Double, te: Double, height: Double, hasGPS: Boolean,
                     landingPeak: Double? = null, landingWidth: Double? = null, extra: String,
                     rng: SeededGenerator): SensorScenario {
        val fall = sqrt(2 * height / SensorVector.standardGravity)
        val start = te - fall
        val peak = landingPeak ?: rng.uniform(5.0, 30.0)
        val width = landingWidth ?: rng.uniform(0.003, 0.015)
        val tumble = SensorVector(rng.uniform(-8.0, 8.0), rng.uniform(-8.0, 8.0), rng.uniform(-4.0, 4.0))
        val landed = if (rng.chance(0.5)) PhoneMount.console else PhoneMount("face down", SensorVector(0.0, 1.0, 0.0),
            SensorVector(1.0, 0.0, 0.0), SensorVector(0.0, 0.0, -1.0))
        val bounce = rng.uniform(0.2, 0.4)
        return render(kind, duration = 12.0, eventTime = te, mount = mount, vibration = vibration, quiet = start..te, hasGPS = hasGPS,
            detail = fmt("%.1f m fall, %.0f g landing, %s", height, peak, extra), rng = rng,
            carAccel = carAccel, speed = speed,
            loose = { t ->
                if (t < start) {
                    null
                } else if (t < te) {
                    // Free fall: the accelerometer reads ~0, so user acceleration cancels gravity.
                    val progress = (t - start) / max(fall, 1e-6)
                    val g = mount.gravity * (1 - progress) + landed.gravity * progress
                    val n = g * (1 / max(g.magnitude, 1e-6))
                    PhoneState(user = n * -1.0, gravity = n, rotation = tumble)
                } else {
                    val up = landed.device(SensorVector(0.0, 0.0, 1.0))
                    var hit = 0.0
                    if (t <= te + width) hit = peak * sin(PI * (t - te) / width)
                    val tb = te + 0.12
                    if (t >= tb && t <= tb + width) hit += peak * bounce * sin(PI * (t - tb) / width)
                    val settle = if (t < te + 0.4) tumble * exp(-(t - te) * 15) else SensorVector.zero
                    // Resting on the car floor, it again feels the car's own motion.
                    PhoneState(user = up * hit + landed.device(carAccel(t) * -1.0), gravity = landed.gravity, rotation = settle)
                }
            })
    }

    /**
     * A real crash recorded by NHTSA (car frame x forward, y right, z down, g, 100 Hz), placed in a
     * drive: steady speed before, the measured pulse, then the car coming to rest.
     */
    fun vehiclePulse(x: List<Double>, y: List<Double>, z: List<Double>, speedBeforeMPS: Double, speedAfterMPS: Double,
                     deltaVMPS: Double, title: String, mount: PhoneMount, rng: SeededGenerator): SensorScenario {
        val te = rng.uniform(4.0, 5.0)
        val n = minOf(x.size, y.size, z.size)
        val pulseLength = n / 100.0
        val decel = 0.5 * SensorVector.standardGravity
        fun sample(t: Double): SensorVector {
            val i = ((t - te) * 100).toInt()
            if (i < 0 || i >= n) return SensorVector.zero
            return SensorVector(x[i], -y[i], -z[i]) // SAE (y right, z down) → (y left, z up)
        }
        val vibration = rng.uniform(0.015, 0.05)
        return render(SensorScenario.Kind.frontalCrash, duration = 12.0, eventTime = te, mount = mount, vibration = vibration,
            trueDeltaV = abs(deltaVMPS), detail = title, rng = rng,
            carAccel = { t ->
                val s = sample(t)
                val stopping = t > te + pulseLength && speedAfterMPS > 0 && t < te + pulseLength + speedAfterMPS / decel
                s + SensorVector(if (stopping) -0.5 else 0.0, 0.0, 0.0)
            },
            speed = { t ->
                when {
                    t < te -> speedBeforeMPS
                    t < te + pulseLength -> speedBeforeMPS + (speedAfterMPS - speedBeforeMPS) * (t - te) / pulseLength
                    else -> max(0.0, speedAfterMPS - decel * (t - te - pulseLength))
                }
            })
    }

    companion object {
        /** A half-sine pulse that changes speed by `deltaV` (m/s) over `duration` seconds, in g. */
        fun halfSine(t: Double, start: Double, duration: Double, deltaV: Double): Double {
            if (t < start || t > start + duration) return 0.0
            return deltaV * PI / (2 * duration) * sin(PI * (t - start) / duration) / SensorVector.standardGravity
        }

        /** Speed change of `halfSine` so far. */
        fun halfSineSpeed(t: Double, start: Double, duration: Double, deltaV: Double): Double {
            if (t <= start) return 0.0
            if (t >= start + duration) return deltaV
            return deltaV * (1 - cos(PI * (t - start) / duration)) / 2
        }

        private fun fmt(format: String, vararg args: Any): String = String.format(Locale.US, format, *args)
    }
}

/** Runs a scenario through the same pipeline the app uses and reports what the driver would see. */
data class ScenarioOutcome(
    val assessments: List<CrashAssessment>,
    /** The strongest decision reached (suspected crash > inconclusive > rejected), null if nothing was examined. */
    val decision: CrashDecision?,
    val estimatedDeltaVMPS: Double?,
) {
    val alerted: Boolean get() = decision == CrashDecision.suspectedCrash

    companion object {
        fun evaluate(scenario: SensorScenario, configuration: CrashEvaluationConfiguration = CrashEvaluationConfiguration()): ScenarioOutcome {
            val pipeline = CrashPipeline(configuration)
            val history = SensorHistory()
            val assessments = mutableListOf<CrashAssessment>()
            for (reading in scenario.readings) {
                history.append(reading)
                pipeline.ingest(reading)?.let { assessments.add(it) }
            }
            scenario.readings.lastOrNull()?.uptime?.let { last -> pipeline.advance(last + 10)?.let { assessments.add(it) } }
            val rank = mapOf(CrashDecision.rejected to 0, CrashDecision.inconclusive to 1, CrashDecision.suspectedCrash to 2)
            val decision = assessments.map { it.decision }.maxByOrNull { rank.getValue(it) }
            val alert = assessments.firstOrNull { it.decision == CrashDecision.suspectedCrash }
            val estimate = alert?.let { ImpactAnalyzer.analyze(history, it.candidate.uptime)?.deltaVMPS }
            return ScenarioOutcome(assessments, decision, estimate)
        }
    }
}
