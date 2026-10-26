package org.cac.crashsafe.core.crash

import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorVector
import java.util.UUID
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sqrt

@Serializable
enum class TransportationMode { car, motorcycle, bicycle, unknown }

/**
 * Experimental settings, not clinically or crash-test validated thresholds.
 * A future calibrated profile can be supplied without changing acquisition or UI code.
 */
data class CrashEvaluationConfiguration(
    val candidateG: Double = 3.0,
    val strongImpactG: Double = 6.0,
    val minimumImpactDuration: Double = 0.01,
    val rotationRadPerSecond: Double = 2.0,
    val minimumSpeedLossMPS: Double = 4.0,
    val minimumSpeedLossFraction: Double = 0.25,
    val settledRMSG: Double = 0.15,
    val preImpactSeconds: Double = 2.0,
    val postImpactSeconds: Double = 3.0,
    val deliveryGraceSeconds: Double = 0.5,
    val maximumMotionGap: Double = 0.15,
    val cooldownSeconds: Double = 15.0,
    /**
     * Horizontal speed change measured from the impact pulse itself, m/s (≈ 6.7 mph). Airbag systems
     * use a similar measure; it works without GPS, which is often lost or lagging right after a crash.
     */
    val crashDeltaVMPS: Double = 3.0,
) {
    val isValid: Boolean
        get() {
            val positive = listOf(candidateG, strongImpactG, minimumImpactDuration, rotationRadPerSecond,
                minimumSpeedLossMPS, minimumSpeedLossFraction, settledRMSG, preImpactSeconds,
                postImpactSeconds, maximumMotionGap, cooldownSeconds, crashDeltaVMPS)
            return positive.all { it.isFinite() && it > 0 } &&
                strongImpactG >= candidateG && minimumSpeedLossFraction <= 1 &&
                preImpactSeconds >= 0.5 && postImpactSeconds >= 1.5 &&
                deliveryGraceSeconds.isFinite() && deliveryGraceSeconds >= 0
        }
}

@Serializable
data class CrashCandidate(
    val uptime: Double,
    val date: Double,
    val transportationMode: TransportationMode,
    val id: String = UUID.randomUUID().toString(),
)

@Serializable
enum class CrashDecision { suspectedCrash, rejected, inconclusive }

@Serializable
enum class CrashEvidence {
    sustainedImpact, strongImpact, rapidRotation, speedLoss, settledAfterImpact,
    possiblePhoneDrop, continuedTravel,
    /** The impact pulse alone changed the car's horizontal speed by at least `crashDeltaVMPS`. */
    largeImpactDeltaV,
}

@Serializable
enum class CrashDataIssue { insufficientBaseline, insufficientPostImpact, motionGap, missingReliableGPS }

@Serializable
data class CrashAssessment(
    val candidate: CrashCandidate,
    val decision: CrashDecision,
    val evidence: List<CrashEvidence>,
    val issues: List<CrashDataIssue>,
    val peakG: Double,
    val peakRotationRadPerSecond: Double,
    val impactDuration: Double,
    val preSpeedMPS: Double? = null,
    val postSpeedMPS: Double? = null,
    val speedDropMPS: Double? = null,
    val postImpactRMSG: Double? = null,
    val location: LocationSample? = null,
    /** Horizontal speed change integrated over the impact pulse, m/s. */
    val impactDeltaVMPS: Double? = null,
) {
    val id: String get() = candidate.id
}

/** Stateless step 5. It can consume candidates from the team's eventual step 4 implementation. */
class CrashEvidenceEvaluator(val configuration: CrashEvaluationConfiguration = CrashEvaluationConfiguration()) {
    init {
        require(configuration.isValid)
    }

    fun evaluate(candidate: CrashCandidate, motion: List<MotionSample>, locations: List<LocationSample>): CrashAssessment {
        val c = configuration
        val t = candidate.uptime
        val samples = motion.filter { it.isValid && it.uptime >= t - c.preImpactSeconds && it.uptime <= t + c.postImpactSeconds }
            .sortedBy { it.uptime }
        val impact = samples.filter { it.uptime >= t - 0.1 && it.uptime <= t + 0.25 }
        val baseline = samples.filter { it.uptime < t - 0.1 }
        val after = samples.filter { it.uptime >= t + 0.5 }
        val fixes = locations.filter { it.isValid }.sortedBy { it.uptime }
        val peak = impact.maxOfOrNull { it.accelerationG.magnitude } ?: 0.0
        val rotation = samples.filter { abs(it.uptime - t) <= 0.5 }.maxOfOrNull { it.rotationRate.magnitude } ?: 0.0
        val duration = longestRun(impact) { it.accelerationG.magnitude >= c.candidateG }
        val rms = if (after.isEmpty()) null else sqrt(after.sumOf { it.accelerationG.magnitude.pow(2) } / after.size)

        val preFix = fixes.lastOrNull { it.uptime < t - 0.1 && it.hasReliableSpeed(t) }
        val postFixes = fixes.filter {
            it.uptime >= t + 0.5 && it.uptime <= t + c.postImpactSeconds && it.hasReliableSpeed(t + c.postImpactSeconds)
        }
        // Median post-impact speed resists one noisy GPS reading.
        val postFix = postFixes.sortedBy { it.speedMPS }.drop(postFixes.size / 2).firstOrNull()
        val speedDrop = if (preFix != null && postFix != null) maxOf(0.0, preFix.speedMPS - postFix.speedMPS) else null
        val speedLoss = if (preFix != null && postFix != null) {
            preFix.speedMPS >= 3 &&
                preFix.speedMPS - postFix.speedMPS - preFix.speedAccuracy - postFix.speedAccuracy >= c.minimumSpeedLossMPS &&
                (preFix.speedMPS - postFix.speedMPS) / preFix.speedMPS >= c.minimumSpeedLossFraction
        } else false

        val possibleDrop = longestRun(samples.filter { it.uptime < t && it.uptime >= t - 0.5 }) {
            it.totalAccelerationG.magnitude < 0.25
        } >= 0.06
        val sustained = duration + 0.000001 >= c.minimumImpactDuration
        val pulseDeltaV = horizontalDeltaV(impact, baseline, c.maximumMotionGap)
        val bigPulse = pulseDeltaV?.let { it >= c.crashDeltaVMPS } ?: false
        val hugePulse = pulseDeltaV?.let { it >= 2 * c.crashDeltaVMPS } ?: false
        val settled = rms?.let { it <= c.settledRMSG } ?: false
        val evidence = mutableListOf<CrashEvidence>()
        if (sustained) evidence.add(CrashEvidence.sustainedImpact)
        if (peak >= c.strongImpactG) evidence.add(CrashEvidence.strongImpact)
        if (rotation >= c.rotationRadPerSecond) evidence.add(CrashEvidence.rapidRotation)
        if (speedLoss) evidence.add(CrashEvidence.speedLoss)
        if (settled) evidence.add(CrashEvidence.settledAfterImpact)
        if (possibleDrop) evidence.add(CrashEvidence.possiblePhoneDrop)
        // A car that was standing still can't "continue" traveling: if it moves afterward, it was pushed.
        val continued = if (preFix != null && postFix != null) {
            postFix.speedMPS >= 3 && preFix.speedMPS >= 3 && postFix.speedMPS >= preFix.speedMPS - 2
        } else false
        if (continued) evidence.add(CrashEvidence.continuedTravel)
        if (bigPulse && sustained) evidence.add(CrashEvidence.largeImpactDeltaV)

        val issues = mutableListOf<CrashDataIssue>()
        if (baseline.size < 10 || span(baseline) < 0.5) issues.add(CrashDataIssue.insufficientBaseline)
        if (after.size < 10 || span(after) < 1 || (after.lastOrNull()?.uptime ?: t) < t + c.postImpactSeconds - c.maximumMotionGap) {
            issues.add(CrashDataIssue.insufficientPostImpact)
        }
        if (samples.zipWithNext().any { (a, b) -> b.uptime - a.uptime > c.maximumMotionGap }) {
            issues.add(CrashDataIssue.motionGap)
        }
        if (preFix == null || postFix == null) issues.add(CrashDataIssue.missingReliableGPS)
        val incompleteMotion = issues.any { it != CrashDataIssue.missingReliableGPS }
        val decision = when {
            incompleteMotion -> CrashDecision.inconclusive
            !sustained -> CrashDecision.rejected
            // The phone fell and hit something. During an emergency stop that looks like speed loss plus
            // an impact, so it counts only when the hit itself was a hard horizontal one (a loose phone
            // thrown into the dash by a crash), not a landing on the floor.
            possibleDrop -> if (speedLoss && bigPulse) CrashDecision.suspectedCrash else CrashDecision.inconclusive
            speedLoss -> CrashDecision.suspectedCrash
            // The pulse alone shows a crash-sized speed change: rear-ended or T-boned while stopped,
            // side impacts that don't slow the car, and crashes where GPS drops out.
            hugePulse || (bigPulse && !continued) -> CrashDecision.suspectedCrash
            issues.contains(CrashDataIssue.missingReliableGPS) && peak >= c.strongImpactG &&
                rotation >= c.rotationRadPerSecond && settled && !possibleDrop -> CrashDecision.suspectedCrash
            // Continued travel and GPS absence are not proof that no crash happened.
            peak >= c.strongImpactG || rotation >= c.rotationRadPerSecond || possibleDrop -> CrashDecision.inconclusive
            else -> CrashDecision.rejected
        }
        val location = fixes.filter { abs(it.uptime - t) <= 3 && it.horizontalAccuracy >= 0 && it.horizontalAccuracy <= 50 }
            .minByOrNull { abs(it.uptime - t) }
        return CrashAssessment(candidate = candidate, decision = decision, evidence = evidence, issues = issues,
            peakG = peak, peakRotationRadPerSecond = rotation, impactDuration = duration,
            preSpeedMPS = preFix?.speedMPS, postSpeedMPS = postFix?.speedMPS,
            speedDropMPS = speedDrop, postImpactRMSG = rms, location = location,
            impactDeltaVMPS = pulseDeltaV)
    }

    private fun span(samples: List<MotionSample>): Double {
        val first = samples.firstOrNull() ?: return 0.0
        return samples.last().uptime - first.uptime
    }

    private fun longestRun(samples: List<MotionSample>, matching: (MotionSample) -> Boolean): Double {
        var start: Double? = null
        var previous: Double? = null
        var longest = 0.0
        for (sample in samples) {
            if (matching(sample)) {
                if (previous?.let { sample.uptime - it > configuration.maximumMotionGap } ?: true) start = null
                if (start == null) start = sample.uptime
                longest = maxOf(longest, sample.uptime - (start ?: sample.uptime))
            } else {
                start = null
            }
            previous = sample.uptime
        }
        return longest
    }

    companion object {
        /**
         * Integrates user acceleration over the contiguous pulse around the peak and drops the part along
         * gravity, so potholes, bumps and a phone landing flat don't count. m/s; null without samples.
         * The pulse is the run of samples above max(0.8 g, 20% of the peak, 1.5 × the RMS of the second
         * before): a crash stands out from what came before it, while the steady 1–2 g of brisk walking
         * or jogging would otherwise merge into one long "pulse".
         */
        fun horizontalDeltaV(impact: List<MotionSample>, baseline: List<MotionSample>, maximumGap: Double): Double? {
            if (impact.isEmpty()) return null
            val peakIndex = impact.indices.maxBy { impact[it].accelerationG.magnitude }
            val recent = baseline.filter { it.uptime >= impact[0].uptime - 1 }
            val baselineRMS = if (recent.isEmpty()) 0.0 else sqrt(recent.sumOf { it.accelerationG.magnitude.pow(2) } / recent.size)
            val threshold = maxOf(0.8, impact[peakIndex].accelerationG.magnitude * 0.2, 1.5 * baselineRMS)
            var lo = peakIndex
            var hi = peakIndex
            while (lo > 0 && impact[lo - 1].accelerationG.magnitude >= threshold) lo--
            while (hi + 1 < impact.size && impact[hi + 1].accelerationG.magnitude >= threshold) hi++
            val spacing = if (impact.size > 1) (impact.last().uptime - impact.first().uptime) / (impact.size - 1) else 0.01
            var sum = SensorVector.zero
            for (i in lo..hi) {
                val dt = if (i + 1 < impact.size) impact[i + 1].uptime - impact[i].uptime else spacing
                sum += impact[i].accelerationG * (dt.coerceIn(0.0, maximumGap) * SensorVector.standardGravity)
            }
            // "Down" from the moment just before the hit (the phone may tumble during it).
            val reference = baseline.takeLast(10).fold(SensorVector.zero) { acc, s -> acc + s.gravityG }
            val gravity = if (reference.magnitude > 0.2) reference else impact[peakIndex].gravityG
            if (gravity.magnitude <= 0.2) return sum.magnitude
            val down = gravity * (1 / gravity.magnitude)
            return (sum - down * sum.dot(down)).magnitude
        }
    }
}
