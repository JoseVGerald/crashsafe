package org.cac.crashsafe.core.pulse

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.model.ChatMessage
import java.time.Instant
import kotlin.math.max

/**
 * The team's Pulse agent prompt, assembled on the phone exactly as pulse_agent builds each model request
 * (hooks/always_core.py `prepend`):
 *   system 1  core.md (the Core; it already contains the hard lines)
 *   system 2  [PULSE_TURN]       context/schema.py `build_turn`: mode, mode focus, app flags, data contract
 *   system 3  [PULSE_KNOWLEDGE]  knowledge/retrieve.py `Knowledge.search`: their notes (optional)
 *   then the conversation, trimmed to their 5,000-token budget.
 * The data comes from the team's code via Tools/Pulse/export_team_pulse.py (`assets/pulse/`).
 */
class PulseTeamAgent(val core: String, val coreMini: String, turnJson: String?) {
    private val contract: String
    private val acknowledgment: JsonObject
    private val modes: Map<String, String>
    /** Tokens of the "[PULSE_KNOWLEDGE]" header, as the team's tokenizer counts it. */
    val knowledgeHeaderCost: Int

    init {
        val json = turnJson?.let { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() }
        contract = json?.get("data_contract")?.jsonPrimitive?.contentOrNull ?: ""
        acknowledgment = json?.get("tool_acknowledgment") as? JsonObject ?: JsonObject(emptyMap())
        modes = (json?.get("modes") as? JsonObject)?.mapValues { it.value.jsonPrimitive.contentOrNull ?: "" } ?: emptyMap()
        knowledgeHeaderCost = json?.get("knowledge_header_cost")?.jsonPrimitive?.intOrNull ?: 7
    }

    /** `build_turn`: the per-turn context block, as the team's code writes it (sorted keys, no escaped slashes). */
    fun turn(text: String, mode: String, connectivity: String, crash: Map<String, JsonElement>): String {
        val flags = signals(text)
        val payload = mutableMapOf<String, JsonElement>(
            "mode" to JsonPrimitive(mode),
            "mode_focus" to JsonPrimitive(modes[mode] ?: ""),
            "condition" to JsonObject(listOf("injury_risk", "distress", "clarity", "engagement", "environmental_danger", "ability_to_act")
                .associateWith { JsonPrimitive("unknown") }),
            "profile" to JsonObject(emptyMap()),
            "crash" to JsonObject(crash),
            "connectivity" to JsonPrimitive(connectivity),
            "tools" to JsonArray(tools.map { tool -> JsonObject(tool.mapValues { JsonPrimitive(it.value) }) }),
            "app_flags" to JsonObject(mapOf("possible_self_harm" to JsonPrimitive(flags.first),
                "medication_question" to JsonPrimitive(flags.second))),
            "tool_acknowledgment" to acknowledgment,
            "data_contract" to JsonPrimitive(contract),
        )
        if (connectivity == "offline") payload["offline_focus"] = JsonPrimitive(modes["offline_overlay"] ?: "")
        return "[PULSE_TURN]\n" + Json.encodeToString(JsonElement.serializer(), sorted(JsonObject(payload)))
    }

    /**
     * `prepend`: Core, turn and knowledge as app-owned system messages, then the conversation. Over the
     * 5,000-token budget, optional knowledge goes first, then the oldest complete turns. (Sizes here are
     * estimated at 4 characters per token; the team counts with tiktoken.)
     */
    fun messages(history: List<ChatMessage>, turn: String, knowledge: String): List<JsonObject> {
        var conversation = history.takeLast(40).mapNotNull { message ->
            val text = (if (message.role == ChatMessage.Role.user) message.text else spokenPart(message.text)).trim()
            if (text.isEmpty()) null
            else message(if (message.role == ChatMessage.Role.user) "user" else "assistant", text.take(2000))
        }
        var prefix = listOf(message("system", core), message("system", turn))
        if (knowledge.isNotEmpty()) prefix = prefix + message("system", knowledge)
        fun size(): Int {
            val json = Json.encodeToString(JsonElement.serializer(), JsonArray(prefix + conversation)).toByteArray().size
            return (json + 1_100) / 4 // + the tool definitions
        }
        if (size() > 5000 && prefix.size > 2) prefix = prefix.take(2)
        while (size() > 5000 && conversation.count { it.role == "user" } > 1) {
            val next = conversation.indices.drop(1).firstOrNull { conversation[it].role == "user" } ?: break
            conversation = conversation.drop(next)
        }
        return prefix + conversation
    }

    private val JsonObject.role: String? get() = this["role"]?.jsonPrimitive?.contentOrNull

    companion object {
        /** The two tools the app can offer (the team's tiers: pre-approved prompts, never actions). */
        val tools = listOf(mapOf("name" to "emergency_call_prompt", "tier" to "pre_approved"),
            mapOf("name" to "find_tow", "tier" to "pre_approved"))

        /**
         * The team's mode for this moment: crisis support after a detected crash, aftermath for follow-up help,
         * otherwise standby (their "normal assistant" mode).
         */
        fun mode(stage: String, incident: AssistantIncident?): String =
            if (stage == "followup") "aftermath" else if (incident != null) "crisis_support" else "standby"

        fun crash(incident: AssistantIncident?, now: Double = nowSeconds()): Map<String, JsonElement> {
            val crash = mutableMapOf<String, JsonElement>("severity" to JsonPrimitive("unknown"), "seconds_since_crash" to JsonNull,
                "location" to JsonNull, "location_source" to JsonPrimitive("unknown"))
            if (incident == null) return crash
            val severity = incident.impact?.severity
            if (severity != null && severity in listOf("minor", "moderate", "severe")) crash["severity"] = JsonPrimitive(severity)
            runCatching { Instant.parse(incident.capturedAt).epochSecond.toDouble() }.getOrNull()?.let { at ->
                crash["seconds_since_crash"] = JsonPrimitive(max(0, (now - at).roundToIntHalfAway()))
            }
            if (incident.isSimulated) crash["simulated"] = JsonPrimitive(true)
            return crash
        }

        /** `signals`: the team's conservative app flags (never a risk score). Self-harm, then medication. */
        fun signals(text: String): Pair<Boolean, Boolean> {
            val t = text.lowercase().replace("’", "'")
            val harm = Regex("""kill myself|hurt myself|end (?:my life|it all)|want to die|didn't make it|did not make it|better off dead|wish i (?:was|were) dead|jok(?:e|ing).{0,30}(?:die|kill myself)""")
            val dosing = Regex("""dose|dosage|how much.{0,50}(?:tylenol|medicine|kid|child)|(?:take|give).{0,20}(?:ibuprofen|aspirin|tylenol|pills|tablets)""")
            return harm.containsMatchIn(t) to dosing.containsMatchIn(t)
        }

        /** What the team's agent says when every model sentence was filtered out. */
        fun localFallback(medication: Boolean): String =
            if (medication) "I can't give a medication dose." else "I'm here. What do you need right now?"

        fun message(role: String, content: String) = JsonObject(mapOf("role" to JsonPrimitive(role), "content" to JsonPrimitive(content)))

        /** Sorted keys at every level, like JSONSerialization's `.sortedKeys`. */
        fun sorted(element: JsonElement): JsonElement = when (element) {
            is JsonObject -> JsonObject(element.entries.sortedBy { it.key }.associate { it.key to sorted(it.value) })
            is JsonArray -> JsonArray(element.map { sorted(it) })
            else -> element
        }
    }
}
