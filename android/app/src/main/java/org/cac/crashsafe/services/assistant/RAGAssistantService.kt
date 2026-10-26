package org.cac.crashsafe.services.assistant

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.pulse.AssistantActivity
import org.cac.crashsafe.core.pulse.AssistantContext
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.core.pulse.AssistantService
import org.cac.crashsafe.core.pulse.LocalEvidenceAssistant
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.services.keys.PulseBackend
import org.cac.crashsafe.services.keys.appending
import org.cac.crashsafe.services.net.Http
import java.io.IOException

/**
 * Sends only the current question, tone, explicit jurisdiction/stage and minimal sensor summary.
 * Names, policy numbers, medical notes, contact names and precise location are not serialized.
 */
class RAGAssistantService(private val endpoint: HttpUrl?) : AssistantService {
    private val fallback = LocalEvidenceAssistant()
    override var requestedActions: List<String> = emptyList()
        private set

    @Serializable
    private data class ConverseBody(
        val messages: List<Turn>,
        @SerialName("conversation_id") val conversationId: String?,
        val jurisdiction: String,
        val stage: String,
        val incident: AssistantIncident?,
        val activity: AssistantActivity?,
    ) {
        @Serializable
        data class Turn(val role: String, val text: String)
    }

    @Serializable
    private data class AssistBody(
        val query: String,
        val jurisdiction: String,
        val stage: String,
        val persona: String,
        val incident: AssistantIncident?,
        val activity: AssistantActivity?,
    )

    @Serializable
    private data class Response(
        val status: String,
        val answer: String,
        val citations: List<Citation> = emptyList(),
        val actions: List<Action>? = null,
    ) {
        @Serializable
        data class Citation(val title: String, val url: String)

        @Serializable
        data class Action(val action: String, val status: String)
    }

    override fun greeting(context: AssistantContext): String = fallback.greeting(context)

    override suspend fun reply(history: List<ChatMessage>, context: AssistantContext): String {
        val query = history.lastOrNull { it.role == ChatMessage.Role.user }?.text ?: ""
        requestedActions = emptyList()
        LocalEvidenceAssistant.emergencyReply(query)?.let {
            requestedActions = listOf("emergency_call_prompt")
            return it
        }
        // Questions about the phone's own measurements are answered from those measurements.
        LocalEvidenceAssistant.motionReply(query, context)?.let { return it }
        val endpoint = endpoint
        if (!context.isOnline || endpoint == null) return fallback.reply(history, context)
        // Pulse as a companion (the team's Pulse core on the server), then the verified evidence answer.
        converse(history, context, endpoint)?.let { return it }
        return try {
            val body = AssistBody(query = query, jurisdiction = context.jurisdiction, stage = context.assistanceStage,
                persona = context.responseStyle, incident = context.incident, activity = context.activity)
            val request = PulseBackend.authorize(Request.Builder().url(endpoint.appending("v1/assist")))
                .post(Http.jsonBody(Http.json.encodeToString(AssistBody.serializer(), body))).build()
            val result = Http.send(request, Http.client(2.0), maxBytes = 100_000)
            if (!result.isOK) throw IOException("assist ${result.status}")
            val response = Http.json.decodeFromString(Response.serializer(), result.text)
            if (response.status !in listOf("answered", "emergency", "insufficient_evidence", "review_required") || response.answer.isEmpty()) {
                throw IOException("assist unparsable")
            }
            withSources(response)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            fallback.reply(history, context)
        }
    }

    /**
     * `POST /v1/converse`: the last turns go along. With a conversation id the team's Pulse agent answers and keeps
     * the conversation in its memory (30 idle minutes at most, never on disk); otherwise the server keeps nothing.
     */
    private suspend fun converse(history: List<ChatMessage>, context: AssistantContext, endpoint: HttpUrl): String? = try {
        val turns = history.takeLast(12).map { ConverseBody.Turn(if (it.role == ChatMessage.Role.user) "user" else "assistant", it.text) }
        val body = ConverseBody(messages = turns, conversationId = context.conversationID, jurisdiction = context.jurisdiction,
            stage = context.assistanceStage, incident = context.incident, activity = context.activity)
        val request = PulseBackend.authorize(Request.Builder().url(endpoint.appending("v1/converse")))
            .post(Http.jsonBody(Http.json.encodeToString(ConverseBody.serializer(), body))).build()
        val result = Http.send(request, Http.client(10.0), maxBytes = 100_000)
        if (!result.isOK) {
            null
        } else {
            val response = Http.json.decodeFromString(Response.serializer(), result.text)
            if (response.status !in listOf("answered", "emergency") || response.answer.isEmpty()) {
                null
            } else {
                requestedActions = (response.actions ?: emptyList())
                    .filter { it.status in listOf("offered", "requested", "app_action_requested") }
                    .map { it.action }
                withSources(response)
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private fun withSources(response: Response): String {
        val sources = response.citations.joinToString("\n") { "${it.title}: ${it.url}" }
        return response.answer + if (sources.isEmpty()) "" else "\n\nSources:\n$sources"
    }

    companion object {
        fun configured() = RAGAssistantService(PulseBackend.endpoint())
    }
}
