package org.cac.crashsafe.services.assistant

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import org.cac.crashsafe.core.pulse.AssistantContext
import org.cac.crashsafe.core.pulse.AssistantService
import org.cac.crashsafe.core.pulse.LocalEvidenceAssistant
import org.cac.crashsafe.core.pulse.PulseKnowledgeIndex
import org.cac.crashsafe.core.pulse.PulseSentenceFilter
import org.cac.crashsafe.core.pulse.PulseTeamAgent
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.services.keys.PulseKeys
import org.cac.crashsafe.services.net.Http
import java.io.IOException

/**
 * Pulse straight from the phone, with no server: each request is built exactly as the team's Pulse agent builds
 * it (`PulseTeamAgent`: their Core, their per-turn context and weighting, their knowledge notes, the
 * conversation), sent to a free OpenRouter model with their model settings, and every sentence passes their
 * filter. The model may ask for two tools (the Call 911 button, a tow search), which the app only offers.
 * Emergencies are answered on the phone first with no model. When OpenRouter can't answer (its free plan
 * allows 50 requests a day, or no signal), the phone's own model does when there is one (`OnDevicePulse`), and
 * after that `fallback` (the backend when configured, otherwise the on-device guides).
 */
class DirectPulseService(
    private val key: String,
    private val fallback: AssistantService,
    private val agent: PulseTeamAgent,
    private val knowledge: () -> PulseKnowledgeIndex,
    private val onDevice: suspend (List<ChatMessage>, String) -> String? = { _, _ -> OnDevicePulse.reply() },
    private val baseURL: String = "https://openrouter.ai/api/v1/chat/completions",
) : AssistantService {
    private val local = LocalEvidenceAssistant()
    override var requestedActions: List<String> = emptyList()
        private set
    /** Which model answered last (null when the fallback did); for tests and diagnostics. */
    var lastModel: String? = null
        private set
    /** Set when OpenRouter's daily free limit is used up: until then Pulse goes straight to the phone's model. */
    var cloudPausedUntil: Double? = null
        private set

    private class DailyLimitReached(val resetsAt: Double) : Exception()

    override fun greeting(context: AssistantContext): String = local.greeting(context)

    override suspend fun reply(history: List<ChatMessage>, context: AssistantContext): String {
        val query = history.lastOrNull { it.role == ChatMessage.Role.user }?.text ?: ""
        requestedActions = emptyList()
        lastModel = null
        LocalEvidenceAssistant.emergencyReply(query)?.let {
            requestedActions = listOf("emergency_call_prompt")
            return it
        }
        LocalEvidenceAssistant.motionReply(query, context)?.let { return it }
        val (selfHarm, medication) = PulseTeamAgent.signals(query)
        // As the team's agent: possible self-harm offers the call prompt (it does not place a call).
        val offers = if (selfHarm) listOf("emergency_call_prompt") else emptyList()
        val mode = PulseTeamAgent.mode(context.assistanceStage, context.incident)
        val connectivity = if (context.isOnline) "online" else "offline"
        val turn = agent.turn(query, mode, connectivity, PulseTeamAgent.crash(context.incident))
        if (context.isOnline && (cloudPausedUntil ?: 0.0) < nowSeconds()) {
            val notes = knowledge().search(query, mode, connectivity, headerCost = agent.knowledgeHeaderCost).text
            converse(history, turn, notes, medication)?.let { answer ->
                requestedActions = (offers + requestedActions).toSet().sorted()
                return answer
            }
        }
        // The phone's own model: free, unlimited, and works with no signal.
        onDevice(history, turn)?.let { raw ->
            lastModel = OnDevicePulse.MODEL_NAME
            requestedActions = offers
            return PulseSentenceFilter.spoken(raw, medication) ?: PulseTeamAgent.localFallback(medication)
        }
        val answer = fallback.reply(history, context)
        requestedActions = (offers + fallback.requestedActions).toSet().sorted()
        return answer
    }

    private suspend fun converse(history: List<ChatMessage>, turn: String, knowledge: String, medication: Boolean): String? {
        val messages = agent.messages(history, turn, knowledge)
        for (model in FREE_MODELS) {
            try {
                val (text, actions) = complete(model, messages) ?: continue
                requestedActions = actions
                lastModel = model
                // When the filter removes every sentence, the team's agent says its short local line instead.
                return PulseSentenceFilter.spoken(text, medication) ?: PulseTeamAgent.localFallback(medication)
            } catch (e: CancellationException) {
                throw e
            } catch (limit: DailyLimitReached) {
                // Shared by every free model on the account: stop asking until it resets.
                cloudPausedUntil = limit.resetsAt
                Log.i(TAG, "OpenRouter daily free limit reached; using the fallback until it resets")
                return null
            } catch (e: Exception) {
                Log.i(TAG, "model $model unavailable: ${e.message}")
            }
        }
        return null
    }

    /**
     * One turn with the team's two-step tool loop: if the model asks for a tool, the app records the request
     * (nothing is performed) and asks the model to finish its reply.
     */
    private suspend fun complete(model: String, messages: List<JsonObject>): Pair<String, List<String>>? {
        val first = chat(model, messages, "auto")
        val calls = (first["tool_calls"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        val names = calls.mapNotNull { (it["function"] as? JsonObject)?.get("name")?.jsonPrimitive?.contentOrNull }
        val actions = names.filter { it in listOf("emergency_call_prompt", "find_tow") }.toSet().sorted()
        val content = (first["content"] as? JsonPrimitive)?.contentOrNull
        if (content != null && content.isNotBlank()) return content to actions
        if (calls.isEmpty()) return null
        val followUp = messages.toMutableList<JsonElement>()
        followUp.add(JsonObject(mapOf("role" to JsonPrimitive("assistant"), "content" to JsonNull, "tool_calls" to JsonArray(calls))))
        for (call in calls) {
            followUp.add(JsonObject(mapOf("role" to JsonPrimitive("tool"),
                "tool_call_id" to JsonPrimitive(call["id"]?.jsonPrimitive?.contentOrNull ?: ""),
                "content" to JsonPrimitive("""{"success": false, "pending": true, "app_action_requested": true, "performed": false}"""))))
        }
        val second = chat(model, followUp, "none")
        val text = (second["content"] as? JsonPrimitive)?.contentOrNull
        if (text == null || text.isBlank()) return null
        return text to actions
    }

    private suspend fun chat(model: String, messages: List<JsonElement>, toolChoice: String): JsonObject {
        // The team's settings: 384 output tokens (runtime/settings.py), no reasoning and temperature 0 (model profiles).
        val body = JsonObject(mapOf(
            "model" to JsonPrimitive(model), "messages" to JsonArray(messages), "max_tokens" to JsonPrimitive(384),
            "temperature" to JsonPrimitive(0), "reasoning" to JsonObject(mapOf("enabled" to JsonPrimitive(false), "exclude" to JsonPrimitive(true))),
            "tools" to TOOLS, "tool_choice" to JsonPrimitive(toolChoice),
        ))
        val request = Request.Builder().url(baseURL)
            .header("Authorization", "Bearer $key")
            .header("X-Title", "CrashSafe Pulse")
            .post(Http.jsonBody(body.toString()))
            .build()
        val result = Http.send(request, Http.client(12.0), maxBytes = 200_000)
        if (result.status == 429 && result.text.take(2000).contains("free-models-per-day")) {
            val reset = (result.headers["X-RateLimit-Reset"] ?: result.headers["x-ratelimit-reset"] ?: resetHeader(result.text))?.toDoubleOrNull()
            throw DailyLimitReached(reset?.let { it / 1000 } ?: (nowSeconds() + 3600))
        }
        if (!result.isOK) throw IOException("OpenRouter ${result.status}")
        val json = Http.json.parseToJsonElement(result.text).jsonObject
        val message = ((json["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.get("message") as? JsonObject
        return message ?: throw IOException("OpenRouter: no message")
    }

    /** OpenRouter puts the reset time (ms since 1970) in the error body's metadata.headers. */
    private fun resetHeader(text: String): String? = runCatching {
        val headers = Http.json.parseToJsonElement(text).jsonObject["error"]?.jsonObject?.get("metadata")?.jsonObject?.get("headers")?.jsonObject
        headers?.get("X-RateLimit-Reset")?.jsonPrimitive?.contentOrNull
    }.getOrNull()

    companion object {
        private const val TAG = "CrashSafe.assistant"
        /** Both screened by the team (pulse_agent/config/model_profiles.json). OpenRouter's free-plan limit is shared. */
        val FREE_MODELS = listOf("nvidia/nemotron-3.5-lightning:free", "google/gemma-4-26b-a4b-it:free")

        /** The team's tool descriptions (pulse_agent/tools/dispatch.py) for the two tools the app can offer. */
        private val TOOLS = JsonArray(listOf(
            tool("emergency_call_prompt", "Ask the app to display its emergency calling prompt. Does not place or connect a call."),
            tool("find_tow", "Request a read-only tow lookup after safety. Never books or pays."),
        ))

        private fun tool(name: String, description: String) = JsonObject(mapOf(
            "type" to JsonPrimitive("function"),
            "function" to JsonObject(mapOf("name" to JsonPrimitive(name), "description" to JsonPrimitive(description),
                "parameters" to JsonObject(mapOf("type" to JsonPrimitive("object"), "properties" to JsonObject(emptyMap()))))),
        ))

        /** Direct when this build has an OpenRouter key, otherwise the backend/on-device assistant. */
        fun configured(agent: PulseTeamAgent, knowledge: () -> PulseKnowledgeIndex): AssistantService {
            val backend = RAGAssistantService.configured()
            val key = PulseKeys.openRouter() ?: return backend
            return DirectPulseService(key, backend, agent, knowledge)
        }
    }
}

/**
 * Pulse on the phone's own model. iOS uses Apple Intelligence here; Android's equivalent (Gemini Nano through
 * AICore) is only on a few phones and its API is still experimental, so for now this answers nothing and the
 * on-device guides (`LocalEvidenceAssistant`) take over, as they do on iPhones without Apple Intelligence.
 */
object OnDevicePulse {
    const val MODEL_NAME = "android-on-device"
    val isAvailable: Boolean = false

    @Suppress("RedundantSuspendModifier")
    suspend fun reply(): String? = null
}
