package org.cac.crashsafe.core.report

import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.CrashSnapshot
import java.util.Locale

/**
 * The facts of a crash in two forms, from what the phone recorded at the time (`CrashSnapshot`):
 * one written for you, and one to text, email or show to the police and your insurer, so your agent has
 * what they need without you having to remember it. Neither copy says who was at fault.
 */
data class ImpactReportFacts(
    val snapshot: CrashSnapshot,
    val outcome: CheckInOutcome,
    val driverName: String,
    val vehicle: String?,
    val insurer: String,
    val policyNumber: String,
    val claimsPhone: String,
    val otherDriver: String = "",
    val otherInsurance: String = "",
    val otherPlate: String = "",
    val policeReportNumber: String = "",
    /** Blood type and medical notes, only when the driver chooses to add them (e.g. for a medical claim). */
    val medical: String? = null,
) {
    val whenText: String get() = Formats.reportDateTime(snapshot.date)

    val whereText: String
        get() {
            val address = listOfNotNull(snapshot.street, snapshot.place).filter { it.isNotEmpty() }.joinToString(", ")
            val lat = snapshot.latitude
            val lon = snapshot.longitude
            val coordinates = if (lat != null && lon != null) String.format(Locale.US, "%.5f, %.5f", lat, lon) else null
            val accuracy = snapshot.accuracyMeters?.let { " ±${it.roundToIntHalfAway()} m" } ?: ""
            return when {
                address.isNotEmpty() && coordinates != null -> "$address ($coordinates$accuracy)"
                address.isNotEmpty() -> address
                coordinates != null -> coordinates + accuracy
                else -> "Not recorded"
            }
        }

    // For you

    val headline: String
        get() {
            val severity = snapshot.impact?.severity?.label ?: "Possible"
            return "$severity impact · ${Formats.time(snapshot.date)}"
        }

    /** What the phone felt, in everyday words. */
    val whatHappened: List<String>
        get() {
            val lines = mutableListOf<String>()
            val impact = snapshot.impact
            if (impact != null) {
                lines.add("Your car's speed changed by about ${impact.deltaVMPH.roundToIntHalfAway()} mph in a split second (about ${String.format(Locale.US, "%.2f", impact.pulseDuration)} s).")
                lines.add("At its peak the force was about ${impact.peakG.roundToIntHalfAway()} times the pull of gravity, for an instant.")
                impact.preImpactSpeedMPH?.let { lines.add("You were going about ${it.roundToIntHalfAway()} mph just before.") }
                impact.timeToStop?.let { lines.add(String.format(Locale.US, "The car came to a stop about %.1f seconds later.", it)) }
            } else {
                lines.add("Your phone felt a sudden jolt of about ${snapshot.peakG.roundToIntHalfAway()} times the pull of gravity.")
                snapshot.speedDropMPH?.let { lines.add("Your speed dropped by about ${it.roundToIntHalfAway()} mph.") }
            }
            if (snapshot.isSimulated) lines.add("This was a test crash with simulated data.")
            return lines
        }

    // For police and insurer

    val officialText: String
        get() {
            val lines = mutableListOf("COLLISION FACTS, RECORDED BY PHONE" + if (snapshot.isSimulated) " (TEST, SIMULATED DATA)" else "", "",
                "Date and time: $whenText", "Location: $whereText")
            snapshot.weather?.let { lines.add("Conditions: $it") }
            lines.add("Driver: ${driverName.ifEmpty { "Not given" }}")
            if (!vehicle.isNullOrEmpty()) lines.add("Vehicle: $vehicle")
            val insurance = listOfNotNull(insurer, if (policyNumber.isEmpty()) null else "Policy $policyNumber",
                if (claimsPhone.isEmpty()) null else "Claims $claimsPhone").filter { it.isNotEmpty() }
            if (insurance.isNotEmpty()) lines.add("Insurance: " + insurance.joinToString(" · "))
            lines.add("Impact measured by phone sensors: $impactLine")
            lines.add("Driver check-in: ${outcome.reportLabel} (${Formats.time(snapshot.date)})")
            if (otherDriver.isNotEmpty()) lines.add("Other driver: $otherDriver")
            if (otherInsurance.isNotEmpty()) lines.add("Other driver's insurance: $otherInsurance")
            if (otherPlate.isNotEmpty()) lines.add("Other vehicle plate: $otherPlate")
            if (policeReportNumber.isNotEmpty()) lines.add("Police report number: $policeReportNumber")
            if (!medical.isNullOrEmpty()) lines.add("Medical: $medical")
            lines += listOf("", disclaimer)
            return lines.joinToString("\n")
        }

    private val impactLine: String
        get() {
            val impact = snapshot.impact
                ?: return String.format(Locale.US, "peak %.1f g", snapshot.peakG) +
                    (snapshot.speedDropMPH?.let { ", speed drop about ${it.roundToIntHalfAway()} mph (GPS)" } ?: "")
            val parts = mutableListOf(impact.severity.label.lowercase(), String.format(Locale.US, "peak %.1f g", impact.peakG),
                "speed change about ${impact.deltaVMPH.roundToIntHalfAway()} mph over ${(impact.pulseDuration * 1000).roundToIntHalfAway()} ms")
            impact.preImpactSpeedMPH?.let { parts.add("speed before about ${it.roundToIntHalfAway()} mph (GPS)") }
            impact.timeToStop?.let { parts.add(String.format(Locale.US, "stopped %.1f s later", it)) }
            return parts.joinToString(", ")
        }

    companion object {
        const val disclaimer = "Sensor values are estimates from a phone in the vehicle. They are not a crash reconstruction and do not show fault or injury."

        const val lookAfterYourself = "Some injuries, like whiplash or a concussion, can show up hours or days later. Get checked if you notice neck or back pain, a headache, dizziness, confusion or numbness, and keep this report with your visit records for a medical claim."

        val nextSteps = listOf(
            "Photograph the cars, plates and the scene from a safe spot.",
            "Swap names, phone numbers, plates and insurance with the other driver.",
            "Stick to what you saw. Don't guess, and don't argue about fault.",
            "Send the police & insurer copy to your agent so they can take it from here.",
        )
    }
}
