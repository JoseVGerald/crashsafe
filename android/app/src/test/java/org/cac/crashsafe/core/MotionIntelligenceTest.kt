package org.cac.crashsafe.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.cac.crashsafe.core.crash.ImpactAnalyzer
import org.cac.crashsafe.core.crash.ImpactReport
import org.cac.crashsafe.core.intelligence.FeatureTransportModel
import org.cac.crashsafe.core.intelligence.HarshEvent
import org.cac.crashsafe.core.intelligence.HarshEventDetector
import org.cac.crashsafe.core.intelligence.LongitudinalEventDetector
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.intelligence.TransportObservation
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHistory
import org.cac.crashsafe.core.sensors.SensorVector
import org.cac.crashsafe.core.sensors.SynchronizedWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin

class SensorHistoryTest {
    @Test fun resamplesToTheTransportRepoContract() {
        val h = Synthetic.history(seconds = 8.0, speed = { 10.0 }) { t -> SensorVector(0.1 * t, 0.0, 0.0) }
        val w = h.window(endingAt = 107.0, duration = 5.0)!!
        assertTrue(w.count == SynchronizedWindow.contractSamples && w.hz == 50.0)
        // Linear interpolation of a linear signal is exact; g → m/s².
        assertTrue(abs(w.linearAccelerationMS2[0].x - 0.1 * w.startUptime * 9.80665) < 1e-6)
        assertTrue(w.speedMPS.all { it == 10.0 })
        assertTrue(w.fixes.size == 5 || w.fixes.size == 6)
    }

    @Test fun failsClosedOnGapsAndMissingCoverage() {
        var h = Synthetic.history(seconds = 8.0, speed = { 0.0 }) { SensorVector.zero }
        assertNull(h.window(endingAt = 120.0, duration = 5.0)) // beyond the data
        assertNull(h.window(endingAt = 103.0, duration = 5.0)) // before the data starts
        // A 0.5 s hole inside the window.
        h = SensorHistory()
        for (i in 0 until 800) if (i !in 300 until 350) h.append(Synthetic.motion(100 + i / 100.0, SensorVector.zero))
        assertNull(h.window(endingAt = 107.0, duration = 5.0))
        assertFalse(h.append(Synthetic.motion(50.0, SensorVector.zero))) // out of order is refused
    }

    @Test fun historyIsBounded() {
        val h = Synthetic.history(seconds = 60.0, speed = { 1.0 }) { SensorVector.zero }
        assertEquals(SensorHistory.motionCapacity, h.motion.count)
    }
}

class ImpactAnalysisTest {
    companion object {
        /** 35 mph, then a 100 ms half-sine pulse of 10 g along -y, then braking to a stop. */
        fun crash(): Pair<SensorHistory, Double> {
            val impact = 108.0
            val h = Synthetic.history(seconds = 18.0, speed = { t -> if (t < impact) 15.6 else max(0.0, 9 - (t - impact) * 3.6) }) { t ->
                when {
                    t >= impact && t <= impact + 0.1 -> SensorVector(0.0, -10 * sin(PI * (t - impact) / 0.1), 0.0)
                    t > impact + 0.1 && t < impact + 2.6 -> SensorVector(0.0, -0.38, 0.0)
                    else -> SensorVector(0.002, 0.0, 0.003)
                }
            }
            return h to impact
        }
    }

    @Test fun measuresPeakDeltaVAndStop() {
        val (h, impact) = crash()
        val r = ImpactAnalyzer.analyze(h, impact + 0.05)!!
        assertTrue(abs(r.peakG - 10) < 0.1)
        // ∫ 10 g · sin over 0.1 s = 10 · 9.80665 · 0.1 · 2/π ≈ 6.24 m/s (above the 0.8 g pulse edge).
        assertTrue(r.deltaVMPS > 5.9 && r.deltaVMPS < 6.3)
        assertTrue(r.pulseDuration > 0.08 && r.pulseDuration < 0.11)
        assertEquals(15.6, r.preImpactSpeedMPS!!, 0.0)
        assertEquals("gps", r.stopBasis)
        assertTrue(r.timeToStop!! > 2 && r.timeToStop!! < 3.1)
        assertEquals(ImpactReport.Severity.moderate, r.severity)
        assertFalse(r.isSimulated)
    }

    @Test fun severityBandsAndSimulatedReport() {
        val simulated = ImpactAnalyzer.simulatedReport()
        assertTrue(simulated.isSimulated && simulated.severity == ImpactReport.Severity.moderate)
        assertTrue(abs(simulated.deltaVMPH - 14) < 1)
        // Not enough motion after the impact: no report rather than a guess.
        val (h, impact) = crash()
        assertNull(ImpactAnalyzer.analyze(h, impact + 9.5))
    }
}

class TransportModeTest {
    private val model = FeatureTransportModel()

    private fun classify(h: SensorHistory, end: Double = 108.0): TransportObservation {
        val w = h.window(endingAt = end, duration = 5.0)!!
        return TransportObservation.of(model.probabilities(TransportFeatures.extract(w)), model.modelID)
    }

    @Test fun walkingIsRecognizedFromStepCadence() {
        // 1.9 steps/s, ±0.25 g vertical bounce, 1.4 m/s.
        val h = Synthetic.history(seconds = 9.0, speed = { 1.4 }) { t ->
            SensorVector(0.05 * sin(2 * PI * 0.95 * t), 0.0, 0.25 * sin(2 * PI * 1.9 * t))
        }
        val o = classify(h)
        assertEquals("walk", o.label)
        assertTrue(o.probability >= TransportObservation.acceptance)
        assertTrue(abs(o.probabilities.sum() - 1) < 1e-9)
    }

    @Test fun drivingAndStillAreSeparated() {
        val car = Synthetic.history(seconds = 9.0, speed = { 20.0 }) { t ->
            SensorVector(0.02 * sin(t * 13), 0.03 * sin(t * 7), 0.04 * sin(t * 17))
        }
        assertEquals("car", classify(car).label)
        val still = Synthetic.history(seconds = 9.0, speed = { 0.0 }) { SensorVector(0.001, 0.0, 0.002) }
        assertEquals("still", classify(still).label)
    }

    @Test fun gpsFeaturesMatchTheRepoFormula() {
        // Five fixes 1 s apart heading north at 10 m/s: speed 10, distance 40, no heading change.
        val fixes = (0 until 5).map { i ->
            LocationSample(uptime = i.toDouble(), date = i.toDouble(), latitude = 45 + i * 10 / 111_195.0, longitude = -122.0,
                horizontalAccuracy = 5.0, speedMPS = 10.0, speedAccuracy = 1.0)
        }
        val f = TransportFeatures.gpsFeatures(fixes, 5000.0)!!
        assertEquals(12, f.size)
        assertTrue(abs(f[0] - 10) < 0.01 && abs(f[5] - 40) < 0.05 && f[7] < 1e-6)
        assertTrue(f[10] == 5.0 && abs(f[11] - 0.8) < 1e-9)
    }

    @Test fun dampedPerWindowNormalizationMatchesTrainShl() {
        val channels = listOf(listOf(1.0, 2.0, 3.0, 4.0), listOf(5.0, 5.0, 5.0, 5.0))
        val x = TransportFeatures.normalizedIMU(channels, floor = listOf(0.1, 0.5), clip = 1.5)!!
        assertTrue(abs(x[0].sum()) < 1e-9)          // zero mean
        assertTrue(x[0].all { abs(it) <= 1.5 })      // clipped
        assertTrue(x[1].all { it == 0.0 })           // flat channel stays 0 (floor, not divide by 0)
        assertNull(TransportFeatures.normalizedIMU(channels, floor = listOf(0.1), clip = 3.0)) // no invented floors
    }
}

class HarshEventTest {
    @Test fun hardBrakingIsDetectedFromGpsSpeedChange() {
        // 20 m/s, then −5 m/s per second (0.51 g) for 2 s.
        val h = Synthetic.history(seconds = 10.0, speed = { t -> if (t < 104) 20.0 else max(10.0, 20 - (t - 104) * 5) }) { SensorVector.zero }
        val events = HarshEventDetector().detect(h.window(endingAt = 108.0, duration = 5.0)!!)
        assertEquals(1, events.size)
        assertEquals(HarshEvent.Kind.harshBrake, events.first().kind)
        assertTrue(events.first().severity > 0.9)
        val steady = Synthetic.history(seconds = 10.0, speed = { 20.0 }) { SensorVector.zero }
        assertTrue(HarshEventDetector().detect(steady.window(endingAt = 108.0, duration = 5.0)!!).isEmpty())
    }
}

/**
 * The backend (Backend/rag/motion_intel.py) writes these values from the same synthetic signals;
 * matching them keeps the app and the agent backend computing identical numbers.
 */
class BackendParityTest {
    private val golden: JsonObject = Json.parseToJsonElement(Fixtures.text("motion_golden.json")).jsonObject

    private fun probabilities(key: String): List<Double> =
        golden[key]!!.jsonObject["probabilities"]!!.jsonArray.map { it.jsonPrimitive.double }

    @Test fun transportProbabilitiesMatchTheBackend() {
        val walk = Synthetic.history(seconds = 9.0, speed = { 1.4 }) { t ->
            SensorVector(0.05 * sin(2 * PI * 0.95 * t), 0.0, 0.25 * sin(2 * PI * 1.9 * t))
        }
        val car = Synthetic.history(seconds = 9.0, speed = { 20.0 }) { t ->
            SensorVector(0.02 * sin(t * 13), 0.03 * sin(t * 7), 0.04 * sin(t * 17))
        }
        for ((key, h) in listOf("walk" to walk, "car" to car)) {
            val expected = probabilities(key)
            assertEquals(8, expected.size)
            val w = h.window(endingAt = 108.0, duration = 5.0)!!
            val ours = FeatureTransportModel().probabilities(TransportFeatures.extract(w))
            for ((a, b) in ours.zip(expected)) assertTrue("$key: $a vs $b", abs(a - b) < 1e-9)
        }
    }

    @Test fun impactMatchesTheBackend() {
        val expected = golden["crash_impact"]!!.jsonObject
        val (h, impact) = ImpactAnalysisTest.crash()
        val r = ImpactAnalyzer.analyze(h, impact + 0.05)!!
        assertEquals(expected["delta_v_mps"]!!.jsonPrimitive.double, r.deltaVMPS, 1e-9)
        assertEquals(expected["peak_g"]!!.jsonPrimitive.double, r.peakG, 1e-9)
        assertEquals(expected["pulse_duration_s"]!!.jsonPrimitive.double, r.pulseDuration, 1e-9)
        assertEquals(expected["time_to_stop_s"]!!.jsonPrimitive.double, r.timeToStop!!, 1e-9)
        assertEquals(expected["severity"]!!.jsonPrimitive.content, r.severity.name)
    }

    @Test fun harshEventsMatchTheBackend() {
        val expected = golden["brake_events"] as JsonArray
        val h = Synthetic.history(seconds = 10.0, speed = { t -> if (t < 104) 20.0 else max(10.0, 20 - (t - 104) * 5) }) { SensorVector.zero }
        val events = HarshEventDetector().detect(h.window(endingAt = 108.0, duration = 5.0)!!)
        assertEquals(expected.size, events.size)
        for ((e, x) in events.zip(expected)) {
            val o = x.jsonObject
            assertEquals(o["kind"]!!.jsonPrimitive.content, e.kind.raw)
            assertEquals(o["start"]!!.jsonPrimitive.double, e.start, 1e-9)
            assertEquals(o["end"]!!.jsonPrimitive.double, e.end, 1e-9)
        }
    }
}

class LongitudinalEventTest {
    private fun run(detector: LongitudinalEventDetector, start: Double, seconds: Double, g: Double, yaw: Double): List<Double> {
        val hits = mutableListOf<Double>()
        for (i in 0 until (seconds * 100).toInt()) {
            val t = start + i / 100.0
            val s = MotionSample(uptime = t, date = 0.0, accelerationG = SensorVector(g + 0.02 * sin(t * 40), 0.0, 0.03 * sin(t * 25)),
                gravityG = SensorVector(0.0, 0.0, -1.0), rotationRate = SensorVector(0.01, 0.0, yaw))
            detector.add(s)?.let { hits.add(it) }
        }
        return hits
    }

    @Test fun hardStopIsCaughtButTurnsAndJoltsAreNot() {
        val d = LongitudinalEventDetector()
        assertTrue(run(d, 0.0, 5.0, 0.02, 0.0).isEmpty())          // cruising
        assertEquals(1, run(d, 5.0, 1.5, 0.35, 0.03).size)          // hard stop
        assertTrue(run(d, 10.0, 3.0, 0.42, 0.45).isEmpty())        // hard turn
        assertTrue(run(d, 15.0, 0.3, 0.6, 0.0).isEmpty())          // pothole jolt
        assertTrue(run(d, 20.0, 1.5, 0.18, 0.0).isEmpty())         // gentle stop
        assertNotNull(d)
    }
}
