package org.cac.crashsafe.core.pulse

/**
 * Martin Porter's stemming algorithm, as SQLite's FTS5 `porter` tokenizer applies it (tokens shorter than
 * 3 or longer than 64 characters pass through unchanged). Used by `PulseKnowledgeIndex`, which runs the
 * team's FTS5 query in Kotlin because Android's SQLite has no FTS5.
 */
object PorterStemmer {
    fun stem(word: String): String {
        if (word.length < 3 || word.length > 64) return word
        return Stemmer(word).run()
    }

    private class Stemmer(word: String) {
        private var b = word.toCharArray()
        /** Offset to the end of the stemmed word. */
        private var k = b.size - 1
        /** A general offset into the string. */
        private var j = 0

        fun run(): String {
            step1ab()
            step1c()
            step2()
            step3()
            step4()
            step5()
            return String(b, 0, k + 1)
        }

        /** True when b[i] is a consonant. */
        private fun cons(i: Int): Boolean = when (b[i]) {
            'a', 'e', 'i', 'o', 'u' -> false
            'y' -> if (i == 0) true else !cons(i - 1)
            else -> true
        }

        /** The number of consonant sequences between 0 and j: [C](VC){m}[V]. */
        private fun m(): Int {
            var n = 0
            var i = 0
            while (true) {
                if (i > j) return n
                if (!cons(i)) break
                i++
            }
            i++
            while (true) {
                while (true) {
                    if (i > j) return n
                    if (cons(i)) break
                    i++
                }
                i++
                n++
                while (true) {
                    if (i > j) return n
                    if (!cons(i)) break
                    i++
                }
                i++
            }
        }

        /** True when 0..j contains a vowel. */
        private fun vowelInStem(): Boolean = (0..j).any { !cons(it) }

        /** True when j, j-1 contain a double consonant. */
        private fun doublec(j: Int): Boolean = j >= 1 && b[j] == b[j - 1] && cons(j)

        /** True when i-2, i-1, i is consonant-vowel-consonant and the last is not w, x or y. */
        private fun cvc(i: Int): Boolean {
            if (i < 2 || !cons(i) || cons(i - 1) || !cons(i - 2)) return false
            val ch = b[i]
            return !(ch == 'w' || ch == 'x' || ch == 'y')
        }

        private fun ends(s: String): Boolean {
            val l = s.length
            val o = k - l + 1
            if (o < 0) return false
            for (i in 0 until l) if (b[o + i] != s[i]) return false
            j = k - l
            return true
        }

        /** Sets (j+1)..k to the characters in s, readjusting k. */
        private fun setto(s: String) {
            val l = s.length
            val o = j + 1
            if (o + l > b.size) b = b.copyOf(o + l)
            for (i in 0 until l) b[o + i] = s[i]
            k = j + l
        }

        private fun r(s: String) {
            if (m() > 0) setto(s)
        }

        private fun step1ab() {
            if (b[k] == 's') {
                if (ends("sses")) k -= 2
                else if (ends("ies")) setto("i")
                else if (b[k - 1] != 's') k--
            }
            if (ends("eed")) {
                if (m() > 0) k--
            } else if ((ends("ed") || ends("ing")) && vowelInStem()) {
                k = j
                if (ends("at")) setto("ate")
                else if (ends("bl")) setto("ble")
                else if (ends("iz")) setto("ize")
                else if (doublec(k)) {
                    k--
                    val ch = b[k]
                    if (ch == 'l' || ch == 's' || ch == 'z') k++
                } else if (m() == 1 && cvc(k)) setto("e")
            }
        }

        private fun step1c() {
            if (ends("y") && vowelInStem()) b[k] = 'i'
        }

        private fun step2() {
            if (k == 0) return
            when (b[k - 1]) {
                'a' -> {
                    if (ends("ational")) r("ate") else if (ends("tional")) r("tion")
                }
                'c' -> {
                    if (ends("enci")) r("ence") else if (ends("anci")) r("ance")
                }
                'e' -> if (ends("izer")) r("ize")
                'l' -> {
                    if (ends("bli")) r("ble")
                    else if (ends("alli")) r("al")
                    else if (ends("entli")) r("ent")
                    else if (ends("eli")) r("e")
                    else if (ends("ousli")) r("ous")
                }
                'o' -> {
                    if (ends("ization")) r("ize") else if (ends("ation")) r("ate") else if (ends("ator")) r("ate")
                }
                's' -> {
                    if (ends("alism")) r("al")
                    else if (ends("iveness")) r("ive")
                    else if (ends("fulness")) r("ful")
                    else if (ends("ousness")) r("ous")
                }
                't' -> {
                    if (ends("aliti")) r("al") else if (ends("iviti")) r("ive") else if (ends("biliti")) r("ble")
                }
                'g' -> if (ends("logi")) r("log")
            }
        }

        private fun step3() {
            when (b[k]) {
                'e' -> {
                    if (ends("icate")) r("ic") else if (ends("ative")) r("") else if (ends("alize")) r("al")
                }
                'i' -> if (ends("iciti")) r("ic")
                'l' -> {
                    if (ends("ical")) r("ic") else if (ends("ful")) r("")
                }
                's' -> if (ends("ness")) r("")
            }
        }

        private fun step4() {
            if (k == 0) return
            when (b[k - 1]) {
                'a' -> if (!ends("al")) return
                'c' -> if (!ends("ance") && !ends("ence")) return
                'e' -> if (!ends("er")) return
                'i' -> if (!ends("ic")) return
                'l' -> if (!ends("able") && !ends("ible")) return
                'n' -> if (!ends("ant") && !ends("ement") && !ends("ment") && !ends("ent")) return
                'o' -> {
                    if (ends("ion") && j >= 0 && (b[j] == 's' || b[j] == 't')) {
                        // ok
                    } else if (!ends("ou")) return
                }
                's' -> if (!ends("ism")) return
                't' -> if (!ends("ate") && !ends("iti")) return
                'u' -> if (!ends("ous")) return
                'v' -> if (!ends("ive")) return
                'z' -> if (!ends("ize")) return
                else -> return
            }
            if (m() > 1) k = j
        }

        private fun step5() {
            j = k
            if (b[k] == 'e') {
                val a = m()
                if (a > 1 || (a == 1 && !cvc(k - 1))) k--
            }
            if (b[k] == 'l' && doublec(k) && m() > 1) k--
        }
    }
}
