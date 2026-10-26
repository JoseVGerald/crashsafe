package org.cac.crashsafe.services.intelligence

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.ImpactAnalyzer
import org.cac.crashsafe.core.crash.ImpactReport
import org.cac.crashsafe.core.intelligence.FeatureTransportModel
import org.cac.crashsafe.core.intelligence.HarshEvent
import org.cac.crashsafe.core.intelligence.HarshEventDetector
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.intelligence.TransportModeModel
import org.cac.crashsafe.core.intelligence.TransportObservation
import org.cac.crashsafe.core.pulse.AssistantActivity
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHistory
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorVector
import org.cac.crashsafe.core.sensors.SynchronizedWindow
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.services.sensors.SensorHub
import java.util.UUID
import kotlin.math.PI
import kotlin.math.sin

/**
 * Keeps the rolling sensor history while sensors run and turns it into what Pulse and the crash
 * flow use: the current transport mode, harsh braking/acceleration events, and impact reports.
 */
class MotionIntelligence(private val sensors: SensorHub, val model: TransportModeModel = FeatureTransportModel()) {
    data class TimedHarshEvent(val event: HarshEvent, val date: Double)

    /** Smoothed over the last three windows (~7.5 s). */
    var current by mutableStateOf<TransportObservation?>(null)
        private set
    var windowsAnalyzed by mutableIntStateOf(0)
        private set
    var lastWindowDate by mutableStateOf<Double?>(null)
        private set
    var recentHarshEvents by mutableStateOf<List<TimedHarshEvent>>(emptyList())
        private set
    /** True while the foreground activity-sensing lease is held. */
    var isSensingActivity by mutableStateOf(false)
        private set

    var history = SensorHistory()
        private set
    private var observer: UUID? = null
    private val recent = mutableListOf<TransportObservation>()
    private var lastClassified: Double? = null
    private var lastHarshCheck: Double? = null
    private val activityOwner = UUID.randomUUID()
    private val detector = HarshEventDetector()

    /** Starts listening to whatever the sensor hub delivers (drives, crash monitoring, activity sensing). */
    fun start() {
        if (observer != null) return
        observer = sensors.addObserver { ingest(it) }
    }

    /** While the app is on screen, keep sensors running so the mode shows up even when not driving. */
    fun setActivitySensing(on: Boolean) {
        if (on == isSensingActivity) return
        isSensingActivity = on
        if (on) sensors.acquire(activityOwner, background = false) else sensors.release(activityOwner)
    }

    fun ingest(reading: SensorReading) {
        if (!history.append(reading)) return
        val sample = (reading as? SensorReading.Motion)?.sample ?: return
        val t = sample.uptime
        if (t - (lastClassified ?: Double.NEGATIVE_INFINITY) >= HOP) {
            history.window(t, SynchronizedWindow.contractSamples / SynchronizedWindow.contractHz)?.let { window ->
                lastClassified = t
                classify(window, sample.date)
            }
        }
        if (t - (lastHarshCheck ?: Double.NEGATIVE_INFINITY) >= 5) {
            history.window(t, 5.0)?.let { window ->
                lastHarshCheck = t
                val start = sample.date - window.duration
                val found = detector.detect(window).map { TimedHarshEvent(it, start + it.start) }
                if (found.isNotEmpty()) recentHarshEvents = (recentHarshEvents + found).takeLast(20)
            }
        }
    }

    private fun classify(window: SynchronizedWindow, date: Double) {
        val probabilities = model.probabilities(TransportFeatures.extract(window))
        recent.add(TransportObservation.of(probabilities, model.modelID))
        if (recent.size > 3) recent.removeAt(0)
        val averaged = (0 until 8).map { i -> recent.sumOf { it.probabilities[i] } / recent.size }
        current = TransportObservation.of(averaged, model.modelID)
        windowsAnalyzed++
        lastWindowDate = date
    }

    /** Impact metrics for a crash event: measured from the history for real events, from the synthetic crash for tests. */
    fun impactReport(event: CrashEvent): ImpactReport? {
        if (event.isSimulated) return ImpactAnalyzer.simulatedReport()
        val uptime = event.assessment?.candidate?.uptime ?: return null
        return ImpactAnalyzer.analyze(history, uptime)
    }

    /** Harsh events in the last `seconds` (for Pulse and the incident packet). */
    fun harshEvents(within: Double, now: Double = nowSeconds()): List<TimedHarshEvent> =
        recentHarshEvents.filter { now - it.date <= within }

    /** What Pulse is told about right now (sent with every question; derived values only). */
    val assistantActivity: AssistantActivity?
        get() {
            val current = current ?: return null
            val recent = harshEvents(600.0)
            return AssistantActivity(
                transport = AssistantIncident.Transport(label = current.label, basis = "model", probability = current.probability, modelId = current.modelID),
                harshBrakes10min = recent.count { it.event.kind == HarshEvent.Kind.harshBrake },
                harshAccels10min = recent.count { it.event.kind == HarshEvent.Kind.harshAccel })
        }

    /** Harsh events in the minute before `date`, as the incident packet's behavior events (seconds from that minute's start). */
    fun behaviorEvents(before: Double): List<AssistantIncident.BehaviorEvent> {
        val start = before - 60
        return recentHarshEvents.filter { it.date >= start && it.date <= before }.takeLast(20).map {
            val offset = it.date - start
            AssistantIncident.BehaviorEvent(kind = it.event.kind.raw, start = offset, end = offset + (it.event.end - it.event.start),
                severity = it.event.severity)
        }
    }

    enum class TestMotion(val title: String) { walk("Walking"), drive("Driving"), still("Sitting still") }

    /**
     * Testing section: plays 12 s of synthetic motion + GPS through the real analysis (for emulators,
     * which have no real motion). Uptimes continue from the history so real readings still append.
     */
    fun replay(kind: TestMotion) {
        val start = (history.latestMotionUptime ?: (SystemClock.elapsedRealtimeNanos() / 1e9)) + 0.01
        val speed = when (kind) {
            TestMotion.walk -> 1.4
            TestMotion.drive -> 20.0
            TestMotion.still -> 0.0
        }
        var lat = 45.5152
        for (k in 0 until 1_200) {
            val t = start + k / 100.0
            val a = when (kind) {
                TestMotion.walk -> SensorVector(0.04 * sin(2 * PI * 0.95 * t), 0.0, 0.25 * sin(2 * PI * 1.9 * t))
                TestMotion.drive -> SensorVector(0.02 * sin(t * 13), 0.03 * sin(t * 7), 0.04 * sin(t * 17))
                TestMotion.still -> SensorVector(0.002, 0.001, 0.002)
            }
            val date = nowSeconds() + k / 100.0 - 12
            ingest(SensorReading.Motion(MotionSample(uptime = t, date = date, accelerationG = a,
                gravityG = SensorVector(0.0, 0.0, -1.0), rotationRate = SensorVector.zero)))
            if (k % 100 == 0) {
                ingest(SensorReading.Location(LocationSample(uptime = t, date = date, latitude = lat, longitude = -122.6784,
                    horizontalAccuracy = 5.0, speedMPS = speed, speedAccuracy = 0.5)))
                lat += speed / 111_320
            }
        }
    }

    fun reset() {
        history = SensorHistory()
        recent.clear()
        current = null
        windowsAnalyzed = 0
        lastClassified = null
        lastHarshCheck = null
        recentHarshEvents = emptyList()
    }

    companion object {
        const val HOP = 2.5
    }
}
