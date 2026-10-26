package org.cac.crashsafe.services.location

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.cac.crashsafe.app.PermissionCenter
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.services.sensors.LocationSampleSource
import java.util.UUID

/** Something that can ask the system to wake the app when the phone starts a drive. */
interface DriveWakeupSource {
    fun setDriveWakeups(enabled: Boolean)
}

/** A position the app shows (the device's last fix, reduced to what screens need). */
data class Here(val latitude: Double, val longitude: Double, val horizontalAccuracy: Double)

/**
 * The device's live location + a short place name ("Seattle, WA"), from Android's location providers — never a
 * hard-coded default. Shared by Home, the trip planner, the post-crash help hub and the driving monitor.
 */
class LocationService(
    private val context: Context,
    private val permissions: PermissionCenter,
    private val scope: CoroutineScope,
) : LocationSampleSource, DriveWakeupSource {
    var location by mutableStateOf<Here?>(null)
        private set
    var placeName by mutableStateOf<String?>(null)
        private set
    var streetName by mutableStateOf<String?>(null)
        private set
    /** "US-OR", "DE"…: picks the legal default speed limits for untagged roads. */
    var regionCode: String? = null
        private set

    /** Called to keep a foreground service alive while background updates are needed (set by the environment). */
    var backgroundUpdates: (Boolean) -> Unit = {}

    private val manager = context.getSystemService(LocationManager::class.java)
    private val sampleObservers = linkedMapOf<UUID, (LocationSample) -> Unit>()
    private var lastGeocoded: Here? = null
    private var listening = false
    private var wantsDriveWakeups = false

    private val listener = object : LocationListener {
        override fun onLocationChanged(fix: Location) = receive(listOf(fix))
        override fun onLocationChanged(locations: MutableList<Location>) = receive(locations)
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    val isAuthorized: Boolean get() = permissions.locationGranted
    override val isDenied: Boolean get() = permissions.locationDenied
    /** "Allow all the time" lets the app notice drives that start while CrashSafe is closed. */
    val hasAlwaysAccess: Boolean get() = permissions.backgroundLocationGranted
    val canPromptForAlways: Boolean get() = !hasAlwaysAccess && (!isAuthorized || permissions.canPromptForBackground)

    fun requestPermission() {
        if (isAuthorized) {
            start()
            return
        }
        scope.launch {
            if (permissions.requestLocation()) start()
        }
    }

    /** Asks for "Allow all the time". Returns false when no prompt can be shown, so the caller should open Settings. */
    fun requestAlwaysPermission(): Boolean {
        if (hasAlwaysAccess) return true
        if (!canPromptForAlways) return false
        scope.launch {
            permissions.requestBackgroundLocation()
            refreshAuthorization()
        }
        return true
    }

    /** Re-reads the permission (e.g. after returning from Settings) and resumes live updates. */
    fun refreshAuthorization() {
        permissions.refresh()
        if (isAuthorized) start()
    }

    override fun setDriveWakeups(enabled: Boolean) {
        wantsDriveWakeups = enabled
    }

    @SuppressLint("MissingPermission")
    override fun start() {
        if (!isAuthorized || listening || manager == null) return
        val providers = buildList {
            if (Build.VERSION.SDK_INT >= 31 && manager.hasProvider(LocationManager.FUSED_PROVIDER)) {
                add(LocationManager.FUSED_PROVIDER)
            } else {
                if (manager.allProviders.contains(LocationManager.GPS_PROVIDER)) add(LocationManager.GPS_PROVIDER)
                if (manager.allProviders.contains(LocationManager.NETWORK_PROVIDER)) add(LocationManager.NETWORK_PROVIDER)
            }
        }
        if (providers.isEmpty()) return
        for (provider in providers) {
            runCatching { manager.requestLocationUpdates(provider, 1000L, 0f, listener, Looper.getMainLooper()) }
                .onFailure { Log.w(TAG, "location updates from $provider failed", it) }
            if (location == null) runCatching { manager.getLastKnownLocation(provider) }.getOrNull()?.let { last ->
                location = Here(last.latitude, last.longitude, if (last.hasAccuracy()) last.accuracy.toDouble() else -1.0)
                geocodeIfMoved(location!!)
            }
        }
        listening = true
    }

    fun stop() {
        manager?.removeUpdates(listener)
        listening = false
    }

    override fun addSampleObserver(receive: (LocationSample) -> Unit): UUID {
        val id = UUID.randomUUID()
        sampleObservers[id] = receive
        return id
    }

    override fun removeSampleObserver(id: UUID) {
        sampleObservers.remove(id)
    }

    /** Keeps updates flowing with the screen off (Android: a location foreground service). */
    override fun setBackgroundUpdates(enabled: Boolean) = backgroundUpdates(enabled)

    private fun receive(fixes: List<Location>) {
        val latest = fixes.lastOrNull() ?: return
        location = Here(latest.latitude, latest.longitude, if (latest.hasAccuracy()) latest.accuracy.toDouble() else -1.0)
        // Quality only, never coordinates.
        Log.d(TAG, "fix speed=${latest.speed} hAcc=${latest.accuracy} provider=${latest.provider}")
        // Measurement timestamps are kept (batched fixes too); old GPS is never re-stamped as fresh.
        for (fix in fixes.sortedBy { it.elapsedRealtimeNanos }) {
            val speedAccuracy = if (Build.VERSION.SDK_INT >= 26 && fix.hasSpeedAccuracy()) fix.speedAccuracyMetersPerSecond.toDouble() else -1.0
            val sample = LocationSample(
                uptime = if (fix.elapsedRealtimeNanos > 0) fix.elapsedRealtimeNanos / 1e9 else SystemClock.elapsedRealtimeNanos() / 1e9,
                date = fix.time / 1000.0,
                latitude = fix.latitude, longitude = fix.longitude,
                horizontalAccuracy = if (fix.hasAccuracy()) fix.accuracy.toDouble() else -1.0,
                speedMPS = if (fix.hasSpeed()) fix.speed.toDouble() else -1.0,
                speedAccuracy = speedAccuracy)
            for (observer in sampleObservers.values.toList()) observer(sample)
        }
        geocodeIfMoved(location!!)
    }

    private fun geocodeIfMoved(here: Here) {
        val last = lastGeocoded
        if (last != null && TransportFeatures.haversine(last.latitude, last.longitude, here.latitude, here.longitude) <= 400) return
        lastGeocoded = here
        scope.launch {
            val place = Geocoding.describe(context, here.latitude, here.longitude) ?: return@launch
            placeName = place.shortName
            streetName = place.street
            place.regionCode?.let { regionCode = it }
        }
    }

    companion object {
        private const val TAG = "CrashSafe.location"

        /** One-off reverse geocode for a picked coordinate: a title and a short place name. */
        suspend fun describe(context: Context, lat: Double, lon: Double): Pair<String, String> {
            val place = Geocoding.describe(context, lat, lon)
                ?: return "Dropped pin" to String.format(java.util.Locale.US, "%.4f, %.4f", lat, lon)
            return (place.title ?: "Dropped pin") to (place.shortName ?: "")
        }
    }
}
