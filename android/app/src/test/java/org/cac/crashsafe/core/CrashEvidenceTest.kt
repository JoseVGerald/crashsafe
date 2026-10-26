package org.cac.crashsafe.core

import kotlinx.serialization.json.Json
import org.cac.crashsafe.core.crash.CrashAssessment
import org.cac.crashsafe.core.crash.CrashCandidate
import org.cac.crashsafe.core.crash.CrashDataIssue
import org.cac.crashsafe.core.crash.CrashDecision
import org.cac.crashsafe.core.crash.CrashEvaluationConfiguration
import org.cac.crashsafe.core.crash.CrashEvidence
import org.cac.crashsafe.core.crash.CrashEvidenceEvaluator
import org.cac.crashsafe.core.crash.CrashPipeline
import org.cac.crashsafe.core.crash.TransportationMode
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorRing
import org.cac.crashsafe.core.sensors.SensorVector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class CrashEvidenceTest {
    private val candidate = CrashCandidate(uptime = 12.0, date = 12.0, transportationMode = TransportationMode.car, id = "c")

    private fun assess(motion: List<MotionSample>, gps: List<LocationSample>): CrashAssessment =
        CrashEvidenceEvaluator().evaluate(candidate, motion, gps)

    private fun sample(time: Double, g: Double) = MotionSample(uptime = time, date = time,
        accelerationG = SensorVector(g, 0.0, 0.0), gravityG = SensorVector(0.0, 0.0, -1.0), rotationRate = SensorVector.zero)

    private fun trace(impactG: Double = 4.0, impactSamples: Int = 5, rotation: Double = 0.0, afterG: Double = 0.0): List<MotionSample> =
        (0..500).map { index ->
            val g = if (index in 200 until 200 + impactSamples) impactG else if (index > 230) afterG else 0.0
            var value = sample(10 + index / 100.0, g)
            if (index in 200..210) value = value.copy(rotationRate = value.rotationRate.copy(z = rotation))
            value
        }

    private fun fixes(postSpeed: Double = 0.0): List<LocationSample> = listOf(11.0, 13.0, 14.0, 15.0).map { time ->
        LocationSample(uptime = time, date = time, latitude = 47.0, longitude = -122.0, horizontalAccuracy = 5.0,
            speedMPS = if (time < 12) 20.0 else postSpeed, speedAccuracy = 0.5)
    }

    @Test fun impactAndReliableSpeedLossProduceExplainableSuspectedCrash() {
        val result = assess(trace(), fixes())
        assertEquals(CrashDecision.suspectedCrash, result.decision)
        assertTrue(CrashEvidence.sustainedImpact in result.evidence)
        assertTrue(CrashEvidence.speedLoss in result.evidence)
        assertEquals(4.0, result.peakG, 0.0)
        assertEquals(20.0, result.speedDropMPS!!, 0.0)
        assertTrue(result.issues.isEmpty())
        assertNotNull(result.location)
    }

    @Test fun crashDoesNotRequireStillnessOrRotationWhenSpeedLossCorroborates() {
        val result = assess(trace(afterG = 0.4), fixes())
        assertEquals(CrashDecision.suspectedCrash, result.decision)
        assertFalse(CrashEvidence.settledAfterImpact in result.evidence)
        assertFalse(CrashEvidence.rapidRotation in result.evidence)
    }

    @Test fun isolatedSpikeAndHardBrakingAreRejected() {
        assertEquals(CrashDecision.rejected, assess(trace(impactG = 8.0, impactSamples = 1), fixes()).decision)
        assertEquals(CrashDecision.rejected, assess(trace(impactG = 0.5), fixes()).decision)
    }

    @Test fun missingGpsRequiresStrongerIndependentEvidence() {
        val strong = assess(trace(impactG = 8.0, rotation = 3.0), emptyList())
        assertEquals(CrashDecision.suspectedCrash, strong.decision)
        assertEquals(listOf(CrashDataIssue.missingReliableGPS), strong.issues)
        assertNull(strong.speedDropMPS)
        assertEquals(CrashDecision.rejected, assess(trace(), emptyList()).decision)
    }

    @Test fun freeFallPatternPreventsMotionOnlyPhoneDropConfirmation() {
        val samples = trace(impactG = 8.0, rotation = 4.0).toMutableList()
        for (index in 180 until 196) samples[index] = samples[index].copy(accelerationG = SensorVector(0.0, 0.0, 1.0))
        val result = assess(samples, emptyList())
        assertTrue(CrashEvidence.possiblePhoneDrop in result.evidence)
        assertEquals(CrashDecision.inconclusive, result.decision)
    }

    @Test fun continuedTravelDoesNotAutomaticallyRuleOutCrash() {
        val result = assess(trace(impactG = 8.0, rotation = 3.0), fixes(postSpeed = 20.0))
        assertTrue(CrashEvidence.continuedTravel in result.evidence)
        assertEquals(CrashDecision.inconclusive, result.decision)
    }

    @Test fun gpsUncertaintyIsAccountedFor() {
        var gps = fixes(postSpeed = 13.0).map { it.copy(speedAccuracy = 3.0) }
        val result = assess(trace(), gps)
        assertFalse(CrashEvidence.speedLoss in result.evidence)
        assertEquals(CrashDecision.rejected, result.decision)
        gps = gps.map { it.copy(speedAccuracy = -1.0) }
        assertTrue(CrashDataIssue.missingReliableGPS in assess(trace(), gps).issues)
    }

    @Test fun staleGpsAndInsufficientMotionRemainExplicit() {
        val gps = fixes().toMutableList()
        gps[0] = gps[0].copy(uptime = 5.0)
        assertTrue(CrashDataIssue.missingReliableGPS in assess(trace(), gps).issues)
        val gap = trace().filter { it.uptime < 12.3 || it.uptime > 12.6 }
        val interrupted = assess(gap, fixes())
        assertEquals(CrashDecision.inconclusive, interrupted.decision)
        assertTrue(CrashDataIssue.motionGap in interrupted.issues)
        val short = assess(trace().filter { it.uptime >= 12 }, fixes())
        assertEquals(CrashDecision.inconclusive, short.decision)
        assertTrue(CrashDataIssue.insufficientBaseline in short.issues)
        val missingAfter = assess(trace().filter { it.uptime < 13 }, fixes())
        assertEquals(CrashDecision.inconclusive, missingAfter.decision)
        assertTrue(CrashDataIssue.insufficientPostImpact in missingAfter.issues)
    }

    @Test fun assessmentRoundTripsWithoutConvertingUnknownSpeedToZero() {
        val result = assess(trace(impactG = 8.0, rotation = 3.0), emptyList())
        val json = Json.encodeToString(CrashAssessment.serializer(), result)
        assertEquals(result, Json.decodeFromString(CrashAssessment.serializer(), json))
        assertNull(result.speedDropMPS)
    }

    @Test fun pipelineEvaluatesExternalCandidatesAndSuppressesDuplicateAlerts() {
        val pipeline = CrashPipeline(automaticCandidates = false)
        val results = mutableListOf<CrashAssessment>()
        val gps = fixes()
        for (sample in trace()) {
            for (fix in gps) if (abs(fix.uptime - sample.uptime) < 0.001) pipeline.ingest(SensorReading.Location(fix))
            pipeline.ingest(SensorReading.Motion(sample))?.let { results.add(it) }
            if (abs(sample.uptime - 12) < 0.001) {
                assertTrue(pipeline.submit(candidate))
                assertFalse(pipeline.submit(candidate))
            }
        }
        pipeline.advance(15.5)?.let { results.add(it) }
        assertEquals(1, results.size)
        assertEquals(CrashDecision.suspectedCrash, results.first().decision)
        assertNull(pipeline.advance(20.0))
        pipeline.ingest(SensorReading.Motion(sample(18.0, 8.0)))
        assertFalse(pipeline.submit(CrashCandidate(uptime = 18.0, date = 0.0, transportationMode = TransportationMode.car)))
    }

    @Test fun watchdogFinalizesMissingPostImpactDataAsInconclusive() {
        val pipeline = CrashPipeline()
        for (sample in trace().filter { it.uptime < 12.1 }) pipeline.ingest(SensorReading.Motion(sample))
        val result = pipeline.advance(16.0)
        assertEquals(CrashDecision.inconclusive, result?.decision)
        assertTrue(result?.issues?.contains(CrashDataIssue.insufficientPostImpact) == true)
    }

    @Test fun pipelineIgnoresInvalidAndReversedSamplesAndBoundsStorage() {
        val pipeline = CrashPipeline(automaticCandidates = false)
        for (index in 0 until 3000) pipeline.ingest(SensorReading.Motion(sample(index / 100.0, 0.0)))
        assertEquals(2048, pipeline.motion.count)
        val last = pipeline.motion.values.last()
        pipeline.ingest(SensorReading.Motion(sample(1.0, 8.0)))
        pipeline.ingest(SensorReading.Motion(sample(Double.NaN, 8.0)))
        assertEquals(last, pipeline.motion.values.last())
        assertNull(pipeline.pending)
    }

    @Test fun ringWrapsInChronologicalOrder() {
        val ring = SensorRing<Int>(3)
        for (number in 1..5) ring.append(number)
        assertEquals(listOf(3, 4, 5), ring.values)
    }

    @Test fun invalidConfigurationsAreDetectable() {
        assertTrue(CrashEvaluationConfiguration().isValid)
        assertFalse(CrashEvaluationConfiguration(candidateG = Double.NaN).isValid)
    }
}
