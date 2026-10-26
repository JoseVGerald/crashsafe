package org.cac.crashsafe.services.driving

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.driving.DriveScenario
import org.cac.crashsafe.core.driving.DrivingSnapshot
import org.cac.crashsafe.core.driving.RoadEnvironment
import org.cac.crashsafe.core.intelligence.LongitudinalEventDetector
import org.cac.crashsafe.core.roads.RoadKind
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHealth
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.services.sensors.SensorHub
import java.util.UUID
import kotlin.math.max
import kotlin.random.Random

/**
 * Watches speed (GPS) and forces (accelerometer) while driving.
 *
 * `live` uses the shared sensor hub; `demo` plays a scripted `DriveScenario` — the emulator has no real motion.
 */
class DrivingMonitor(
    private val sensors: SensorHub,
    private val scope: CoroutineScope,
    /** Real speed limits for live drives (TomTom / OpenStreetMap); null in tests. */
    val speedLimits: SpeedLimitService? = null,
) {
    sealed interface Mode {
        data object Idle : Mode
        data object Live : Mode
        data class Demo(val scenario: DriveScenario) : Mode
    }

    var mode by mutableStateOf<Mode>(Mode.Idle)
        private set
    var snapshot by mutableStateOf(DrivingSnapshot())
        private set
    /** Recent g-force readings for the live sparkline. */
    var gHistory by mutableStateOf(List(40) { 0.0 })
        private set

    private val sensorOwner = UUID.randomUUID()
    private var sensorObserver: UUID? = null
    private var demoTask: Job? = null
    private var lastSpeed: Pair<Double, Double>? = null
    /** Hard braking from the phone's motion (GPS alone, once a second, missed real hard stops). */
    private var brakeDetector = LongitudinalEventDetector()
    private var motionBrakes = false
    private val recentSpeeds = ArrayDeque<Pair<Double, Double>>()
    /** Strongest reading since the screen was last updated (motion arrives 100 times a second). */
    private var pendingG = 0.0
    private var lastGUpdate = Double.NEGATIVE_INFINITY
    private var movingSpeedSum = 0.0
    private var movingSpeedCount = 0
    private var startedAt: Double? = null

    val isActive: Boolean get() = mode != Mode.Idle
    val scenario: DriveScenario? get() = (mode as? Mode.Demo)?.scenario
    val hasAccelerometer: Boolean get() = sensors.hasMotionHardware
    val sensorHealth: SensorHealth get() = sensors.health

    // Control

    fun startLive(background: Boolean) {
        stop()
        reset(RoadEnvironment.city, null)
        speedLimits?.startDrive()
        mode = Mode.Live
        sensorObserver = sensors.addObserver { reading ->
            when (reading) {
                is SensorReading.Motion -> {
                    ingestG(reading.sample.accelerationG.magnitude, reading.sample.uptime)
                    detectBraking(reading.sample)
                }
                is SensorReading.Location -> {
                    applySpeedLimit(reading.sample)
                    displaySpeedMPS(reading.sample, SystemClock.elapsedRealtimeNanos() / 1e9)?.let { ingestSpeed(it * 2.23694, reading.sample.date) }
                }
            }
        }
        sensors.acquire(sensorOwner, background)
    }

    fun startDemo(scenario: DriveScenario) {
        stop()
        reset(scenario.environment, scenario.speedLimit)
        mode = Mode.Demo(scenario)
        demoTask = scope.launch {
            var speed = scenario.cruiseSpeed * 0.4
            var tick = 0
            while (isActive) {
                tick++
                // Ease toward cruise speed with a little noise, with a hard brake every ~12 s.
                val brake = tick % 24 == 0
                speed += if (brake) -14.0 else (scenario.cruiseSpeed - speed) * 0.12 + Random.nextDouble(-1.2, 1.2)
                speed = max(0.0, speed)
                ingestSpeed(speed, nowSeconds())
                ingestG(if (brake) Random.nextDouble(0.42, 0.55) else Random.nextDouble(0.02, 0.12))
                delay(500)
            }
        }
    }

    fun stop() {
        demoTask?.cancel()
        demoTask = null
        if (mode == Mode.Live) {
            sensorObserver?.let { sensors.removeObserver(it) }
            sensorObserver = null
            sensors.release(sensorOwner)
        }
        mode = Mode.Idle
    }

    // Ingest

    /** The real limit for the road the car is on (refreshed by the service as the car moves). */
    private fun applySpeedLimit(fix: LocationSample) {
        val speedLimits = speedLimits ?: return
        speedLimits.observe(fix)
        val reading = speedLimits.current ?: return
        snapshot = snapshot.copy(
            speedLimitMPH = reading.mph,
            speedLimitIsPosted = reading.isPosted,
            roadName = reading.roadName,
            roadSegment = reading.resolvedSegment,
            roadFeatures = reading.features,
            environment = when (reading.environment) {
                RoadKind.highway -> RoadEnvironment.highway
                RoadKind.rural -> RoadEnvironment.forest
                RoadKind.city -> RoadEnvironment.city
            })
    }

    private fun reset(environment: RoadEnvironment, limit: Double?) {
        snapshot = DrivingSnapshot(speedLimitMPH = limit, environment = environment)
        gHistory = List(gHistory.size) { 0.0 }
        movingSpeedSum = 0.0
        movingSpeedCount = 0
        lastSpeed = null
        pendingG = 0.0
        lastGUpdate = Double.NEGATIVE_INFINITY
        brakeDetector = LongitudinalEventDetector()
        motionBrakes = false
        recentSpeeds.clear()
        startedAt = nowSeconds()
    }

    private fun ingestSpeed(speedMPH: Double, date: Double) {
        var brakes = snapshot.hardBrakes
        var accelerations = snapshot.hardAccelerations
        lastSpeed?.let { (mph, at) ->
            val dt = date - at
            if (dt > 0) {
                val mphPerSecond = (speedMPH - mph) / dt
                // GPS-only fallback when the phone has no motion data (≈ 0.3 g).
                if (mphPerSecond < -6.5 && !motionBrakes) brakes++
                if (mphPerSecond > 6.5) accelerations++
            }
        }
        lastSpeed = speedMPH to date
        recentSpeeds.addLast(speedMPH to date)
        while (recentSpeeds.isNotEmpty() && date - recentSpeeds.first().second > 4) recentSpeeds.removeFirst()
        if (speedMPH > 3) {
            movingSpeedSum += speedMPH
            movingSpeedCount++
        }
        snapshot = snapshot.copy(
            speedMPH = speedMPH,
            maxSpeedMPH = max(snapshot.maxSpeedMPH, speedMPH),
            averageSpeedMPH = if (movingSpeedCount == 0) 0.0 else movingSpeedSum / movingSpeedCount,
            elapsed = startedAt?.let { nowSeconds() - it } ?: 0.0,
            hardBrakes = brakes,
            hardAccelerations = accelerations)
    }

    /** A hard longitudinal event from motion counts as a brake unless GPS says the car sped up. */
    private fun detectBraking(sample: MotionSample) {
        motionBrakes = true
        brakeDetector.add(sample) ?: return
        val first = recentSpeeds.firstOrNull()
        val last = recentSpeeds.lastOrNull()
        if (first != null && last != null && last.first > first.first + 2) {
            snapshot = snapshot.copy(hardAccelerations = snapshot.hardAccelerations + 1)
        } else if ((last?.first ?: 10.0) > 3) {
            snapshot = snapshot.copy(hardBrakes = snapshot.hardBrakes + 1)
        }
    }

    private fun ingestG(g: Double, uptime: Double = SystemClock.elapsedRealtimeNanos() / 1e9) {
        pendingG = max(pendingG, g)
        if (g > snapshot.peakG) snapshot = snapshot.copy(peakG = g)
        if (uptime - lastGUpdate < G_UPDATE_INTERVAL) return
        lastGUpdate = uptime
        snapshot = snapshot.copy(currentG = pendingG)
        gHistory = gHistory.drop(1) + pendingG
        pendingG = 0.0
    }

    companion object {
        /** How often g-force reaches the screen: 10 times a second is smooth; 100 would redraw every screen 100 times a second. */
        const val G_UPDATE_INTERVAL = 0.1

        /**
         * Speed for the speedometer and coaching. Crash evidence keeps the strict rule (`hasReliableSpeed`);
         * the dashboard also accepts a fresh speed whose accuracy Android couldn't estimate (speedAccuracy -1, as
         * on the emulator) when the position itself is precise.
         */
        fun displaySpeedMPS(fix: LocationSample, now: Double): Double? {
            if (fix.hasReliableSpeed(now)) return fix.speedMPS
            if (!fix.isValid || fix.speedMPS < 0 || fix.speedAccuracy >= 0 || fix.horizontalAccuracy < 0 ||
                fix.horizontalAccuracy > 20 || fix.uptime > now || now - fix.uptime > 2) return null
            return fix.speedMPS
        }
    }
}
