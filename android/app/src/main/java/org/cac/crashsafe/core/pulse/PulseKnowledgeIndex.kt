package org.cac.crashsafe.core.pulse

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.text.Normalizer
import kotlin.math.ln

/**
 * The team's knowledge index (knowledge/retrieve.py): their 108 notes searched as SQLite FTS5 does it, with
 * the porter tokenizer, the same bm25 weights (title 8, text 1), mode/state filters, relevance cut-off,
 * two-example limit and 1,500-token budget. Android's SQLite has no FTS5, so the index and FTS5's bm25()
 * are computed here in Kotlin; the iOS app runs the same query in SQLite.
 */
class PulseKnowledgeIndex(json: String?) {
    @Serializable
    private data class Row(
        val id: String,
        val title: String,
        val text: String,
        val rendered: String,
        val kind: String,
        val cost: Int,
        val priority: Int,
        val modes: List<String>,
        val states: List<String>,
    )

    private class Doc(val row: Row, val titleTokens: Map<String, Int>, val textTokens: Map<String, Int>, val size: Int)

    private val docs: List<Doc>
    private val averageLength: Double

    init {
        val rows = json?.let {
            runCatching { Json { ignoreUnknownKeys = true }.decodeFromString<List<Row>>(it) }.getOrNull()
        } ?: emptyList()
        docs = rows.map { row ->
            val title = tokenize(row.title)
            val text = tokenize(row.text)
            Doc(row, title.groupingBy { it }.eachCount(), text.groupingBy { it }.eachCount(), title.size + text.size)
        }
        averageLength = if (docs.isEmpty()) 1.0 else docs.sumOf { it.size }.toDouble() / docs.size
    }

    val count: Int get() = docs.size

    data class Result(val text: String, val ids: List<String>)

    /** `Knowledge.search`: the notes for this turn as one [PULSE_KNOWLEDGE] block, best first. */
    fun search(text: String, mode: String, connectivity: String, cap: Int = 1500, headerCost: Int = 7): Result {
        if (mode in listOf("crash_check", "unresponsive_escalation") || connectivity == "offline") return Result("", emptyList())
        val seen = mutableSetOf<String>()
        val words = WORD.findAll(text.lowercase()).map { it.value }
            .filter { seen.add(it) && it !in stopWords }.take(16).toList()
        // Each quoted query word is one FTS5 phrase; a word the tokenizer splits further is a multi-token phrase.
        val phrases = words.filter { it.length > 2 }.map { tokenize(it) }.filter { it.isNotEmpty() }
        if (phrases.isEmpty()) return Result("", emptyList())

        val n = docs.size.toDouble()
        val idf = phrases.map { phrase ->
            val hits = docs.count { doc -> phraseCount(doc, phrase).let { (t, x) -> t + x > 0 } }
            val value = ln((n - hits + 0.5) / (hits + 0.5))
            if (value <= 0) 1e-6 else value
        }
        data class Scored(val doc: Doc, val score: Double)
        val k1 = 1.2
        val b = 0.75
        val scored = docs.mapNotNull { doc ->
            var matched = false
            var score = 0.0
            phrases.forEachIndexed { i, phrase ->
                val (inTitle, inText) = phraseCount(doc, phrase)
                if (inTitle + inText > 0) matched = true
                val freq = 8.0 * inTitle + 1.0 * inText
                score += idf[i] * (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * doc.size / averageLength))
            }
            if (!matched || mode !in doc.row.modes || doc.row.states.none { it in listOf("steady") }) null
            else Scored(doc, -score)
        }.sortedWith(compareBy<Scored>({ it.score }, { it.doc.row.priority }, { it.doc.row.id })).take(100)

        val chosen = mutableListOf<String>()
        val seenText = mutableSetOf<String>()
        var examples = 0
        var used = headerCost
        val best = -(scored.firstOrNull()?.score ?: 0.0)
        for (row in scored) {
            if (-row.score < best * 0.6) continue // no weak, incidental matches
            val note = row.doc.row
            val body = note.text.trim()
            if (body in seenText || (note.kind == "example" && examples >= 2) || used + note.cost + 2 > minOf(cap, 1500)) continue
            chosen.add(note.id)
            seenText.add(body)
            used += note.cost + 2
            if (note.kind == "example") examples++
        }
        if (chosen.isEmpty()) return Result("", emptyList())
        val rendered = chosen.mapNotNull { id -> docs.firstOrNull { it.row.id == id }?.row?.rendered }
        return Result("[PULSE_KNOWLEDGE]\n" + rendered.joinToString("\n\n"), chosen)
    }

    /** Occurrences of a (single- or multi-token) phrase in the title and text columns. */
    private fun phraseCount(doc: Doc, phrase: List<String>): Pair<Int, Int> {
        if (phrase.size == 1) return (doc.titleTokens[phrase[0]] ?: 0) to (doc.textTokens[phrase[0]] ?: 0)
        return countSequence(tokenize(doc.row.title), phrase) to countSequence(tokenize(doc.row.text), phrase)
    }

    private fun countSequence(tokens: List<String>, phrase: List<String>): Int =
        (0..tokens.size - phrase.size).count { start -> phrase.indices.all { tokens[start + it] == phrase[it] } }

    companion object {
        /** `[^\W_]+`: runs of letters and digits. */
        private val WORD = Regex("[\\p{L}\\p{N}\\p{M}]+")

        private val stopWords: Set<String> = """
            a an the and or but i me my we us our you your they their he she it its
            is am are was were be been being do does did have has had can could would should will
            what which who how when where why this that these those of to for from at in on into
            off with without after before about as if then just so not no anyone everyone nobody
            someone something anything tell say ask please need want once first also very really
            synthetic test testing crash accident pulse pulled over minor reports
        """.trimIndent().split(Regex("\\s+")).filter { it.isNotEmpty() }.toSet()

        /** FTS5's `porter unicode61`: letters and digits, lowercased, diacritics removed, then Porter-stemmed. */
        fun tokenize(text: String): List<String> {
            val folded = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
            return Regex("[\\p{L}\\p{N}\\p{Co}]+").findAll(folded).map { PorterStemmer.stem(it.value) }.toList()
        }
    }
}
