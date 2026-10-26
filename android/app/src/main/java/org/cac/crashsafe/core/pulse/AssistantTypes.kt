package org.cac.crashsafe.core.pulse

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.ImpactReport
import org.cac.crashsafe.model.CheckInOutcome
import java.time.Instant
import java.time.format.DateTimeFormatter

/** Why the assistant was opened — changes how it greets the driver. */
sealed interface AssistantScenario {
    data object General : AssistantScenario

    /** Driver answered the check-in ("I'm OK") — the conscious path. */
    data class AfterCrash(val outcome: CheckInOutcome) : AssistantScenario
}

/** Everything the assistant may use to tailor answers. Built from the on-device profile. */
data class AssistantContext(
    val userName: String,
    val isOnline: Boolean,
    val scenario: AssistantScenario,
    val carDescription: String,
    val insurer: String,
    val medicalNotes: String,
    val familyContactNames: List<String>,
    val currentTrip: String? = null,
    val responseStyle: String = "practical",
    val jurisdiction: String = "UNKNOWN",
    val assistanceStage: String = "active",
    val incident: AssistantIncident? = null,
    /** What the phone's motion says the driver is doing now (transport mode, recent harsh events). */
    val activity: AssistantActivity? = null,
    /** One per conversation, so Pulse's agent on the backend remembers earlier turns (random, not tied to the person). */
    val conversationID: String? = null,
)

/** Derived from the rolling sensor history by `MotionIntelligence`; no raw telemetry. */
@Serializable
data class AssistantActivity(
    val transport: AssistantIncident.Transport,
    @SerialName("harsh_brakes_10min") val harshBrakes10min: Int,
    @SerialName("harsh_accels_10min") val harshAccels10min: Int,
)

/** The incident packet the backend accepts (snake_case on the wire, as iOS sends it). */
@Serializable
data class AssistantIncident(
    @SerialName("schema_version") val schemaVersion: Int = 1,
    @SerialName("captured_at") val capturedAt: String,
    @SerialName("is_simulated") val isSimulated: Boolean,
    val decision: String,
    val evidence: List<String>,
    val issues: List<String>,
    @SerialName("peak_g") val peakG: Double,
    @SerialName("speed_drop_mps") val speedDropMps: Double? = null,
    val transport: Transport,
    @SerialName("behavior_events") val behaviorEvents: List<BehaviorEvent>? = null,
    val impact: Impact? = null,
) {
    @Serializable
    data class Transport(
        val label: String,
        val basis: String,
        /** Set when `basis` is "model". */
        val probability: Double? = null,
        @SerialName("model_id") val modelId: String? = null,
    )

    /** Matches the backend's behavior event schema (`incident_context.py`). */
    @Serializable
    data class BehaviorEvent(val kind: String, val start: Double, val end: Double, val severity: Double)

    /** Matches `motion_intel.normalize_impact`. */
    @Serializable
    data class Impact(
        @SerialName("peak_g") val peakG: Double,
        @SerialName("pulse_duration_s") val pulseDurationS: Double,
        @SerialName("delta_v_mps") val deltaVMps: Double,
        @SerialName("pre_impact_speed_mps") val preImpactSpeedMps: Double? = null,
        @SerialName("post_impact_speed_mps") val postImpactSpeedMps: Double? = null,
        @SerialName("time_to_stop_s") val timeToStopS: Double? = null,
        @SerialName("stop_basis") val stopBasis: String? = null,
        @SerialName("average_stop_deceleration_g") val averageStopDecelerationG: Double? = null,
        val severity: String,
        @SerialName("is_simulated") val isSimulated: Boolean,
    ) {
        companion object {
            fun of(r: ImpactReport) = Impact(peakG = r.peakG, pulseDurationS = r.pulseDuration, deltaVMps = r.deltaVMPS,
                preImpactSpeedMps = r.preImpactSpeedMPS, postImpactSpeedMps = r.postImpactSpeedMPS,
                timeToStopS = r.timeToStop, stopBasis = r.stopBasis, averageStopDecelerationG = r.averageStopDecelerationG,
                severity = r.severity.name, isSimulated = r.isSimulated)
        }
    }

    companion object {
        fun make(event: CrashEvent): AssistantIncident {
            val assessment = event.assessment
            return AssistantIncident(
                capturedAt = iso8601(event.date),
                isSimulated = event.isSimulated,
                decision = assessment?.decision?.name ?: "inconclusive",
                evidence = assessment?.evidence?.map { it.name } ?: emptyList(),
                issues = assessment?.issues?.map { it.name } ?: emptyList(),
                peakG = event.peakG,
                speedDropMps = assessment?.speedDropMPS,
                transport = Transport(label = assessment?.candidate?.transportationMode?.name ?: "unknown",
                    basis = if (assessment == null) "unknown" else "profile"),
                impact = event.impact?.let { Impact.of(it) })
        }

        /** "2026-10-25T16:40:12Z", as Swift's `ISO8601Format()`. */
        fun iso8601(seconds: Double): String =
            DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(seconds.toLong()))
    }
}
