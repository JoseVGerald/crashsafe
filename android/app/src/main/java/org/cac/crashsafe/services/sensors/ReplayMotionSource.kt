package org.cac.crashsafe.services.sensors

import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.util.nowSeconds

/**
 * Wraps the real motion sensor and can play a clip in its place, on the live clock: a recording from
 * the Sensor Lab, a real crash-test pulse, or a generated event. The emulator has no real motion,
 * so this is how motion reaches the app there; on a phone it replays a crash without crashing.
 * Everything downstream (SensorHub, the crash pipeline, motion analysis) sees ordinary samples.
 */
class ReplayMotionSource(private val live: MotionSource, private val scope: CoroutineScope) : MotionSource {
    class Clip(val title: String, readings: List<SensorReading>) {
        /** Seconds from the start of the clip. */
        val samples: List<Pair<Double, MotionSample>>

        init {
            val motion = readings.mapNotNull { (it as? SensorReading.Motion)?.sample }
            val origin = motion.firstOrNull()?.uptime ?: 0.0
            samples = motion.map { (it.uptime - origin) to it }
        }

        val duration: Double get() = samples.lastOrNull()?.first ?: 0.0
    }

    private var receive: ((MotionSample?, Boolean) -> Unit)? = null
    private var interval = 0.01
    private var playback: Job? = null
    private var isRestarting = false
    var current: Clip? = null
        private set
    /** Called when a clip ends or is stopped (so the hub can notice the real sensor is back, or absent). */
    var onFinish: (() -> Unit)? = null

    override val isAvailable: Boolean get() = live.isAvailable || current != null
    val hasHardware: Boolean get() = live.isAvailable
    val isReplaying: Boolean get() = current != null

    override fun start(interval: Double, receive: (MotionSample?, Boolean) -> Unit) {
        this.interval = interval
        this.receive = receive
        if (current == null && live.isAvailable) live.start(interval, receive)
    }

    override fun stop() {
        receive = null
        live.stop()
        // The hub stops motion before starting it again; that mustn't end the clip it's starting for.
        if (isRestarting) return
        playback?.cancel()
        playback = null
        current = null
    }

    /**
     * Plays `clip` in real time. Live readings pause meanwhile and resume after.
     * @param restart asks the sensor hub to (re)start motion, needed where there's no hardware.
     */
    fun play(clip: Clip, loop: Boolean = false, restart: () -> Unit) {
        playback?.cancel()
        live.stop()
        current = clip
        isRestarting = true
        restart()
        isRestarting = false
        playback = scope.launch {
            do {
                val start = SystemClock.elapsedRealtimeNanos() / 1e9
                val origin = nowSeconds()
                var index = 0
                while (index < clip.samples.size) {
                    if (!isActive) return@launch
                    val elapsed = SystemClock.elapsedRealtimeNanos() / 1e9 - start
                    while (index < clip.samples.size && clip.samples[index].first <= elapsed) {
                        val (t, sample) = clip.samples[index]
                        receive?.invoke(sample.copy(uptime = start + t, date = origin + t), false)
                        index++
                    }
                    delay(10)
                }
            } while (loop && isActive)
            finish()
        }
    }

    fun stopReplay() {
        if (current == null) return
        playback?.cancel()
        playback = null
        finish()
    }

    private fun finish() {
        current = null
        playback = null
        val receive = receive
        if (receive != null && live.isAvailable) live.start(interval, receive)
        onFinish?.invoke()
    }
}
