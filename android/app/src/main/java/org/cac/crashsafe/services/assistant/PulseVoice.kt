package org.cac.crashsafe.services.assistant

import android.content.Context
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Pulse's offline speaking voice: the most natural English voice installed in the phone's text-to-speech engine.
 * Google's engine ships high-quality voices for free; more can be downloaded in Settings → Accessibility →
 * Text-to-speech. Apps can use any installed voice; they can't download one themselves.
 */
class PulseVoice(context: Context, private val prefs: SharedPreferences) {
    /** One installed voice, as plain values. */
    data class Option(
        val id: String,
        val name: String,
        val language: String,
        /** Android's 100…500 quality scale. */
        val quality: Int,
        val needsNetwork: Boolean,
        /** Quality, then US English, then other English accents, then offline voices. */
        val rank: Int,
    ) {
        val qualityLabel: String get() = if (quality >= Voice.QUALITY_VERY_HIGH) "Premium" else if (quality >= Voice.QUALITY_HIGH) "Enhanced" else "Standard"
        val isNatural: Boolean get() = quality >= Voice.QUALITY_HIGH
    }

    var options by mutableStateOf<List<Option>>(emptyList())
        private set
    var isReady by mutableStateOf(false)
        private set

    private val waiting = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val ready = CompletableDeferred<Boolean>()

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        val ok = status == TextToSpeech.SUCCESS
        if (ok) reload()
        isReady = ok
        ready.complete(ok)
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                utteranceId?.let { waiting.remove(it)?.complete(Unit) }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                utteranceId?.let { waiting.remove(it)?.complete(Unit) }
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                utteranceId?.let { waiting.remove(it)?.complete(Unit) }
            }
        })
    }

    /** Re-reads the installed voices (at launch, and back from Settings, where voices download). */
    fun reload() {
        val voices = runCatching { tts.voices }.getOrNull() ?: emptySet()
        options = voices.filter { it.locale.language == "en" && !it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }
            .map { voice ->
                val accent = if (voice.locale.country == "US") 20 else 10
                val offline = if (voice.isNetworkConnectionRequired) 0 else 5
                Option(voice.name, prettyName(voice), voice.locale.toLanguageTag(), voice.quality, voice.isNetworkConnectionRequired,
                    voice.quality + accent + offline)
            }
            .sortedByDescending { it.rank }
    }

    /** The voice Pulse speaks with: the one picked in Profile → Testing, else the best installed. */
    val preferredID: String? get() = prefs.getString(KEY, null)?.takeIf { id -> options.any { it.id == id } } ?: options.firstOrNull()?.id

    fun choose(id: String?) {
        prefs.edit().apply { if (id == null) remove(KEY) else putString(KEY, id) }.apply()
    }

    /** True when a high-quality voice is installed (worth telling the user about if not). */
    val hasNaturalVoice: Boolean get() = options.any { it.isNatural }

    /** Says `text` and returns when it's done (or stopped). */
    suspend fun say(text: String, rate: Float = 1.0f, voiceID: String? = preferredID, usage: Int = AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE) {
        if (!ready.await()) return
        voiceID?.let { id -> tts.voices?.firstOrNull { it.name == id } }?.let { tts.voice = it } ?: run { tts.language = Locale.US }
        tts.setSpeechRate(rate)
        tts.setAudioAttributes(AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        val id = UUID.randomUUID().toString()
        val done = CompletableDeferred<Unit>()
        waiting[id] = done
        val params = Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1f) }
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, params, id) != TextToSpeech.SUCCESS) {
            waiting.remove(id)
            return
        }
        // Long text at the slowest rate is still well under this.
        withTimeoutOrNull(120_000) { done.await() }
    }

    fun stop() {
        runCatching { tts.stop() }
        waiting.values.forEach { it.complete(Unit) }
        waiting.clear()
    }

    val isSpeaking: Boolean get() = runCatching { tts.isSpeaking }.getOrDefault(false)

    private fun prettyName(voice: Voice): String {
        // Google voice names look like "en-us-x-tpd-local"; show the accent and the variant.
        val country = voice.locale.displayCountry.ifEmpty { voice.locale.country }
        val variant = voice.name.split("-").getOrNull(3)?.uppercase() ?: voice.name
        return "$country $variant" + if (voice.isNetworkConnectionRequired) " (online)" else ""
    }

    companion object {
        const val KEY = "pulse.voiceIdentifier"
    }
}
