package org.cac.crashsafe.services.sensors

import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHealth
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorState
import org.cac.crashsafe.core.util.nowSeconds
import java.util.UUID
import kotlin.math.abs

interface LocationSampleSource {
    val isDenied: Boolean
    fun addSampleObserver(receive: (LocationSample) -> Unit): UUID
    fun removeSampleObserver(id: UUID)
    fun start()
    fun setBackgroundUpdates(enabled: Boolean)
}

/**
 * A single acquisition session with independent consumers and reference-counted leases.
 * No raw readings are saved to disk or uploaded.
 */
class SensorHub(
    private val motion: MotionSource,
    private val location: LocationSampleSource,
    private val scope: CoroutineScope,
    private val now: () -> Double = { SystemClock.elapsedRealtimeNanos() / 1e9 },
    private val useWatchdog: Boolean = true,
    private val logStore: BackgroundSensorLog.Store? = null,
    private val appState: () -> AppState.Snapshot = { AppState.current() },
) {
    var health by mutableStateOf(SensorHealth())
        private set
    /** Readings received while off screen or locked (see `BackgroundSensorLog`). */
    var backgroundLog by mutableStateOf(logStore?.load() ?: BackgroundSensorLog())
        private set
    var isRunning by mutableStateOf(false)
        private set
    val hasMotionHardware: Boolean get() = motion.isAvailable

    private val owners = mutableMapOf<UUID, Boolean>()
    private val observers = linkedMapOf<UUID, (SensorReading) -> Unit>()
    private var locationObserver: UUID? = null
    private var watchdog: Job? = null
    private var lastMotion: Double? = null
    private var lastLocation: Double? = null
    private var latestLocation: LocationSample? = null
    private var rateStart: Double? = null
    private var rateCount = 0
    private var startedAt = 0.0
    private var lastLogSave = 0.0

    fun resetBackgroundLog() {
        backgroundLog = BackgroundSensorLog()
        logStore?.save(backgroundLog)
    }

    fun addObserver(receive: (SensorReading) -> Unit): UUID {
        val id = UUID.randomUUID()
        observers[id] = receive
        return id
    }

    fun removeObserver(id: UUID) {
        observers.remove(id)
    }

    fun acquire(owner: UUID, background: Boolean) {
        val wasRunning = owners.isNotEmpty()
        owners[owner] = background
        isRunning = true
        location.setBackgroundUpdates(owners.values.contains(true))
        if (wasRunning) return
        health = SensorHealth(state = if (motion.isAvailable) SensorState.starting else SensorState.unavailable, locationUnavailable = true)
        lastMotion = null
        lastLocation = null
        latestLocation = null
        rateStart = null
        rateCount = 0
        startedAt = now()
        locationObserver = location.addSampleObserver { receive(it) }
        location.start()
        if (motion.isAvailable) startMotion()
        if (useWatchdog) {
            watchdog = scope.launch {
                while (isActive) {
                    delay(1000)
                    checkFreshness()
                }
            }
        }
    }

    /**
     * Call when the app returns to the foreground (for example, from Settings): a stream that was
     * denied, interrupted or stale is started again, without restarting the drive.
     */
    fun refreshAfterForeground() {
        if (!isRunning) return
        location.start()
        when (health.state) {
            SensorState.permissionDenied, SensorState.interrupted, SensorState.stale, SensorState.unavailable -> {
                if (!motion.isAvailable) {
                    health = health.copy(state = SensorState.unavailable)
                    return
                }
                motion.stop()
                lastMotion = null
                rateStart = null
                rateCount = 0
                startedAt = now()
                health = health.copy(state = SensorState.starting)
                startMotion()
            }
            SensorState.starting, SensorState.active, SensorState.stopped -> {}
        }
    }

    /**
     * The motion source started or stopped delivering on its own (a replayed clip began or ended).
     * Starts motion if it can now, or marks it unavailable instead of letting it go stale.
     */
    fun motionSourceChanged() {
        if (!isRunning) return
        if (motion.isAvailable) {
            if (health.state == SensorState.active || health.state == SensorState.starting) return
            motion.stop()
            lastMotion = null
            rateStart = null
            rateCount = 0
            startedAt = now()
            health = health.copy(state = SensorState.starting)
            startMotion()
        } else {
            motion.stop()
            health = health.copy(state = SensorState.unavailable, measuredHz = 0.0)
        }
    }

    private fun startMotion() {
        motion.start(1 / health.requestedHz) { sample, denied ->
            if (!isRunning) return@start
            if (sample == null) {
                health = health.copy(state = if (denied) SensorState.permissionDenied else SensorState.interrupted)
                return@start
            }
            receive(sample)
        }
    }

    fun release(owner: UUID) {
        if (owners.remove(owner) == null) return
        location.setBackgroundUpdates(owners.values.contains(true))
        if (owners.isNotEmpty()) return
        isRunning = false
        motion.stop()
        locationObserver?.let { location.removeSampleObserver(it) }
        locationObserver = null
        watchdog?.cancel()
        watchdog = null
        health = health.copy(state = SensorState.stopped)
        // The location service also serves maps/weather; releasing motion must not stop those consumers.
    }

    fun checkFreshness() {
        if (!isRunning) return
        setLocationUnavailable(location.isDenied || !(latestLocation?.hasReliableSpeed(now(), maximumAge = 5.0) ?: false))
        if (health.state != SensorState.active && health.state != SensorState.starting) return
        if (now() - (lastMotion ?: startedAt) > 0.5) health = health.copy(state = SensorState.stale)
    }

    private fun noteOffScreen(isMotion: Boolean, gap: Double?) {
        val state = appState()
        if (!state.background && !state.locked) return
        val firstOffScreen = backgroundLog.isEmpty
        backgroundLog = backgroundLog.recording(isMotion, gap, state.background, state.locked, nowSeconds())
        if (firstOffScreen) Log.i(BackgroundSensorLog.TAG, "Off-screen sensor readings started (locked: ${state.locked})")
        // Persist about every 5 s so the count survives the app being closed.
        if (logStore != null && now() - lastLogSave > 5) {
            lastLogSave = now()
            logStore.save(backgroundLog)
        }
    }

    private fun receive(sample: MotionSample) {
        if (!isRunning) return
        val last = lastMotion
        if (!sample.isValid || sample.uptime > now() + 0.05 || now() - sample.uptime > 0.5 || (last != null && sample.uptime <= last)) {
            health = health.copy(rejectedMotionSamples = health.rejectedMotionSamples + 1)
            return
        }
        if (last != null && sample.uptime - last > 0.15) health = health.copy(motionGaps = health.motionGaps + 1)
        noteOffScreen(true, last?.let { sample.uptime - it })
        lastMotion = sample.uptime
        rateCount++
        val start = rateStart
        if (start != null && sample.uptime - start >= 1) {
            val hz = (rateCount - 1) / (sample.uptime - start)
            if (abs(hz - health.measuredHz) >= 0.5) health = health.copy(measuredHz = hz)
            rateStart = sample.uptime
            rateCount = 1
        } else if (start == null) {
            rateStart = sample.uptime
        }
        // `health` is observed by Home, Profile and drive mode: write it only when something changed.
        // Writing it on every sample (100 a second) would redraw those screens 100 times a second.
        if (health.state != SensorState.active) health = health.copy(state = SensorState.active)
        val reading = SensorReading.Motion(sample)
        for (observer in observers.values.toList()) observer(reading)
    }

    private fun receive(sample: LocationSample) {
        if (!isRunning) return
        val last = lastLocation
        if (!sample.isValid || sample.uptime > now() + 0.05 || now() - sample.uptime > 5 || (last != null && sample.uptime <= last)) {
            health = health.copy(rejectedLocationSamples = health.rejectedLocationSamples + 1)
            return
        }
        lastLocation = sample.uptime
        latestLocation = sample
        noteOffScreen(false, null)
        setLocationUnavailable(!sample.hasReliableSpeed(now(), maximumAge = 5.0))
        val reading = SensorReading.Location(sample)
        for (observer in observers.values.toList()) observer(reading)
    }

    private fun setLocationUnavailable(unavailable: Boolean) {
        if (health.locationUnavailable != unavailable) health = health.copy(locationUnavailable = unavailable)
    }
}
