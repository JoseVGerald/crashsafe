package org.cac.crashsafe.services.assistant

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import org.cac.crashsafe.app.PermissionCenter

/** Why listening didn't produce words. `heardNothing` keeps a call going; the others end it. */
class VoiceInputFailure(val kind: Kind) : Exception(kind.message) {
    enum class Kind(val message: String) {
        notAllowed("The microphone is off for CrashSafe in Settings."),
        unavailable("Speech recognition isn't available right now."),
        heardNothing("I didn't catch that."),
    }
}

/** Speech-to-text for Pulse's mic buttons (`SpeechVoiceInput` in the app). */
interface VoiceInputService {
    /** Listens until the speaker pauses and returns the transcript. */
    suspend fun listen(): String
    /** Tap-to-talk: start listening… */
    suspend fun start()
    /** …and stop, returning what was said. */
    suspend fun finish(): String
    fun cancel()
    /** Words heard so far (live, while listening). */
    val partial: String
}

/** Tests and previews only: pretends to listen, then returns a canned phrase. */
class MockVoiceInputService : VoiceInputService {
    override val partial: String = ""
    private val phrases = listOf(
        "I think I'm okay but my car won't start.",
        "What should I tell my insurance?",
        "I'm kind of shaking right now.",
        "What photos should I take?",
    )
    private var index = 0

    override suspend fun start() {}
    override suspend fun finish(): String = listen()
    override fun cancel() {}

    override suspend fun listen(): String {
        delay(1500)
        return phrases[index].also { index = (index + 1) % phrases.size }
    }
}

/**
 * The microphone, transcribed by Android's speech recognizer: on the phone when it can (private, works
 * offline), otherwise Google's service. What it hears goes to Pulse; nothing is recorded or kept.
 */
class SpeechVoiceInput(private val context: Context, private val permissions: PermissionCenter) : VoiceInputService {
    override var partial by mutableStateOf("")
        private set
    var isRecording by mutableStateOf(false)
        private set

    private var recognizer: SpeechRecognizer? = null
    private var finalText: String? = null
    private var ended = false
    private var lastChange = 0.0

    private fun now() = SystemClock.elapsedRealtime() / 1000.0

    /** One turn: listens until the speaker pauses (about a conversational beat), up to 15 s. */
    override suspend fun listen(): String {
        start()
        val began = now()
        while (isRecording && !ended) {
            delay(100)
            val quiet = now() - lastChange
            if (partial.isNotEmpty() && quiet > 1.0) break
            if (partial.isEmpty() && now() - began > 7) break
            if (now() - began > 15) break
        }
        return finish()
    }

    override suspend fun start() {
        cancel()
        if (!permissions.microphoneGranted && !permissions.requestMicrophone()) throw VoiceInputFailure(VoiceInputFailure.Kind.notAllowed)
        if (!SpeechRecognizer.isRecognitionAvailable(context)) throw VoiceInputFailure(VoiceInputFailure.Kind.unavailable)
        val created = if (Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        recognizer = created
        partial = ""
        finalText = null
        ended = false
        lastChange = now()
        created.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (!text.isNullOrBlank() && text != partial) {
                    partial = text
                    lastChange = now()
                }
            }

            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                finalText = if (text.isNullOrBlank()) partial else text
                ended = true
            }

            override fun onError(error: Int) {
                Log.i(TAG, "recognizer error $error")
                ended = true
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1000L)
        }
        created.startListening(intent)
        isRecording = true
    }

    /** Stops listening and returns what was said. */
    override suspend fun finish(): String {
        val active = recognizer ?: throw VoiceInputFailure(VoiceInputFailure.Kind.heardNothing)
        if (!ended) active.stopListening()
        // The final transcript follows stopListening shortly; the live one is already complete after a pause.
        repeat(12) { if (finalText == null && !ended) delay(50) }
        val text = (finalText ?: partial).trim()
        release()
        Log.i(TAG, "heard ${text.split(" ").count { it.isNotEmpty() }} words")
        if (text.isEmpty()) throw VoiceInputFailure(VoiceInputFailure.Kind.heardNothing)
        return text
    }

    override fun cancel() {
        recognizer?.cancel()
        release()
    }

    private fun release() {
        recognizer?.destroy()
        recognizer = null
        isRecording = false
    }

    private companion object {
        const val TAG = "CrashSafe.voice"
    }
}
