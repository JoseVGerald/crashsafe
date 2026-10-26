package org.cac.crashsafe.core.crash

import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorRing
import kotlin.math.abs

/**
 * Minimal bounded history and an interchangeable candidate gate support step 5.
 * The default gate is a prototype bridge until the team's step 4 detector is ready.
 */
class CrashPipeline(
    val configuration: CrashEvaluationConfiguration = CrashEvaluationConfiguration(),
    var transportationMode: TransportationMode = TransportationMode.unknown,
    val automaticCandidates: Boolean = true,
) {
    var pending: CrashCandidate? = null
        private set
    val motion = SensorRing<MotionSample>(2048)
    val locations = SensorRing<LocationSample>(64)
    private var lastMotion: Double? = null
    private var lastLocation: Double? = null
    private var nextCandidateTime = Double.NEGATIVE_INFINITY

    init {
        require(configuration.isValid)
    }

    fun ingest(reading: SensorReading): CrashAssessment? {
        when (reading) {
            is SensorReading.Motion -> {
                val sample = reading.sample
                if (!sample.isValid || !(lastMotion?.let { sample.uptime > it } ?: true)) return null
                lastMotion = sample.uptime
                motion.append(sample)
                val completed = advance(sample.uptime)
                if (automaticCandidates && sample.accelerationG.magnitude >= configuration.candidateG) {
                    submit(CrashCandidate(uptime = sample.uptime, date = sample.date, transportationMode = transportationMode))
                }
                return completed
            }
            is SensorReading.Location -> {
                val fix = reading.sample
                if (!fix.isValid || !(lastLocation?.let { fix.uptime > it } ?: true)) return null
                lastLocation = fix.uptime
                locations.append(fix)
                return null // GPS never advances the motion clock or hides a motion outage.
            }
        }
    }

    fun submit(candidate: CrashCandidate): Boolean {
        val last = lastMotion ?: return false
        if (!candidate.uptime.isFinite() || !candidate.date.isFinite() || abs(candidate.uptime - last) > 0.25 ||
            pending != null || candidate.uptime < nextCandidateTime) return false
        pending = candidate
        return true
    }

    /** Called by a watchdog too, so loss of motion after an impact yields an inconclusive assessment. */
    fun advance(uptime: Double): CrashAssessment? {
        val candidate = pending ?: return null
        if (!uptime.isFinite() ||
            uptime < candidate.uptime + configuration.postImpactSeconds + configuration.deliveryGraceSeconds) return null
        pending = null
        val result = CrashEvidenceEvaluator(configuration).evaluate(candidate, motion.values, locations.values)
        nextCandidateTime = uptime + if (result.decision == CrashDecision.suspectedCrash) configuration.cooldownSeconds else 1.0
        return result
    }
}
