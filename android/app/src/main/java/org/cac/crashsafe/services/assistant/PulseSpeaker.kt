package org.cac.crashsafe.services.assistant

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.pulse.PulseSentenceFilter
import org.cac.crashsafe.services.keys.PulseBackend
import org.cac.crashsafe.services.keys.PulseKeys
import org.cac.crashsafe.services.keys.appending
import org.cac.crashsafe.services.net.Http
import java.io.File
import kotlin.coroutines.resume

/**
 * Speaks for Pulse in its voice, Cartesia's "Corey": straight from Cartesia when this build has a Cartesia key
 * (the backup key takes over if the main one is refused), otherwise through the backend (`POST /v1/tts`).
 * When neither answers in time (offline, or nothing configured), the best installed text-to-speech voice says
 * it instead, so nothing Pulse needs to say is lost. To start sooner, the first sentence is voiced on its own
 * and plays while the rest is still being fetched.
 */
class PulseSpeaker(
    private val context: Context,
    private val voice: PulseVoice,
    private val scope: CoroutineScope,
    private val endpoint: HttpUrl? = PulseBackend.endpoint(),
    cartesiaKey: String? = PulseKeys.cartesia(),
    backupKey: String? = PulseKeys.cartesiaBackup(),
    private val isOnline: () -> Boolean = { true },
    private val timeoutSeconds: Double = 4.0,
) {
    private val cartesiaKeys = listOfNotNull(cartesiaKey, backupKey)
    /** The key that answered last, tried first next time. */
    private var workingKey = 0
    private var player: MediaPlayer? = null
    private var task: Job? = null
    /** Recent lines, so repeated coaching is instant and free. */
    private val cache = LinkedHashMap<String, ByteArray>()
    private val audio = context.getSystemService(AudioManager::class.java)
    private var focus: AudioFocusRequest? = null

    val hasCorey: Boolean get() = cartesiaKeys.isNotEmpty() || endpoint != null

    val isSpeaking: Boolean get() = (player?.isPlaying ?: false) || voice.isSpeaking

    /** Says `text`, interrupting anything Pulse was saying. */
    fun speak(text: String, rate: Float = 1.0f) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        stop()
        task = scope.launch {
            requestFocus()
            try {
                play(trimmed, rate)
            } finally {
                abandonFocus()
            }
        }
    }

    /** Says `text` and returns once Pulse has finished saying it (or was stopped): turn-taking in a call. */
    suspend fun say(text: String, rate: Float = 1.0f) {
        speak(text, rate)
        task?.join()
    }

    /** Fetches a line ahead of time (e.g. the call greeting), so saying it later is instant. */
    fun prefetch(text: String) {
        scope.launch { corey(text) }
    }

    private suspend fun play(text: String, rate: Float) = coroutineScope {
        // The first sentence alone comes back sooner; the rest is fetched while it plays.
        val sentences = PulseSentenceFilter.sentences(text)
        val first = if (sentences.size > 1) sentences[0] else text
        val rest = if (sentences.size > 1) sentences.drop(1).joinToString(" ") else ""
        val later: Deferred<ByteArray?>? = if (rest.isEmpty()) null else async { corey(rest) }
        val clip = corey(first)
        if (clip != null && isActive) {
            playClip(clip)
            val restClip = later?.await()
            when {
                restClip != null -> playClip(restClip)
                rest.isNotEmpty() -> sayWithSystemVoice(rest, rate)
            }
            return@coroutineScope
        }
        later?.cancel()
        sayWithSystemVoice(text, rate)
    }

    private suspend fun playClip(clip: ByteArray) {
        val file = withContext(Dispatchers.IO) {
            File.createTempFile("pulse", ".mp3", context.cacheDir).apply { writeBytes(clip) }
        }
        try {
            suspendCancellableCoroutine { continuation ->
                val created = MediaPlayer()
                player = created
                created.setAudioAttributes(attributes)
                created.setOnPreparedListener { it.start() }
                created.setOnCompletionListener { if (continuation.isActive) continuation.resume(Unit) }
                created.setOnErrorListener { _, _, _ -> if (continuation.isActive) continuation.resume(Unit); true }
                runCatching {
                    created.setDataSource(file.absolutePath)
                    created.prepareAsync()
                }.onFailure { if (continuation.isActive) continuation.resume(Unit) }
                continuation.invokeOnCancellation { runCatching { created.stop() } }
            }
            Log.i(TAG, "Pulse spoke as Corey (${clip.size} bytes)")
        } finally {
            player?.release()
            player = null
            file.delete()
        }
    }

    private suspend fun sayWithSystemVoice(text: String, rate: Float) {
        Log.i(TAG, "Pulse spoke with the system voice (Corey unavailable)")
        voice.say(text, rate)
    }

    fun stop() {
        task?.cancel()
        task = null
        runCatching { player?.stop() }
        player?.release()
        player = null
        voice.stop()
    }

    suspend fun corey(text: String): ByteArray? {
        cache[text]?.let { return it }
        if (!isOnline() || text.length > 1200) return null
        // Cartesia keys in order, starting with the one that worked last; then the backend.
        val keys = cartesiaKeys.indices.map { (workingKey + it) % cartesiaKeys.size }
        for (index in keys.ifEmpty { listOf(-1) }) {
            val request = coreyRequest(text, if (index >= 0) cartesiaKeys[index] else null) ?: continue
            val result = try {
                Http.send(request, Http.client(timeoutSeconds + 1))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                continue
            }
            if (result.status != 200 || result.contentType?.startsWith("audio/") != true || result.body.size <= 1000) {
                Log.i(TAG, "Corey request refused (${result.status}); trying the next key")
                continue
            }
            if (index >= 0) workingKey = index
            cache[text] = result.body
            if (cache.size > 32) cache.remove(cache.keys.first())
            return result.body
        }
        return null
    }

    /** Cartesia itself when this build has a key, else the backend. */
    private fun coreyRequest(text: String, key: String?): Request? {
        if (key != null) {
            val body = JsonObject(mapOf(
                "model_id" to JsonPrimitive("sonic-3"), "transcript" to JsonPrimitive(text), "language" to JsonPrimitive("en"),
                "voice" to JsonObject(mapOf("mode" to JsonPrimitive("id"), "id" to JsonPrimitive(COREY))),
                "output_format" to JsonObject(mapOf("container" to JsonPrimitive("mp3"), "sample_rate" to JsonPrimitive(44100),
                    "bit_rate" to JsonPrimitive(128000))),
            ))
            return Request.Builder().url("https://api.cartesia.ai/tts/bytes")
                .header("X-API-Key", key)
                .header("Cartesia-Version", "2025-04-16")
                .post(Http.jsonBody(body.toString()))
                .build()
        }
        val endpoint = endpoint ?: return null
        val body = JsonObject(mapOf("text" to JsonPrimitive(text)))
        return PulseBackend.authorize(Request.Builder().url(endpoint.appending("v1/tts"))).post(Http.jsonBody(body.toString())).build()
    }

    private fun requestFocus() {
        val manager = audio ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).build()
            focus = request
            manager.requestAudioFocus(request)
        }
    }

    private fun abandonFocus() {
        val manager = audio ?: return
        focus?.let { if (Build.VERSION.SDK_INT >= 26) manager.abandonAudioFocusRequest(it) }
        focus = null
    }

    private val attributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    companion object {
        private const val TAG = "CrashSafe.voice"
        /** Cartesia "Corey - Supportive Buddy". */
        const val COREY = "630ed21c-2c5c-41cf-9d82-10a7fd668370"
    }
}
