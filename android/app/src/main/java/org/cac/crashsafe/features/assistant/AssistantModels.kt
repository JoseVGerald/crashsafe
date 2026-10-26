package org.cac.crashsafe.features.assistant

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.pulse.AssistantActivity
import org.cac.crashsafe.core.pulse.AssistantContext
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.core.pulse.AssistantScenario
import org.cac.crashsafe.core.pulse.AssistantService
import org.cac.crashsafe.core.pulse.spokenPart
import org.cac.crashsafe.core.util.newID
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.services.assistant.PulseSpeaker
import org.cac.crashsafe.services.assistant.VoiceInputFailure
import org.cac.crashsafe.services.assistant.VoiceInputService

/** Everything Pulse may use, built from the on-device profile and live services. */
fun makeAssistantContext(user: AuthUser, profile: Profile?, activeTrip: Trip?, isOnline: Boolean,
                         scenario: AssistantScenario = AssistantScenario.General, incident: AssistantIncident? = null,
                         activity: AssistantActivity? = null): AssistantContext =
    AssistantContext(
        userName = user.name,
        isOnline = isOnline,
        scenario = scenario,
        carDescription = profile?.primaryVehicle?.displayName ?: "",
        insurer = profile?.insurer ?: "",
        medicalNotes = profile?.medicalNotes ?: "",
        familyContactNames = profile?.sortedContacts?.map { it.name } ?: emptyList(),
        currentTrip = activeTrip?.routeLabel,
        responseStyle = if (profile?.coachingStyle == CoachingStyle.emotional) "supportive" else "practical",
        jurisdiction = "UNKNOWN",
        assistanceStage = if (scenario == AssistantScenario.General) "followup" else "active",
        incident = incident,
        activity = activity)

/** The text chat with Pulse. */
class AssistantViewModel(
    private val service: AssistantService,
    private val voice: VoiceInputService,
    private val scope: CoroutineScope,
    /** Rebuilt on every request so replies use the latest profile and connectivity. */
    var contextProvider: () -> AssistantContext,
) {
    var messages by mutableStateOf<List<ChatMessage>>(emptyList())
        private set
    var scenario by mutableStateOf<AssistantScenario>(AssistantScenario.General)
        private set
    var draft by mutableStateOf("")
    var isThinking by mutableStateOf(false)
        private set
    var isListening by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    /** Says replies out loud after a spoken question (hands-free after a crash). */
    var speaker: PulseSpeaker? = null
    private var lastInputWasVoice = false
    /** Lets Pulse's agent on the backend keep this conversation's earlier turns. */
    private var conversationID = newID()

    val isAfterCrash: Boolean get() = scenario is AssistantScenario.AfterCrash
    val canSend: Boolean get() = draft.isNotBlank() && !isThinking

    /** Starts a fresh conversation for a new scenario; a general request keeps any chat in progress. */
    fun begin(scenario: AssistantScenario) {
        if (scenario == AssistantScenario.General && messages.isNotEmpty()) return
        this.scenario = scenario
        conversationID = newID()
        val context = contextProvider().copy(scenario = scenario)
        messages = listOf(ChatMessage(ChatMessage.Role.assistant, service.greeting(context)))
        errorMessage = null
    }

    fun send(text: String? = null) {
        val body = (text ?: draft).trim()
        if (body.isEmpty() || isThinking) return
        if (text == null) draft = ""
        messages = messages + ChatMessage(ChatMessage.Role.user, body)
        isThinking = true
        errorMessage = null
        val spoken = lastInputWasVoice
        lastInputWasVoice = false
        scope.launch {
            try {
                val context = contextProvider().copy(scenario = scenario, conversationID = conversationID)
                val reply = service.reply(messages, context)
                messages = messages + ChatMessage(ChatMessage.Role.assistant, reply)
                if (spoken) speaker?.speak(spokenPart(reply))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = "The assistant couldn't answer. Your saved guides still work offline."
            } finally {
                isThinking = false
            }
        }
    }

    fun listen() {
        if (isListening || isThinking) return
        isListening = true
        scope.launch {
            try {
                speaker?.stop()
                val transcript = voice.listen()
                isListening = false
                lastInputWasVoice = true
                send(transcript)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                isListening = false
                errorMessage = "Couldn't hear that. Try again or type your question."
            }
        }
    }
}

/**
 * A phone call with Pulse: tap once and just talk. Pulse listens until you pause, answers out loud as Corey,
 * then listens again on its own, back and forth until you hang up. (Pulse doesn't listen while it is talking;
 * tap the orb to cut it off and speak.) The mic opens only for your turn.
 */
class PulseCallViewModel(
    private val assistant: AssistantService,
    val voice: VoiceInputService,
    private val speaker: PulseSpeaker?,
    private val scope: CoroutineScope,
    var contextProvider: () -> AssistantContext,
) {
    sealed interface Phase {
        data object Idle : Phase
        data object Connecting : Phase
        data object Listening : Phase
        data class Thinking(val heard: String) : Phase
        data class Speaking(val heard: String, val reply: String) : Phase
        data class Failed(val message: String) : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Idle)
        private set
    /** What Pulse said last, kept on screen while it listens for the next turn. */
    var lastReply by mutableStateOf("")
        private set
    var startedAt by mutableStateOf<Double?>(null)
        private set
    /** Muted: the mic stays off and Pulse hears nothing until you unmute. */
    var isMuted by mutableStateOf(false)
        private set
    /** Buttons Pulse asked for with its reply; they act only when tapped. */
    var offersEmergencyCall by mutableStateOf(false)
        private set
    var offersTowSearch by mutableStateOf(false)
        private set

    private var call: Job? = null
    /** This call's turns, so "what about the other driver?" makes sense to Pulse. */
    var history: List<ChatMessage> = emptyList()
        private set
    private var conversationID = newID()

    val inCall: Boolean get() = phase != Phase.Idle && phase !is Phase.Failed

    /** Fetches the greeting's audio ahead of time, so a call starts talking at once. */
    fun prepare() {
        speaker?.prefetch(GREETING)
    }

    fun startCall(initialTopic: String? = null) {
        if (inCall) return
        history = emptyList()
        lastReply = ""
        isMuted = false
        offersEmergencyCall = false
        offersTowSearch = false
        conversationID = newID()
        startedAt = nowSeconds()
        phase = Phase.Connecting
        call = scope.launch { converse(initialTopic) }
    }

    fun endCall() {
        call?.cancel()
        call = null
        voice.cancel()
        speaker?.stop()
        startedAt = null
        isMuted = false
        phase = Phase.Idle
    }

    fun toggleMute() {
        isMuted = !isMuted
        if (isMuted) voice.cancel() // Close the mic now, mid-sentence if need be.
    }

    /** Cuts Pulse off mid-sentence; the call goes straight back to listening. */
    fun interrupt() {
        if (phase is Phase.Speaking) speaker?.stop()
    }

    private suspend fun CoroutineScope.converse(initialTopic: String?) {
        val greeting = if (!initialTopic.isNullOrEmpty()) "I'm here. Let's talk about $initialTopic. What's happening?" else GREETING
        say(greeting, heard = "")
        while (isActive) {
            phase = Phase.Listening
            if (isMuted) {
                delay(100)
                continue
            }
            val heard = try {
                voice.listen() // Ends when you pause.
            } catch (e: CancellationException) {
                return
            } catch (e: VoiceInputFailure) {
                if (e.kind == VoiceInputFailure.Kind.heardNothing) continue // Silence (or muted): keep the line open, like a call.
                if (isActive) fail(e.message ?: "Couldn't listen.")
                return
            } catch (e: Exception) {
                if (isActive) fail(e.message ?: "Couldn't listen.")
                return
            }
            if (!isActive) return
            if (isMuted) continue
            history = history + ChatMessage(ChatMessage.Role.user, heard)
            phase = Phase.Thinking(heard)
            val context = contextProvider().copy(conversationID = conversationID)
            val reply = try {
                assistant.reply(history.takeLast(40), context)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "Sorry, I didn't get an answer just then. Could you say that again?"
            }
            if (!isActive) return
            offersEmergencyCall = offersEmergencyCall || "emergency_call_prompt" in assistant.requestedActions
            offersTowSearch = offersTowSearch || "find_tow" in assistant.requestedActions
            say(reply, heard)
        }
    }

    private suspend fun say(reply: String, heard: String) {
        history = history + ChatMessage(ChatMessage.Role.assistant, reply)
        lastReply = spokenPart(reply)
        phase = Phase.Speaking(heard, lastReply)
        speaker?.say(lastReply)
    }

    private fun fail(message: String) {
        voice.cancel()
        speaker?.stop()
        startedAt = null
        isMuted = false
        phase = Phase.Failed(message)
    }

    companion object {
        const val GREETING = "I'm here. What's going on?"
    }
}
