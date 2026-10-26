package org.cac.crashsafe.core.intelligence

import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.crash.ImpactAnalyzer
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.SynchronizedWindow
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Transportation-mode classification, ported from the basis of
 * github.com/udaykamboj/multi-placement-transportation-mode-classification-ML-system:
 * its 8 SHL classes, its 50 Hz × 250-sample (5 s) IMU windows, its damped per-window
 * normalization, and its 12 per-window GPS features. The trained MSRLSTM network isn't
 * bundled (its checkpoints ship without the normalization statistics it needs), so a
 * transparent feature model fills the `TransportModeModel` slot until a converted model is added.
 */
enum class TransportClass(
    /** Labels used by the backend's incident schema (`Backend/rag/incident_context.py`). */
    val label: String,
    val title: String,
    val systemImage: String,
) {
    still("still", "Still", "figure.stand"),
    walk("walk", "Walking", "figure.walk"),
    run("run", "Running", "figure.run"),
    bike("bicycle", "Cycling", "bicycle"),
    car("car", "In a car", "car.fill"),
    bus("bus", "On a bus", "bus.fill"),
    train("train", "On a train", "tram.fill"),
    subway("subway", "On a subway", "tram.tunnel.fill");

    companion object {
        fun ofRaw(index: Int): TransportClass? = entries.getOrNull(index)
    }
}

/** One classified window, in the shape the agent backend accepts (`transport` in the incident packet). */
@Serializable
data class TransportObservation(
    val label: String,
    val basis: String,
    val probability: Double,
    val modelID: String,
    val probabilities: List<Double>,
) {
    val transportClass: TransportClass? get() = TransportClass.entries.firstOrNull { it.label == label }

    companion object {
        /** Below this the label is reported as "unknown" (the backend uses the same 0.8 bar). */
        const val acceptance = 0.8

        fun of(probabilities: List<Double>, modelID: String): TransportObservation {
            val best = probabilities.indices.maxByOrNull { probabilities[it] } ?: 0
            val label = if (probabilities[best] >= acceptance) TransportClass.ofRaw(best)?.label ?: "unknown" else "unknown"
            return TransportObservation(label = label, basis = "model", probability = probabilities[best],
                modelID = modelID, probabilities = probabilities)
        }
    }
}

/**
 * The model slot. A TensorFlow Lite conversion of the repo's network would implement this with
 * `TransportFeatures.normalizedIMU(...)` as its input.
 */
interface TransportModeModel {
    val modelID: String

    /** Eight probabilities in `TransportClass` order, summing to 1. */
    fun probabilities(features: TransportFeatures): List<Double>
}

/** Features from one synchronized window. */
data class TransportFeatures(
    /**
     * The repo's `window_gps_features`, same order: mean, max, std, p50, p90 speed (m/s), total
     * distance (m), straight-line rate (m/s), mean/std/max heading change (rad), fix count, coverage.
     */
    val gps: List<Double>?,
    val accelMeanMS2: Double,
    val accelStdMS2: Double,
    val accelMaxMS2: Double,
    val gyroMeanRadS: Double,
    val gyroStdRadS: Double,
    /** Strongest periodicity of vertical acceleration between 0.7 and 4 Hz (steps, pedalling). */
    val cadenceHz: Double,
    /** Autocorrelation at that cadence, 0…1. */
    val cadenceStrength: Double,
    /** Median GPS speed over the window (from the per-sample speeds), m/s. */
    val medianSpeedMPS: Double?,
) {
    companion object {
        fun extract(window: SynchronizedWindow): TransportFeatures {
            val accel = window.linearAccelerationMS2.map { it.magnitude }
            val gyro = window.rotationRadPerSecond.map { it.magnitude }
            // Cadence from the vertical component (acceleration along gravity): independent of how the
            // phone is held, and not frequency-doubled the way |acceleration| is.
            val vertical = window.linearAccelerationMS2.zip(window.gravityG).map { (a, g) ->
                if (g.magnitude > 0) a.dot(g) / g.magnitude else 0.0
            }
            val (cadence, strength) = dominantPeriod(vertical, window.hz)
            val speeds = window.speedMPS.filterNotNull()
            return TransportFeatures(
                gps = gpsFeatures(window.fixes, window.duration * 1000),
                accelMeanMS2 = mean(accel), accelStdMS2 = std(accel), accelMaxMS2 = accel.maxOrNull() ?: 0.0,
                gyroMeanRadS = mean(gyro), gyroStdRadS = std(gyro),
                cadenceHz = cadence, cadenceStrength = strength,
                medianSpeedMPS = if (speeds.size >= window.count / 3) ImpactAnalyzer.median(speeds) else null)
        }

        /** Port of `window_gps_features` (scripts/parse_shl_gps.py). */
        fun gpsFeatures(fixes: List<LocationSample>, durationMS: Double): List<Double>? {
            val fl = fixes.sortedBy { it.date }
            if (fl.size < 2) return null
            val span = (fl.last().date - fl.first().date) * 1000
            if (span <= 0) return null
            val dist = mutableListOf<Double>()
            val speed = mutableListOf<Double>()
            val bears = mutableListOf<Double>()
            for ((a, b) in fl.zipWithNext()) {
                val d = haversine(a.latitude, a.longitude, b.latitude, b.longitude)
                val dt = max((b.date - a.date) * 1000, 1.0)
                dist.add(d)
                speed.add(d / (dt / 1000))
                bears.add(atan2(b.longitude - a.longitude, b.latitude - a.latitude))
            }
            val hd = bears.zipWithNext().map { (a, b) ->
                val x = abs(b - a)
                min(x, 2 * PI - x)
            }
            val total = dist.sum()
            return listOf(mean(speed), speed.maxOrNull() ?: 0.0, std(speed), percentile(speed, 50.0), percentile(speed, 90.0),
                total, total / max(span / 1000, 1e-3),
                if (hd.isEmpty()) 0.0 else mean(hd), if (hd.isEmpty()) 0.0 else std(hd), hd.maxOrNull() ?: 0.0,
                fl.size.toDouble(), span / durationMS)
        }

        /**
         * Port of `damped_perwin` + clip (scripts/train_shl.py): per-channel instance normalization
         * with the std floored so near-still windows don't amplify noise. `floor` comes from the
         * model's training statistics; there is no default on purpose.
         */
        fun normalizedIMU(channels: List<List<Double>>, floor: List<Double>, clip: Double): List<List<Double>>? {
            if (channels.isEmpty() || channels.size != floor.size || clip <= 0 || !floor.all { it > 0 }) return null
            return channels.mapIndexed { c, xs ->
                val m = mean(xs)
                val s = max(std(xs), floor[c])
                xs.map { ((it - m) / s).coerceIn(-clip, clip) }
            }
        }

        /**
         * The repo's 9-channel layout (lacc x/y/z m/s², gyr x/y/z rad/s, mag x/y/z). Magnetometer is
         * zero-filled: the repo found it hurts (hard-iron spikes) and its best models mask it.
         */
        fun imuChannels(window: SynchronizedWindow): List<List<Double>> {
            val a = window.linearAccelerationMS2
            val g = window.rotationRadPerSecond
            val zeros = List(window.count) { 0.0 }
            return listOf(a.map { it.x }, a.map { it.y }, a.map { it.z }, g.map { it.x }, g.map { it.y }, g.map { it.z }, zeros, zeros, zeros)
        }

        // Math

        fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val r = 6_371_000.0
            val p1 = lat1 * PI / 180
            val p2 = lat2 * PI / 180
            val dp = (lat2 - lat1) * PI / 180
            val dl = (lon2 - lon1) * PI / 180
            val h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
            return 2 * r * asin(min(1.0, sqrt(h)))
        }

        fun mean(xs: List<Double>): Double = if (xs.isEmpty()) 0.0 else xs.sum() / xs.size

        /** Population standard deviation (numpy's default). */
        fun std(xs: List<Double>): Double {
            if (xs.isEmpty()) return 0.0
            val m = mean(xs)
            return sqrt(xs.sumOf { (it - m) * (it - m) } / xs.size)
        }

        /** Linear-interpolated percentile (numpy's default). */
        fun percentile(xs: List<Double>, q: Double): Double {
            if (xs.isEmpty()) return 0.0
            val s = xs.sorted()
            val pos = (s.size - 1) * q / 100
            val lo = floor(pos).toInt()
            val hi = min(lo + 1, s.size - 1)
            return s[lo] + (s[hi] - s[lo]) * (pos - lo)
        }

        /** Strongest normalized autocorrelation lag between 0.7 and 4 Hz. */
        fun dominantPeriod(xs: List<Double>, hz: Double): Pair<Double, Double> {
            val m = mean(xs)
            val centered = DoubleArray(xs.size) { xs[it] - m }
            val energy = centered.sumOf { it * it }
            if (energy <= 1e-9) return 0.0 to 0.0
            val minLag = max(1, (hz / 4).toInt())
            val maxLag = min(centered.size - 1, (hz / 0.7).toInt())
            if (minLag >= maxLag) return 0.0 to 0.0
            var bestLag = 0
            var bestR = 0.0
            for (lag in minLag..maxLag) {
                var sum = 0.0
                for (i in 0 until centered.size - lag) sum += centered[i] * centered[i + lag]
                val r = sum / energy
                if (r > bestR) {
                    bestLag = lag
                    bestR = r
                }
            }
            return if (bestLag == 0) 0.0 to 0.0 else hz / bestLag to min(bestR, 1.0)
        }
    }
}

/**
 * Transparent stand-in for the trained network: physically motivated scores per class from
 * speed (GPS branch), vibration, rotation and step cadence, turned into probabilities by softmax.
 */
class FeatureTransportModel : TransportModeModel {
    override val modelID = "crashsafe-shl8-features-v3"

    override fun probabilities(features: TransportFeatures): List<Double> {
        val f = features
        val speed = f.medianSpeedMPS ?: f.gps?.get(3)
        val straight = f.gps?.let { it[7] < 0.15 } ?: false
        fun band(x: Double?, lo: Double, hi: Double, soft: Double): Double {
            if (x == null) return 0.0
            if (x >= lo && x <= hi) return 1.0
            val d = if (x < lo) lo - x else x - hi
            return max(0.0, 1 - d / soft)
        }
        // Gait: a human-rate rhythm with real amplitude (engine/road vibration doesn't count). A phone in
        // the hand shows the step rate; one in a front pocket swings with one leg and shows the stride
        // rate, half of it (real iPhone data, MotionSense: walking ≈ 0.95 Hz, jogging ≈ 1.35 Hz there).
        // Car vibration can be faintly rhythmic too (median strength 0.26 in real drives) but never this
        // clean (walking 0.46–0.71) and never swings the phone around (stairs: ~2 rad/s, cars: ~0.1).
        val walkRate = max(band(f.cadenceHz, 0.75, 1.15, 0.25), band(f.cadenceHz, 1.5, 2.4, 0.3))
        val runRate = max(band(f.cadenceHz, 1.2, 1.7, 0.25), band(f.cadenceHz, 2.4, 3.6, 0.5))
        // Only a gait rate counts: a gentle 3 Hz rhythm is road vibration, not a run.
        val gaitRate = max(walkRate, if (f.accelStdMS2 > 3) runRate else 0.0)
        val rhythmic = f.cadenceStrength > 0.4 && gaitRate > 0 && f.accelStdMS2 > 0.5
        val swinging = f.accelStdMS2 > 1.5 && f.gyroMeanRadS > 0.8 && f.cadenceStrength > 0.15
        val stepping = rhythmic || swinging
        val vigorous = f.accelStdMS2 > 5.5
        val quiet = band(f.accelStdMS2, 0.0, 0.25, 0.5)
        val score = DoubleArray(8)
        score[TransportClass.still.ordinal] = 3 * quiet * band(f.gyroMeanRadS, 0.0, 0.15, 0.3) +
            (speed?.let { if (it < 0.4) 1.5 else if (it > 1.5) -4.0 else -1.0 } ?: 0.0)
        score[TransportClass.walk.ordinal] = (if (stepping) 2.5 * max(walkRate, if (rhythmic) 0.0 else 0.8) * (if (vigorous) 0.4 else 1.0) else 0.0) +
            band(f.accelStdMS2, 0.8, 5.5, 1.5) + band(speed, 0.5, 2.3, 1.0) - (speed?.let { if (it > 4) 3.0 else 0.0 } ?: 0.0)
        // Running is never gentle (real jogging: under 5.2 m/s² of shake in only 10% of windows); a gentle
        // 3 Hz rhythm is road vibration.
        score[TransportClass.run.ordinal] = (if (stepping && f.accelStdMS2 > 3) 2.5 * runRate * (if (vigorous) 1.0 else 0.5) else 0.0) +
            band(f.accelStdMS2, 5.5, 15.0, 1.5) + band(speed, 2.3, 6.5, 1.5) - (speed?.let { if (it > 8) 3.0 else 0.0 } ?: 0.0)
        // Without a speed, only pedalling (a leg-rate rhythm while the phone turns with the leg) says
        // "bike"; a car's road vibration alone looks much the same (real drives scored "Cycling" otherwise).
        val pedalling = rhythmic && f.cadenceHz in 0.8..1.8 && f.gyroMeanRadS > 0.5
        val bikeMotion = band(f.gyroStdRadS, 0.15, 0.8, 0.4) + band(f.accelStdMS2, 0.6, 3.0, 1.0)
        score[TransportClass.bike.ordinal] = 1.6 * band(speed, 3.0, 9.0, 2.0) + bikeMotion * (if (speed == null && !pedalling) 0.4 else 1.0) -
            (if (stepping && f.cadenceHz > 1.4) 1.5 else 0.0)
        // Vehicle vibration: some shake, little rotation, no gait.
        val ridingMotion = if (speed == null && !stepping && f.gyroMeanRadS < 0.3) 0.6 else 0.0
        score[TransportClass.car.ordinal] = 2.6 * band(speed, 6.0, 45.0, 4.0) + band(f.accelStdMS2, 0.05, 1.2, 1.0) -
            (if (stepping) 1.5 else 0.0) + (if (straight) 0.0 else 0.3) + ridingMotion
        score[TransportClass.bus.ordinal] = 1.4 * band(speed, 3.0, 22.0, 4.0) + 0.6 * band(f.accelStdMS2, 0.1, 1.2, 1.0) -
            (if (stepping) 1.5 else 0.0)
        score[TransportClass.train.ordinal] = 1.2 * band(speed, 22.0, 90.0, 8.0) + (if (straight) 0.6 else 0.0) +
            0.4 * band(f.accelStdMS2, 0.05, 0.6, 0.5) - (if (stepping) 2.0 else 0.0)
        val gpsCoverage = f.gps?.get(11) ?: 0.0
        score[TransportClass.subway.ordinal] = (if (f.gps == null || gpsCoverage < 0.3) 0.8 else -1.0) *
            band(f.accelStdMS2, 0.1, 0.8, 0.5) + 0.5 * band(f.gyroMeanRadS, 0.0, 0.1, 0.2) - (if (stepping) 2.0 else 0.0)
        return softmax(score.toList(), temperature = 0.45)
    }

    fun softmax(xs: List<Double>, temperature: Double): List<Double> {
        val m = xs.maxOrNull() ?: 0.0
        val e = xs.map { exp((it - m) / temperature) }
        val s = e.sum()
        return e.map { it / s }
    }
}
