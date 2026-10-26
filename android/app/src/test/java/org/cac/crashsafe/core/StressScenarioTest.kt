package org.cac.crashsafe.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.cac.crashsafe.core.crash.CrashDecision
import org.cac.crashsafe.core.crash.CrashEvidence
import org.cac.crashsafe.core.crash.CrashPipeline
import org.cac.crashsafe.core.crash.PhoneMount
import org.cac.crashsafe.core.crash.ScenarioFactory
import org.cac.crashsafe.core.crash.ScenarioOutcome
import org.cac.crashsafe.core.crash.SeededGenerator
import org.cac.crashsafe.core.crash.SensorScenario
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorCSV
import org.cac.crashsafe.core.sensors.SensorLabMath
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorVector
import org.cac.crashsafe.core.sensors.JoltTracker
import org.cac.crashsafe.core.sensors.Jolt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Regression tests from the virtual stress test (`Tools/StressLab`, docs/stress-test-report.md):
 * real crash pulses, real walking, and the generated events that exposed gaps.
 */
class StressScenarioTest {
    @Serializable
    data class Clip(val closing_kmh: Double, val x: List<Double>, val y: List<Double>, val z: List<Double>,
                    val delta_v_mps: Map<String, Double>)

    private fun clip(name: String): Clip =
        Json { ignoreUnknownKeys = true }.decodeFromString(Clip.serializer(), Fixtures.text("$name.json"))

    @Test fun realThirtyFiveMphBarrierCrashChecksInFromEveryMount() {
        val clip = clip("nhtsa_v07605_frontal_35mph")
        val rng = SeededGenerator(1)
        for (saturation in listOf(8.0, 16.0)) {
            for (mount in PhoneMount.standard) {
                val scenario = ScenarioFactory(saturationG = saturation).vehiclePulse(clip.x, clip.y, clip.z,
                    speedBeforeMPS = clip.closing_kmh / 3.6, speedAfterMPS = 0.0, deltaVMPS = abs(clip.delta_v_mps.getValue("x")),
                    title = "", mount = mount, rng = rng)
                val outcome = ScenarioOutcome.evaluate(scenario)
                assertTrue("${mount.name} ±$saturation g", outcome.alerted)
                assertTrue(outcome.assessments.first().evidence.contains(CrashEvidence.speedLoss))
            }
        }
    }

    @Test fun carHitFromTheSideWhileStoppedChecksInWithoutAnyGPSSpeedLoss() {
        val clip = clip("nhtsa_v07602_side_struck_while_stopped")
        val rng = SeededGenerator(2)
        val dv = abs(clip.delta_v_mps.getValue("y"))
        val scenario = ScenarioFactory().vehiclePulse(clip.x, clip.y, clip.z, speedBeforeMPS = 0.0, speedAfterMPS = dv,
            deltaVMPS = dv, title = "", mount = PhoneMount.dash, rng = rng)
        val outcome = ScenarioOutcome.evaluate(scenario)
        assertTrue(outcome.alerted)
        val assessment = outcome.assessments.first { it.decision == CrashDecision.suspectedCrash }
        assertTrue(CrashEvidence.largeImpactDeltaV in assessment.evidence)
        assertFalse(CrashEvidence.speedLoss in assessment.evidence)
        // The pulse's own speed change matches what NHTSA measured (19 mph) within 15%.
        assertTrue(abs((assessment.impactDeltaVMPS ?: 0.0) - dv) / dv < 0.15)
    }

    @Test fun briskRealWalkingNeverChecksIn() {
        val rows = Fixtures.text("motionsense_wlk7_sub24_60-70s.csv").lines().drop(1).filter { it.isNotBlank() }
        val pipeline = CrashPipeline()
        val decisions = mutableListOf<CrashDecision>()
        rows.forEachIndexed { i, line ->
            val c = line.split(",").mapNotNull { it.toDoubleOrNull() }
            if (c.size < 13) return@forEachIndexed
            val t = 100 + i / 50.0
            val sample = MotionSample(uptime = t, date = t, accelerationG = SensorVector(c[10], c[11], c[12]),
                gravityG = SensorVector(c[4], c[5], c[6]), rotationRate = SensorVector(c[7], c[8], c[9]))
            pipeline.ingest(SensorReading.Motion(sample))?.let { decisions.add(it.decision) }
        }
        pipeline.advance(200.0)?.let { decisions.add(it.decision) }
        assertTrue(decisions.isNotEmpty()) // its 4 g heel strikes do get examined…
        assertFalse(CrashDecision.suspectedCrash in decisions) // …and are not called a crash.
    }

    @Test fun generatedCrashesAreCaughtAndLookAlikesAreNot() {
        val rng = SeededGenerator(2026)
        val factory = ScenarioFactory()
        var caught = 0
        repeat(40) {
            if (ScenarioOutcome.evaluate(factory.make(SensorScenario.Kind.frontalCrash, rng)).alerted) caught++
        }
        assertTrue("caught $caught of 40", caught >= 38)
        for (kind in SensorScenario.Kind.entries.filter { !it.isCrash }) {
            repeat(15) {
                val s = factory.make(kind, rng)
                assertFalse("${kind.title}: ${s.detail}", ScenarioOutcome.evaluate(s).alerted)
            }
        }
    }

    @Test fun emergencyStopWherePhoneFallsIsNotACrash() {
        val rng = SeededGenerator(7)
        repeat(30) {
            val s = ScenarioFactory().make(SensorScenario.Kind.phoneFliesOffMountWhileBraking, rng)
            assertFalse(s.detail, ScenarioOutcome.evaluate(s).alerted)
        }
    }

    @Test fun rearEndedWhileStoppedIsCaughtAboveSevenMph() {
        val rng = SeededGenerator(11)
        var caught = 0
        var total = 0
        repeat(60) {
            val s = ScenarioFactory().make(SensorScenario.Kind.rearEndedWhileStopped, rng)
            val dv = s.trueDeltaVMPS ?: return@repeat
            if (dv < 3.5) return@repeat
            total++
            if (ScenarioOutcome.evaluate(s).alerted) caught++
        }
        assertTrue("caught $caught of $total", total > 20 && caught == total)
    }

    @Test fun scenariosAreReproducible() {
        val s1 = ScenarioFactory().make(SensorScenario.Kind.pothole, SeededGenerator(5))
        val s2 = ScenarioFactory().make(SensorScenario.Kind.pothole, SeededGenerator(5))
        assertTrue(s1.readings.size == s2.readings.size && s1.detail == s2.detail)
    }

    @Test fun seededGeneratorMatchesSplitMix64() {
        // SplitMix64 reference values for seed 0 (Vigna's splitmix64.c).
        val rng = SeededGenerator(0)
        assertEquals(java.lang.Long.parseUnsignedLong("16294208416658607535"), rng.next())
        assertEquals(java.lang.Long.parseUnsignedLong("7960286522194355700"), rng.next())
    }
}

class SensorLabTest {
    @Test fun tiltFromGravity() {
        val flat = SensorLabMath.tilt(SensorVector(0.0, 0.0, -1.0))!!
        assertTrue(abs(flat.pitch) < 1e-9 && abs(flat.roll) < 1e-9 && abs(flat.fromFlat) < 1e-9)
        assertTrue(abs(flat.bubble.first) < 1e-9 && abs(flat.bubble.second) < 1e-9)
        val upright = SensorLabMath.tilt(SensorVector(0.0, -1.0, 0.0))!!
        assertTrue(abs(upright.pitch - 90) < 1e-9 && abs(upright.fromFlat - 90) < 1e-9)
        // Right edge lowered 30°: the bubble floats left, toward the raised edge.
        val s = sin(PI / 6)
        val c = cos(PI / 6)
        val rolled = SensorLabMath.tilt(SensorVector(s, 0.0, -c))!!
        assertTrue(abs(rolled.roll - 30) < 1e-9)
        assertTrue(rolled.bubble.first < -0.6 && abs(rolled.bubble.second) < 1e-9)
        // Top edge raised 20°: bubble moves up the screen.
        val pitched = SensorLabMath.tilt(SensorVector(0.0, -sin(PI / 9), -cos(PI / 9)))!!
        assertTrue(abs(pitched.pitch - 20) < 1e-9 && pitched.bubble.second < 0)
        assertNull(SensorLabMath.tilt(SensorVector.zero))
    }

    @Test fun splitsAccelerationAroundGravity() {
        val (h, v) = SensorLabMath.split(SensorVector(0.3, 0.0, -0.4), SensorVector(0.0, 0.0, -1.0))
        assertTrue(abs(h - 0.3) < 1e-12 && abs(v - 0.4) < 1e-12)
    }

    @Test fun gpsSpeedChangeInG() {
        val a = LocationSample(uptime = 10.0, date = 0.0, latitude = 45.0, longitude = -122.0, horizontalAccuracy = 5.0,
            speedMPS = 20.0, speedAccuracy = 0.5)
        var b = a.copy(uptime = 11.0, speedMPS = 20 - 9.80665 * 0.5)
        assertTrue(abs(SensorLabMath.longitudinalG(a, b)!! + 0.5) < 1e-9)
        b = b.copy(uptime = 10.1)
        assertNull(SensorLabMath.longitudinalG(a, b))
        assertTrue(SensorLabMath.compass(95.0) == "E" && SensorLabMath.compass(350.0) == "N")
    }

    @Test fun joltTrackerTellsBumpsHitsAndDropsApart() {
        val tracker = JoltTracker()
        fun feed(seconds: Double, t0: Double, accel: SensorVector, gravity: SensorVector = SensorVector(0.0, 0.0, -1.0)): Double {
            for (i in 0 until (seconds * 100).toInt()) {
                val t = t0 + i / 100.0
                tracker.add(MotionSample(uptime = t, date = 0.0, accelerationG = accel, gravityG = gravity, rotationRate = SensorVector.zero))
            }
            return t0 + seconds
        }
        var t = feed(1.0, 0.0, SensorVector.zero)
        t = feed(0.03, t, SensorVector(0.8, 0.0, 0.0))
        t = feed(0.5, t, SensorVector.zero)
        t = feed(0.02, t, SensorVector(4.0, 0.0, 0.0))
        t = feed(0.5, t, SensorVector.zero)
        // Free fall (accelerometer reads 0: user acceleration cancels gravity), then a landing.
        t = feed(0.3, t, SensorVector(0.0, 0.0, 1.0))
        t = feed(0.02, t, SensorVector(0.0, 0.0, 9.0))
        feed(0.3, t, SensorVector.zero)
        assertEquals(listOf(Jolt.Kind.bump, Jolt.Kind.crashLevel, Jolt.Kind.drop), tracker.jolts.map { it.kind })
        assertEquals(4.0, tracker.jolts[1].peakG, 0.0)
    }

    @Test fun csvRoundTripKeepsMotionAndSpeedButNoCoordinates() {
        val readings = listOf(
            SensorReading.Motion(MotionSample(uptime = 5.0, date = 0.0, accelerationG = SensorVector(0.1, -0.2, 0.3),
                gravityG = SensorVector(0.0, -1.0, 0.0), rotationRate = SensorVector(1.0, 2.0, 3.0))),
            SensorReading.Location(LocationSample(uptime = 5.5, date = 0.0, latitude = 45.52, longitude = -122.68,
                horizontalAccuracy = 4.0, speedMPS = 12.5, speedAccuracy = 0.7)),
        )
        val csv = SensorCSV.encode(readings)
        assertFalse(csv.contains("45.52") || csv.contains("122.68"))
        val back = SensorCSV.decode(csv, start = 100.0)
        assertEquals(2, back.size)
        val m = (back[0] as SensorReading.Motion).sample
        val l = (back[1] as SensorReading.Location).sample
        assertTrue(m.uptime == 100.0 && abs(m.accelerationG.y + 0.2) < 1e-5 && abs(m.rotationRate.z - 3) < 1e-5)
        assertTrue(abs(l.uptime - 100.5) < 1e-9 && abs(l.speedMPS - 12.5) < 1e-5 && l.latitude == 0.0)
        assertNotNull(back)
    }
}
