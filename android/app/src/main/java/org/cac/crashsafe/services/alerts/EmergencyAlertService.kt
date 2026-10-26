package org.cac.crashsafe.services.alerts

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.services.keys.PulseBackend
import org.cac.crashsafe.services.keys.appending
import org.cac.crashsafe.services.net.Http

data class AlertRecipient(val name: String, val phone: String)

enum class AlertDelivery {
    sent,
    /** No signal — will be sent when the phone reconnects. */
    queued,
    /** The server ran without a texting/calling provider (or this was a test crash): nothing was sent. */
    dryRun,
}

/**
 * Notifies family contacts after a crash (unconscious path, or "I need help").
 *
 * Phones can't send texts silently on the driver's behalf, so the real version goes through our backend
 * when online. The phone itself starts the 911 call.
 */
interface EmergencyAlertService {
    suspend fun alertFamily(recipients: List<AlertRecipient>, outcome: CheckInOutcome, event: CrashEvent, isOnline: Boolean): AlertDelivery
}

/** Pretends to send; reports `queued` when offline. */
class MockEmergencyAlertService : EmergencyAlertService {
    override suspend fun alertFamily(recipients: List<AlertRecipient>, outcome: CheckInOutcome, event: CrashEvent, isOnline: Boolean): AlertDelivery {
        delay(1000)
        return if (isOnline) AlertDelivery.sent else AlertDelivery.queued
    }
}

/**
 * Sends the family alert through the CrashSafe backend (`POST /v1/alerts`), which texts each
 * contact and places an automated call that reads the message (Twilio when configured; a dry run
 * otherwise). The server never calls 911 — the phone starts that call itself.
 */
class BackendEmergencyAlertService(
    private val endpoint: HttpUrl?,
    private val driverName: () -> String,
    private val location: () -> Pair<Double, Double>?,
) : EmergencyAlertService {
    @Serializable
    private data class Body(
        @SerialName("is_simulated") val isSimulated: Boolean,
        val outcome: String,
        @SerialName("driver_name") val driverName: String,
        val recipients: List<Recipient>,
        val location: Location?,
        val impact: AssistantIncident.Impact?,
    ) {
        @Serializable
        data class Recipient(val name: String, val phone: String)

        @Serializable
        data class Location(val lat: Double, val lon: Double)
    }

    @Serializable
    private data class Response(val delivery: String)

    override suspend fun alertFamily(recipients: List<AlertRecipient>, outcome: CheckInOutcome, event: CrashEvent, isOnline: Boolean): AlertDelivery {
        val endpoint = endpoint
        if (!isOnline || endpoint == null || recipients.isEmpty() || outcome == CheckInOutcome.ok) return AlertDelivery.queued
        val here = location()
        val body = Body(isSimulated = event.isSimulated, outcome = outcome.name, driverName = driverName(),
            recipients = recipients.take(5).map { Body.Recipient(it.name, it.phone) },
            location = here?.let { Body.Location(it.first, it.second) },
            impact = event.impact?.let { AssistantIncident.Impact.of(it) })
        return try {
            val request = PulseBackend.authorize(Request.Builder().url(endpoint.appending("v1/alerts")))
                .post(Http.jsonBody(Http.json.encodeToString(Body.serializer(), body))).build()
            val result = Http.send(request, Http.client(10.0))
            if (!result.isOK) return AlertDelivery.queued
            when (Http.json.decodeFromString(Response.serializer(), result.text).delivery) {
                "sent", "partial" -> AlertDelivery.sent
                "dry_run" -> AlertDelivery.dryRun
                else -> AlertDelivery.queued
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AlertDelivery.queued
        }
    }

    companion object {
        /** Same server as Pulse. */
        fun configured(driverName: () -> String, location: () -> Pair<Double, Double>?) =
            BackendEmergencyAlertService(PulseBackend.endpoint(), driverName, location)
    }
}
