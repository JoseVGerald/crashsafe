package org.cac.crashsafe.core.pulse

import kotlinx.coroutines.delay
import org.cac.crashsafe.core.intelligence.TransportClass
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.model.CheckInOutcome
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale

/**
 * The conscious-path assistant.
 *
 * AI TEAM: `DirectPulseService` (OpenRouter from the phone) and `RAGAssistantService` (our server) implement
 * this; never put production API keys in the app.
 */
interface AssistantService {
    /** First message shown when the chat opens. */
    fun greeting(context: AssistantContext): String

    /** Reply to the latest user message given the full history. */
    suspend fun reply(history: List<ChatMessage>, context: AssistantContext): String

    /**
     * What Pulse asked the app to offer with its last reply ("emergency_call_prompt", "find_tow"). The app only
     * shows these as buttons; nothing happens until the person taps one.
     */
    val requestedActions: List<String> get() = emptyList()
}

/** Returns canned, safety-first replies based on simple keywords. */
class MockAssistantService(private val latencyMillis: Long = 900) : AssistantService {
    override fun greeting(context: AssistantContext): String {
        val name = context.userName.split(" ").firstOrNull { it.isNotEmpty() } ?: "there"
        return when (val scenario = context.scenario) {
            AssistantScenario.General -> "Hi $name. I'm here if anything happens on the road. Ask me about towing, insurance, or what to do after a crash."
            is AssistantScenario.AfterCrash -> when (scenario.outcome) {
                CheckInOutcome.ok -> "I'm glad you're responding, $name. Take a slow breath. First things first: are you somewhere safe, away from traffic? If anyone is hurt, call 911 now."
                CheckInOutcome.needsHelp -> "Help comes first. If you haven't already, call 911 — the button is at the top of this screen. I cannot confirm family alert delivery. Tell me what's happening and I'll stay with you."
                CheckInOutcome.noResponse -> "No response was recorded. I cannot confirm family alert delivery. If you're awake now: are you hurt? If yes, call 911 first."
            }
        }
    }

    override suspend fun reply(history: List<ChatMessage>, context: AssistantContext): String {
        delay(latencyMillis)
        val last = history.lastOrNull { it.role == ChatMessage.Role.user }?.text?.lowercase() ?: ""
        val suffix = if (context.isOnline) "" else "\n\n(Offline — using your saved trip pack.)"
        fun has(vararg needles: String) = needles.any { last.contains(it) }
        return when {
            has("hurt", "pain", "bleed", "injur", "dizzy") ->
                "If you or anyone else is hurt, call 911 now — that comes before anything else. Don't move someone with neck or back pain unless there's fire or traffic danger."
            has("tow", "stuck", "won't start", "wont start") ->
                "I found tow companies near you in your trip pack. I'd suggest calling the closest one yourself and asking for the total price before they hook up your car. Want me to show the list?"
            has("insur", "claim") -> {
                val insurer = context.insurer.ifEmpty { "your insurer" }
                "Report it to $insurer promptly — most policies require it. Stick to facts: time, place, weather, what you saw. Don't guess or admit fault at the scene. (Not legal advice.)"
            }
            has("photo", "picture", "document", "record") ->
                "Once you're safe: photograph all vehicles from each corner, license plates, the road, signs, and anything like rain or darkness. Swap names, phone numbers, and insurance with the other driver."
            has("scared", "panic", "shaking", "anxious", "nervous") ->
                "That's a normal reaction. Let's slow down together: breathe in for 4, hold for 4, out for 6. You don't need to decide anything right this second."
            else ->
                "Got it. Here's the order I'd go in: 1) make sure everyone is safe, 2) call 911 if anyone's hurt, 3) document the scene, 4) arrange a tow, 5) notify your insurer. Which one should we start with?"
        } + suffix
    }
}

internal data class LocalKnowledgeCard(
    val id: String,
    val title: String,
    val terms: String,
    val body: String,
    val scope: String,
    val stage: String,
    val expires: String,
    val sources: List<String>,
)

/** Small bundled evidence cards; does not depend on a model, network or trip-pack availability. */
class LocalEvidenceAssistant : AssistantService {
    override fun greeting(context: AssistantContext): String = when (val scenario = context.scenario) {
        AssistantScenario.General -> "I can help with crash procedures, documentation and insurance questions. Tell me what you need."
        is AssistantScenario.AfterCrash -> when (scenario.outcome) {
            CheckInOutcome.ok -> "I'm glad you can respond. Are you away from immediate danger? If anyone needs urgent help, call 911."
            CheckInOutcome.needsHelp -> "If you need urgent help, call 911 now. I cannot confirm that any family alert was delivered."
            CheckInOutcome.noResponse -> "No response was recorded. That does not establish unconsciousness or confirm that an alert was delivered. If you need urgent help, call 911."
        }
    }

    override suspend fun reply(history: List<ChatMessage>, context: AssistantContext): String {
        val query = history.lastOrNull { it.role == ChatMessage.Role.user }?.text ?: ""
        emergencyReply(query)?.let { return it }
        motionReply(query, context)?.let { return it }
        val cards = ranked(query, context).take(if (context.assistanceStage == "active") 1 else 2)
        if (cards.isEmpty()) {
            return "I don't have current, supported information for that question and location. If you are safe and need paperwork help, select follow-up mode. For urgent danger, call 911."
        }
        val intro = if (context.responseStyle == "supportive") "We can take this one step at a time.\n\n" else ""
        val bodies = cards.joinToString("\n\n") { it.body + " [" + it.id + "]" }
        val sources = cards.flatMap { it.sources }.toSet().sorted().mapNotNull { KnowledgeCards.sourceLinks[it] }.joinToString("\n")
        return intro + bodies + "\n\nSources:\n" + sources
    }

    companion object {
        private val aliases = mapOf("insurer" to "insurance", "claims" to "insurance", "claim" to "insurance",
            "scared" to "panic", "shaking" to "panic", "panicking" to "panic",
            "photos" to "photographs", "pictures" to "photographs",
            "electric" to "ev", "accident" to "collision", "crash" to "collision")

        // Short function words carry no topic: "on the freeway" must not match "Vehicle on fire".
        private val stop = setOf("the", "a", "an", "i", "my", "me", "to", "is", "it", "what", "how", "do", "should",
            "can", "of", "for", "and", "you", "after", "about", "have", "are", "on", "in", "at",
            "with", "was", "were", "be", "been", "just", "this", "that", "there", "if", "or", "but",
            "so", "from", "by", "as", "its", "m", "s", "t", "re", "ve", "ll", "d")

        private fun words(value: String): Set<String> =
            value.lowercase().split(Regex("[^\\p{L}\\p{M}\\p{N}]+"))
                .filter { it.isNotEmpty() && it !in stop }.map { aliases[it] ?: it }.toSet()

        /** Answers from the app's own measurements (rolling sensor history), never from guesses. */
        fun motionReply(query: String, context: AssistantContext): String? {
            val text = query.lowercase()
            val asksImpact = listOf("how hard", "impact", "how fast was", "speed change", "how bad was", "g-force", "g force").any { text.contains(it) }
            val asksActivity = listOf("what am i doing", "am i driving", "am i walking", "what mode", "my activity", "detect").any { text.contains(it) }
            val asksDriving = listOf("brake", "braking", "how am i driving", "driving behavior", "accelerat").any { text.contains(it) }
            val impact = context.incident?.impact
            if (asksImpact && impact != null) {
                val mph = (impact.deltaVMps * 2.23694).roundToIntHalfAway()
                var answer = "Your phone measured a ${impact.severity} impact: a peak of about ${impact.peakG.roundToIntHalfAway()} g " +
                    "and a speed change of roughly $mph mph over ${(impact.pulseDurationS * 1000).roundToIntHalfAway()} ms."
                impact.timeToStopS?.let { answer += String.format(Locale.US, " The car stopped about %.1f s after the hit.", it) }
                if (impact.isSimulated) answer += " (This was a test crash with simulated data.)"
                return answer + " It's an estimate from the phone's sensors, not a medical assessment — if anyone is hurt, call 911."
            }
            val activity = context.activity
            if (asksActivity && activity != null) {
                val mode = TransportClass.entries.firstOrNull { it.label == activity.transport.label }
                    ?: return "I can't tell yet — the last few seconds of motion don't clearly match one mode."
                val score = ((activity.transport.probability ?: 0.0) * 100).roundToIntHalfAway()
                return "From your phone's motion over the last few seconds, it looks like you're ${mode.title.lowercase()} " +
                    "(model score $score%). That's a pattern match, not a certainty."
            }
            if (asksDriving && activity != null) {
                val brakes = activity.harshBrakes10min
                val accels = activity.harshAccels10min
                if (brakes + accels == 0) return "No harsh braking or acceleration in the last 10 minutes. Nice and smooth."
                return "In the last 10 minutes: $brakes hard brake${if (brakes == 1) "" else "s"} and $accels hard acceleration${if (accels == 1) "" else "s"}. " +
                    "Leaving a bigger gap ahead gives you more time to slow down gently."
            }
            return null
        }

        fun emergencyReply(query: String): String? {
            val text = query.lowercase().replace("’", "'")
            val historical = listOf("last week", "last month", "years ago", "yesterday", "hypothetically", "what if").any { text.contains(it) }
            if (historical && !text.contains("now") && !text.contains("currently")) return null
            if (listOf("on fire", "flames", "smoke coming", "car is burning").any { text.contains(it) }) {
                return "Call 911 now. If you can get out, move away from the burning vehicle and traffic. Do not return or try to fight the fire. [S10]"
            }
            val checked = text.replace("nobody is unconscious", "").replace("no one is unconscious", "").replace("not unconscious", "")
            if (listOf("not breathing", "isn't breathing", "won't wake", "not waking up", "unresponsive", "unconscious", "passed out",
                    "can't breathe", "cannot breathe", "trouble breathing", "chest hurts", "chest pain",
                    "bleeding heavily", "severe bleeding", "seizure", "headache getting worse").any { checked.contains(it) }) {
                return "Call 911 now and follow the call-taker's instructions. Describe the symptoms. This assistant has not contacted emergency services. [S01, S03, S08]"
            }
            return null
        }

        /** The best-matching current cards for this question, location and stage (best first). */
        internal fun ranked(query: String, context: AssistantContext): List<LocalKnowledgeCard> {
            val today = LocalDate.now(ZoneOffset.UTC).toString()
            val terms = words(query)
            return KnowledgeCards.cards.mapNotNull { card ->
                if (card.expires < today || !(card.scope == "US" || card.scope == context.jurisdiction) ||
                    !(card.stage == "any" || card.stage == context.assistanceStage)) return@mapNotNull null
                val score = words(card.title + " " + card.terms).intersect(terms).size * 3 + words(card.body).intersect(terms).size
                if (score >= 3) card to score else null
            }.sortedWith(compareBy<Pair<LocalKnowledgeCard, Int>>({ -it.second }, { it.first.id })).map { it.first }
        }

        /** Verified evidence for a model to use as data: card id, text, and its sources as "title: url". */
        fun evidence(query: String, context: AssistantContext, limit: Int): List<Triple<String, String, List<String>>> =
            ranked(query, context).take(limit).map { card ->
                Triple(card.id, card.body, card.sources.mapNotNull { KnowledgeCards.sourceLinks[it] })
            }
    }
}
