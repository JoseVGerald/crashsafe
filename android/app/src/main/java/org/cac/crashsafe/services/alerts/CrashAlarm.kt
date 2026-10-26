package org.cac.crashsafe.services.alerts

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.cac.crashsafe.R
import org.cac.crashsafe.features.checkin.CrashResponseCenter
import org.cac.crashsafe.services.assistant.PulseVoice
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** The voice and siren side of the crash check-in. */
interface CrashAlarm {
    /** Speaks to the driver (on the alarm stream, so it plays even with media muted). */
    fun say(text: String)
    /** A loud two-tone siren on a loop, to get the attention of anyone nearby. */
    fun startSiren()
    fun stopSiren()
    val isSirenOn: Boolean
    /** Stops speech and siren. */
    fun stopAll()
}

/**
 * The crash check-in's fixed lines, pre-recorded in a natural neural voice (Kokoro-82M, Apache 2.0,
 * rendered by Tools/Voice/render_prompts.py). They play offline and with the screen locked, and sound human
 * even when no high-quality voice is installed; anything else Pulse says uses `PulseVoice`.
 */
object PulseVoiceClips {
    val lines: Map<String, Int> = mapOf(
        CrashResponseCenter.promptText(30) to R.raw.checkin_tap_ok,
        CrashResponseCenter.promptText(10) to R.raw.checkin_10s,
        CrashResponseCenter.promptText(5) to R.raw.checkin_5s,
        CrashResponseCenter.okLine to R.raw.checkin_glad,
        CrashResponseCenter.helpLine to R.raw.checkin_help,
    )
}

/**
 * Pre-recorded clips (or the text-to-speech voice) for the "Are you okay?" prompts and a generated tone for the
 * siren, on the alarm audio stream (plays with media muted; the drive's foreground service keeps it going).
 */
class SpeakerCrashAlarm(private val context: Context, private val voice: PulseVoice, private val scope: CoroutineScope) : CrashAlarm {
    private var clipPlayer: MediaPlayer? = null
    private var track: AudioTrack? = null
    private var speech: Job? = null
    override var isSirenOn = false
        private set

    private val alarmAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    override fun say(text: String) {
        voice.stop()
        speech?.cancel()
        releaseClip()
        val clip = PulseVoiceClips.lines[text]
        if (clip != null) {
            runCatching {
                val player = MediaPlayer()
                player.setAudioAttributes(alarmAttributes)
                player.setDataSource(context, Uri.parse("android.resource://${context.packageName}/$clip"))
                player.setOnCompletionListener { it.release(); if (clipPlayer === it) clipPlayer = null }
                player.prepare()
                player.setVolume(1f, 1f)
                player.start()
                clipPlayer = player
            }
        } else {
            speech = scope.launch { voice.say(text, rate = 0.96f, usage = AudioAttributes.USAGE_ALARM) }
        }
        vibrate()
    }

    override fun startSiren() {
        if (isSirenOn) return
        val buffer = sirenBuffer(RATE)
        val created = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(buffer.size * 2)
                .build()
        }.getOrNull() ?: return
        created.write(buffer, 0, buffer.size)
        created.setLoopPoints(0, buffer.size, -1)
        created.setVolume(1f)
        created.play()
        track = created
        isSirenOn = true
        // Turn the alarm stream up so a bystander can hear it.
        context.getSystemService(AudioManager::class.java)?.let { audio ->
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, max, 0) }
        }
    }

    override fun stopSiren() {
        runCatching { track?.stop() }
        track?.release()
        track = null
        isSirenOn = false
    }

    override fun stopAll() {
        voice.stop()
        speech?.cancel()
        releaseClip()
        stopSiren()
    }

    private fun releaseClip() {
        runCatching { clipPlayer?.stop() }
        clipPlayer?.release()
        clipPlayer = null
    }

    private fun vibrate() {
        val vibrator = context.getSystemService(Vibrator::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 120, 80, 120), -1))
    }

    companion object {
        const val RATE = 44_100

        /** One 1.6 s cycle sweeping 650 → 1,300 Hz and back (a "wail"), slightly clipped for loudness. */
        fun sirenBuffer(rate: Int): ShortArray {
            val frames = (rate * 1.6).toInt()
            val samples = ShortArray(frames)
            var phase = 0.0
            for (i in 0 until frames) {
                val t = i.toDouble() / rate
                val sweep = 0.5 - 0.5 * cos(2 * PI * t / 1.6) // 0 → 1 → 0
                val frequency = 650 + 650 * sweep
                phase += 2 * PI * frequency / rate
                val tone = sin(phase) + 0.3 * sin(2 * phase)
                samples[i] = ((tone * 0.9).coerceIn(-0.95, 0.95) * Short.MAX_VALUE).toInt().toShort()
            }
            return samples
        }
    }
}

/** For tests and previews: says nothing, no siren. */
class SilentCrashAlarm : CrashAlarm {
    val spoken = mutableListOf<String>()
    override var isSirenOn = false
        private set

    override fun say(text: String) {
        spoken.add(text)
    }

    override fun startSiren() {
        isSirenOn = true
    }

    override fun stopSiren() {
        isSirenOn = false
    }

    override fun stopAll() {
        isSirenOn = false
    }
}

/**
 * Starts the 911 call. Android shows the dialer with 911 filled in, so the driver (or a bystander) confirms the
 * call with one tap; apps aren't allowed to call emergency numbers silently.
 */
interface EmergencyDialer {
    fun call911()
}

class SystemEmergencyDialer(private val context: Context) : EmergencyDialer {
    override fun call911() {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:911")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}

class NoEmergencyDialer : EmergencyDialer {
    var calls = 0
        private set

    override fun call911() {
        calls++
    }
}
