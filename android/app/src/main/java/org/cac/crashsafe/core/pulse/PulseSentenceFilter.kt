package org.cac.crashsafe.core.pulse

/**
 * The team's deterministic sentence filter (`Backend/rag/pulse_core/sentence_filter.py`), in Kotlin: every
 * sentence a model writes passes it before it is shown or spoken. Never calls a model.
 */
object PulseSentenceFilter {
    sealed interface Decision {
        val text: String?

        data class Pass(override val text: String) : Decision
        data class Rewrite(override val text: String, val reason: String) : Decision
        data class Drop(val reason: String) : Decision {
            override val text: String? get() = null
        }
    }

    const val doseFallback = "I can't give a medication dose."
    private const val number = """(?:\d+(?:[.,]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|half|quarter)"""
    private val dose = regex("""\b$number\s*(?:mg|mcg|μg|ug|g|kg|ml|milligrams?|micrograms?|grams?|millilit(?:er|re)s?|pills?|tablets?|capsules?|teaspoons?|tablespoons?|doses?)\b""")
    private val medicationQuantity = regex("""\b(?:take|give|swallow|use)\b.{0,30}""" + number)
    private val banned = regex("""\b(?:calm(?:ing)? down|let'?s calm down|relax|don't panic|do not panic|everything will be fine|you(?:'re| are) fine|you(?:'ll| will) be (?:okay|ok)|it's nothing|it(?:'s| is) (?:not )?your fault|(?:you are|you're) uninjured)\b""")
    private val scoring = regex("""C-SSRS|SAFE-T|Columbia.{0,20}(?:score|scale)|(?:low|moderate|high)[ -](?:acute[ -])?risk|lethality.{0,15}(?:score|scale)|hospitalization disposition""")
    private val action = regex("""\b(?:done(?=[.!]?$)|sent(?=[.!]?$)|i(?:'ve| have)? (?:called|sent|notified|alerted|contacted|shared|booked)|help (?:is|are) (?:coming|on the way)|help knows where you are|they(?:'re| are) on the way)\b""")
    private val listMarker = regex("""^(?:[-*•]\s+|\d+[.)]\s+)""")
    private val notSpeech = regex("""https?://|[\[\]{}*_#<>]|\b(?:tool_call|function_name)\b""")
    private val required = listOf(
        regex("called|help|on the way") to "emergency_call_prompt",
        regex("sent|notified|alerted|contacted") to "alert_contacts",
        regex("shared") to "share_location",
        regex("booked") to "book_tow_or_submit_claim",
    )
    private val callClaim = regex("""called|help (?:is|are)|on the way""")
    private val sentenceEnd = regex("""(?<!\d)[.!?](?=\s|$)|(?<=\d)[!?](?=\s|$)""")

    fun filter(text: String, successfulActions: Set<String> = emptySet(), medicationQuestion: Boolean = false): Decision {
        var normalized = text.trim().replace("’", "'")
        normalized = listMarker.replace(normalized, "").trim()
        if (normalized.isEmpty()) return Decision.Drop("empty")
        if (dose.containsMatchIn(normalized)) return Decision.Rewrite(doseFallback, "dose_pattern")
        if (medicationQuestion && medicationQuantity.containsMatchIn(normalized)) return Decision.Rewrite(doseFallback, "medication_quantity")
        if (banned.containsMatchIn(normalized)) return Decision.Drop("banned_phrase")
        if (scoring.containsMatchIn(normalized)) return Decision.Drop("clinical_scoring")
        val claimsAction = action.containsMatchIn(normalized)
        if (claimsAction && successfulActions.isEmpty()) {
            return Decision.Rewrite("I don't have confirmation that worked.", "unconfirmed_action")
        }
        for ((pattern, name) in required) {
            if (claimsAction && pattern.containsMatchIn(normalized) && name !in successfulActions) {
                return Decision.Rewrite("I don't have confirmation that worked.", "unmatched_action")
            }
        }
        if (claimsAction && callClaim.containsMatchIn(normalized)) return Decision.Drop("call_prompt_not_dispatch_confirmation")
        if (notSpeech.containsMatchIn(normalized)) return Decision.Drop("not_speech")
        return Decision.Pass(normalized)
    }

    /** Whole sentences, as the team's `SentenceStream` splits them (a decimal dose like 2.5 mg stays whole). */
    fun sentences(text: String): List<String> {
        var rest = text
        val result = mutableListOf<String>()
        while (true) {
            val match = sentenceEnd.find(rest) ?: break
            val end = match.range.last + 1
            result.add(rest.substring(0, end).trim())
            rest = rest.substring(end).trim { it == ' ' || it == '\t' }
        }
        val tail = rest.trim()
        if (tail.isNotEmpty()) result.add(tail)
        return result
    }

    /**
     * The reply as it may be spoken: every sentence through the team's filter (their agent has no sentence cap),
     * no ellipses (their Core forbids them), and short enough for one voice clip. Null when nothing survives.
     */
    fun spoken(text: String, medicationQuestion: Boolean): String? {
        val cleaned = Regex("""\s*(?:\.\.\.|…)\s*""").replace(text, ", ")
        val kept = mutableListOf<String>()
        for (sentence in sentences(cleaned)) {
            val kept1 = filter(sentence, medicationQuestion = medicationQuestion).text ?: continue
            if (kept1 in kept || (kept + kept1).joinToString(" ").length > 1100) continue
            kept.add(kept1)
        }
        return if (kept.isEmpty()) null else kept.joinToString(" ")
    }

    private fun regex(pattern: String) = Regex(pattern, RegexOption.IGNORE_CASE)
}

/** What to say from an assistant reply: the answer without its source list or card IDs. */
fun spokenPart(reply: String): String =
    Regex("""\s*\[[A-Z0-9_]+\]""").replace(reply.split("\n\nSources:").first(), "")
