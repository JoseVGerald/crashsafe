package org.cac.crashsafe.features.sensorlab

import android.content.Context
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.cac.crashsafe.core.crash.CrashAssessment
import org.cac.crashsafe.core.crash.CrashPipeline
import org.cac.crashsafe.core.crash.PhoneMount
import org.cac.crashsafe.core.crash.RealCrashPulse
import org.cac.crashsafe.core.crash.ScenarioFactory
import org.cac.crashsafe.core.crash.SeededGenerator
import org.cac.crashsafe.core.crash.SensorScenario
import org.cac.crashsafe.core.sensors.Jolt
import org.cac.crashsafe.core.sensors.JoltTracker
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorCSV
import org.cac.crashsafe.core.sensors.SensorLabMath
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorRing
import org.cac.crashsafe.services.driving.SpeedLimitService
import org.cac.crashsafe.services.sensors.ReplayMotionSource
import org.cac.crashsafe.services.sensors.SensorHub
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Live state behind the Sensor Lab: recent motion for the graphs, jolts, GPS speed, a silent copy of
 * the crash pipeline (shows what the detector would decide without starting a real check-in), and
 * 30-second recordings that can be shared and replayed.
 */
class SensorLabModel(
    private val context: Context,
    private val sensors: SensorHub,
    val replay: ReplayMotionSource?,
    private val speedLimits: SpeedLimitService? = null,
) {
    sealed interface Recording {
        data object Idle : Recording
        data class Active(val until: Double) : Recording
        data class Saved(val file: File) : Recording
    }

    var isRunning by mutableStateOf(false)
        private set
    var jolts by mutableStateOf<List<Jolt>>(emptyList())
        private set
    var lastAssessment by mutableStateOf<CrashAssessment?>(null)
        private set
    var assessmentsSeen by mutableIntStateOf(0)
        private set
    var recording by mutableStateOf<Recording>(Recording.Idle)
        private set
    var recordings by mutableStateOf<List<File>>(emptyList())
        private set
    /**
     * Off by default: replayed motion stays out of the real crash detector, so a replayed crash during
     * a watched drive can't start a check-in that alerts contacts.
     */
    var replayTriggersCheckIn by mutableStateOf(false)
    /** Bumped as readings arrive (at most 20 times a second), so the graphs redraw at that rate. */
    var frame by mutableLongStateOf(0L)
        private set
    var replayTitle by mutableStateOf<String?>(null)
        private set

    /** High-rate state, read by the screen on each frame rather than observed per sample. */
    val motion = SensorRing<MotionSample>(600)
    val fixes = SensorRing<LocationSample>(20)
    val tracker = JoltTracker()
    var peakG = 0.0
        private set
    var peakRotation = 0.0
        private set
    private var pipeline = CrashPipeline()
    private val recorded = mutableListOf<SensorReading>()
    private var observer: UUID? = null
    private val owner = UUID.randomUUID()
    private var lastFrame = 0L

    val folder: File get() = File(context.filesDir, "Recordings")

    init {
        recordings = savedRecordings()
    }

    fun start() {
        if (isRunning) return
        isRunning = true
        observer = sensors.addObserver { ingest(it) }
        sensors.acquire(owner, background = false)
    }

    fun stop() {
        if (!isRunning) return
        isRunning = false
        observer?.let { sensors.removeObserver(it) }
        observer = null
        stopReplay()
        sensors.release(owner)
        if (recording is Recording.Active) finishRecording()
    }

    fun resetPeaks() {
        peakG = 0.0
        peakRotation = 0.0
        tracker.reset()
        jolts = emptyList()
        lastAssessment = null
        assessmentsSeen = 0
        pipeline = CrashPipeline()
        frame++
    }

    private fun ingest(reading: SensorReading) {
        when (reading) {
            is SensorReading.Motion -> {
                val sample = reading.sample
                motion.append(sample)
                peakG = maxOf(peakG, sample.accelerationG.magnitude)
                peakRotation = maxOf(peakRotation, sample.rotationRate.magnitude)
                tracker.add(sample)?.let { jolt -> jolts = (listOf(jolt) + jolts).take(8) }
            }
            is SensorReading.Location -> {
                fixes.append(reading.sample)
                speedLimits?.observe(reading.sample)
            }
        }
        pipeline.ingest(reading)?.let {
            lastAssessment = it
            assessmentsSeen++
        }
        val active = recording
        if (active is Recording.Active) {
            recorded.add(reading)
            if (reading.uptime >= active.until) finishRecording()
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastFrame >= 50) {
            lastFrame = now
            frame++
        }
        replayTitle = replay?.current?.title
    }

    // Derived values

    val latest: MotionSample? get() = motion.last
    val latestFix: LocationSample? get() = fixes.last
    val tilt: SensorLabMath.Tilt? get() = latest?.let { SensorLabMath.tilt(it.gravityG) }

    /** Speeding up (+) or slowing (−) from the last two GPS fixes, g. */
    val gpsLongitudinalG: Double?
        get() {
            val f = fixes.values
            if (f.size < 2) return null
            return SensorLabMath.longitudinalG(f[f.size - 2], f[f.size - 1])
        }

    // Recording

    fun startRecording() {
        if (!isRunning || recording is Recording.Active) return
        recorded.clear()
        recording = Recording.Active((latest?.uptime ?: (SystemClock.elapsedRealtimeNanos() / 1e9)) + RECORD_SECONDS)
    }

    fun finishRecording() {
        if (recording !is Recording.Active) return
        val readings = recorded.toList()
        recorded.clear()
        val file = if (readings.size > 10) runCatching { save(readings) }.getOrNull() else null
        recording = if (file == null) Recording.Idle else Recording.Saved(file)
        recordings = savedRecordings()
    }

    fun delete(file: File) {
        file.delete()
        recordings = savedRecordings()
        if ((recording as? Recording.Saved)?.file == file) recording = Recording.Idle
    }

    /** Recordings made here, plus any CSV copied into the app's Recordings folder (`adb push`). */
    private fun savedRecordings(): List<File> =
        (folder.listFiles() ?: emptyArray()).filter { it.extension.lowercase() == "csv" }.sortedByDescending { it.name }

    private fun save(readings: List<SensorReading>): File {
        folder.mkdirs()
        val name = "pulse-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".csv"
        val file = File(folder, name)
        file.writeText(SensorCSV.encode(readings))
        return file
    }

    // Replay

    sealed interface Source {
        data class Generated(val kind: SensorScenario.Kind) : Source
        data object RealCrash : Source
        data class Bundled(val name: String) : Source
        data class Recorded(val file: File) : Source
    }

    val isReplaying: Boolean get() = replay?.isReplaying ?: false
    val suppressesCrashDetection: Boolean get() = isReplaying && !replayTriggersCheckIn

    fun play(source: Source) {
        val replay = replay ?: return
        val clip = clip(source) ?: return
        if (!isRunning) start()
        resetPeaks()
        replay.play(clip) { sensors.motionSourceChanged() }
        replayTitle = clip.title
    }

    fun stopReplay() {
        replay?.stopReplay()
        replayTitle = null
    }

    private fun clip(source: Source): ReplayMotionSource.Clip? {
        val rng = SeededGenerator(System.currentTimeMillis() / 1000)
        return when (source) {
            is Source.Generated -> {
                val scenario = ScenarioFactory().make(source.kind, rng)
                ReplayMotionSource.Clip("${source.kind.title} · ${scenario.detail}", scenario.readings)
            }
            Source.RealCrash -> {
                val scenario = ScenarioFactory().vehiclePulse(RealCrashPulse.x, RealCrashPulse.y, RealCrashPulse.z,
                    speedBeforeMPS = 56.09 / 3.6, speedAfterMPS = 0.0, deltaVMPS = 18.1, title = RealCrashPulse.title,
                    mount = PhoneMount.dash, rng = rng)
                ReplayMotionSource.Clip(RealCrashPulse.title, scenario.readings)
            }
            is Source.Bundled -> {
                val text = runCatching { context.assets.open("clips/${source.name}.csv").bufferedReader().readText() }.getOrNull() ?: return null
                val title = bundledClips.firstOrNull { it.first == source.name }?.second ?: source.name
                ReplayMotionSource.Clip(title, SensorCSV.decode(text))
            }
            is Source.Recorded -> {
                val text = runCatching { source.file.readText() }.getOrNull() ?: return null
                ReplayMotionSource.Clip(source.file.nameWithoutExtension, SensorCSV.decode(text))
            }
        }
    }

    companion object {
        const val RECORD_SECONDS = 30.0

        /** Bundled clips of real iPhone motion (MotionSense, MIT license). */
        val bundledClips = listOf(
            "motionsense-walking" to "Real walking (phone in pocket)",
            "motionsense-jogging" to "Real jogging (phone in pocket)",
        )
    }
}
