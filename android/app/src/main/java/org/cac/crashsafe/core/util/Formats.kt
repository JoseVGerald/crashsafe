package org.cac.crashsafe.core.util

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

/** Date and number formatting that matches the iOS app's wording. */
object Formats {
    private fun zoned(seconds: Double) = Instant.ofEpochMilli((seconds * 1000).toLong()).atZone(ZoneId.systemDefault())

    /** "4:40 PM". */
    fun time(seconds: Double): String = DateTimeFormatter.ofPattern("h:mm a", Locale.US).format(zoned(seconds))

    /** "Sat, Oct 25, 2026, 4:40 PM PDT" (the report's date and time). */
    fun reportDateTime(seconds: Double): String =
        DateTimeFormatter.ofPattern("EEE, MMM d, yyyy, h:mm a z", Locale.US).format(zoned(seconds))

    /** "Oct 22, 2026 · 9:13 AM" (date fields). */
    fun dateAndTime(seconds: Double): String =
        DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).format(zoned(seconds)) + " · " + time(seconds)

    /** "Oct 22, 9:13 AM". */
    fun monthDayTime(seconds: Double): String = DateTimeFormatter.ofPattern("MMM d, h:mm a", Locale.US).format(zoned(seconds))

    /** "Oct 22". */
    fun monthDay(seconds: Double): String = DateTimeFormatter.ofPattern("MMM d", Locale.US).format(zoned(seconds))

    /** "Oct 22, 2026, 9:13 AM". */
    fun abbreviatedDateTime(seconds: Double): String =
        DateTimeFormatter.ofPattern("MMM d, yyyy, h:mm a", Locale.US).format(zoned(seconds))

    /** "5 hours ago", "yesterday", "in 2 days" (Swift's `.relative(presentation: .named)`). */
    fun relative(seconds: Double, now: Double = nowSeconds()): String {
        val delta = seconds - now
        val past = delta < 0
        val s = abs(delta)
        fun phrase(n: Long, unit: String) = if (past) "$n $unit${if (n == 1L) "" else "s"} ago" else "in $n $unit${if (n == 1L) "" else "s"}"
        return when {
            s < 60 -> "now"
            s < 3600 -> phrase((s / 60).toLong(), "minute")
            s < 86_400 -> phrase((s / 3600).toLong(), "hour")
            s < 2 * 86_400 -> if (past) "yesterday" else "tomorrow"
            s < 7 * 86_400 -> phrase((s / 86_400).toLong(), "day")
            s < 30 * 86_400 -> if ((s / (7 * 86_400)).toLong() == 1L) (if (past) "last week" else "next week") else phrase((s / (7 * 86_400)).toLong(), "week")
            else -> phrase((s / (30 * 86_400)).toLong(), "month")
        }
    }

    /** Hour of day, 0–23, in the phone's time zone. */
    fun hour(seconds: Double = nowSeconds()): Int = zoned(seconds).hour
}

object PhoneFormat {
    /** "2065550100" → "(206) 555-0100"; other formats are returned unchanged. */
    fun display(raw: String): String {
        var digits = raw.filter { it.isDigit() }
        if (digits.length == 11 && digits.startsWith("1")) digits = digits.drop(1)
        if (digits.length != 10 || (raw.contains("+") && !raw.startsWith("+1"))) return raw
        return "(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6, 10)}"
    }

    /** Digits and a leading +, for a tel: link. */
    fun dialable(raw: String): String = raw.filter { it.isDigit() || it == '+' }
}

/** Pure validation rules, shared by sign-in, sign-up and the editors (and unit tested). */
object Validation {
    fun name(value: String): String? = if (value.trim().isEmpty()) "Enter your name." else null

    fun email(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return "Enter your email."
        val pattern = Regex("^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$")
        return if (!pattern.matches(trimmed)) "Enter a valid email address." else null
    }

    fun newPassword(value: String): String? {
        if (value.isEmpty()) return "Choose a password."
        return if (value.length < 8) "Use at least 8 characters." else null
    }

    fun confirmation(value: String, password: String): String? {
        if (value.isEmpty()) return "Re-enter your password."
        return if (value != password) "Passwords don't match." else null
    }

    fun phone(value: String): String? {
        val digits = value.filter { it.isDigit() }
        if (digits.isEmpty()) return "Enter a phone number."
        return if (digits.length < 7) "That phone number looks too short." else null
    }

    /** Four-segment password strength, 0…4. */
    fun passwordScore(password: String): Int {
        if (password.isEmpty()) return 0
        var score = if (password.length >= 8) 1 else 0
        if (password.length >= 12) score += 1
        if (password.any { it.isUpperCase() } && password.any { it.isLowerCase() }) score += 1
        if (password.any { it.isDigit() } || password.any { !it.isLetter() && !it.isDigit() }) score += 1
        return minOf(score, 4)
    }
}
