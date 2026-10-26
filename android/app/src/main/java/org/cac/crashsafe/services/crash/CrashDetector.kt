package org.cac.crashsafe.services.crash

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.crash.CrashAssessment
import org.cac.crashsafe.core.crash.CrashCandidate
import org.cac.crashsafe.core.crash.CrashDecision
import org.cac.crashsafe.core.crash.CrashEvaluationConfiguration
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.CrashPipeline
import org.cac.crashsafe.core.crash.TransportationMode
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.services.sensors.SensorHub
import java.util.UUID

/**
 * Watches sensors during an active trip and emits `CrashEvent`s.
 *
 * The live implementation shares acquisition with the dashboard and evaluates candidates offline.
 */
interface CrashDetector {
    val isMonitoring: Boolean
    /** Single stream of detected crashes for the lifetime of the app. */
    val events: SharedFlow<CrashEvent>
    fun startMonitoring(carType: CarType)
    fun stopMonitoring()
    /** Demo hook: emits a fake event so the check-in flow can be shown without crashing a car. */
    fun simulateCrash()
}

private fun crashEvents() = MutableSharedFlow<CrashEvent>(replay = 0, extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

/**
 * Step 5 integration. Only suspected crashes enter the check-in flow.
 * All assessments remain inspectable; inconclusive events do not claim that the user is safe.
 */
class LiveCrashDetector(
    private val sensors: SensorHub,
    private val scope: CoroutineScope,
    private val configuration: CrashEvaluationConfiguration = CrashEvaluationConfiguration(),
    private val automaticCandidates: Boolean = true,
    private val useWatchdog: Boolean = true,
    /** True while readings must not reach crash detection (a Sensor Lab replay, unless the tester opts in). */
    private val ignoreReadings: () -> Boolean = { false },
) : CrashDetector {
    override var isMonitoring by mutableStateOf(false)
        private set
    var lastAssessment by mutableStateOf<CrashAssessment?>(null)
        private set
    private val flow = crashEvents()
    override val events: SharedFlow<CrashEvent> = flow
    private val owner = UUID.randomUUID()
    private var observer: UUID? = null
    private var timer: Job? = null
    private var pipeline = CrashPipeline(configuration, automaticCandidates = automaticCandidates)

    override fun startMonitoring(carType: CarType) {
        if (isMonitoring) return
        val mode = when (carType) {
            CarType.motorcycle -> TransportationMode.motorcycle
            CarType.other -> TransportationMode.unknown
            else -> TransportationMode.car
        }
        pipeline = CrashPipeline(configuration, transportationMode = mode, automaticCandidates = automaticCandidates)
        lastAssessment = null
        isMonitoring = true
        observer = sensors.addObserver { reading ->
            if (isMonitoring && !ignoreReadings()) publish(pipeline.ingest(reading))
        }
        sensors.acquire(owner, background = true)
        if (useWatchdog) {
            timer = scope.launch {
                while (isActive && isMonitoring) {
                    delay(250)
                    publish(pipeline.advance(SystemClock.elapsedRealtimeNanos() / 1e9))
                }
            }
        }
    }

    /** Integration point for step 4. Candidate timestamps use the shared monotonic sensor clock. */
    fun submitCandidate(candidate: CrashCandidate): Boolean = isMonitoring && pipeline.submit(candidate)

    override fun stopMonitoring() {
        isMonitoring = false
        timer?.cancel()
        timer = null
        observer?.let { sensors.removeObserver(it) }
        observer = null
        sensors.release(owner)
        pipeline = CrashPipeline(configuration, automaticCandidates = automaticCandidates)
    }

    override fun simulateCrash() {
        flow.tryEmit(CrashEvent(date = nowSeconds(), peakG = 6.2, speedDropMPH = 38.0, isSimulated = true))
    }

    private fun publish(assessment: CrashAssessment?) {
        if (assessment == null) return
        lastAssessment = assessment
        if (assessment.decision != CrashDecision.suspectedCrash) return
        flow.tryEmit(CrashEvent(date = assessment.candidate.date, peakG = assessment.peakG,
            speedDropMPH = assessment.speedDropMPS?.let { it * 2.23694 }, isSimulated = false, assessment = assessment))
    }
}

/** Never detects anything on its own; only `simulateCrash()` emits events. */
class MockCrashDetector : CrashDetector {
    override var isMonitoring by mutableStateOf(false)
        private set
    private val flow = crashEvents()
    override val events: SharedFlow<CrashEvent> = flow

    override fun startMonitoring(carType: CarType) {
        isMonitoring = true
    }

    override fun stopMonitoring() {
        isMonitoring = false
    }

    override fun simulateCrash() {
        flow.tryEmit(CrashEvent(date = nowSeconds(), peakG = 6.2, speedDropMPH = 38.0, isSimulated = true))
    }
}
