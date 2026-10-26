package org.cac.crashsafe.services.driving

import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.roads.RoadDefaults
import org.cac.crashsafe.core.roads.RoadKind
import org.cac.crashsafe.core.roads.RoadMatcher
import org.cac.crashsafe.core.roads.RoadSegment
import org.cac.crashsafe.core.roads.RoadWay
import org.cac.crashsafe.core.roads.SpeedLimitReading
import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.core.util.roundedHalfAway
import org.cac.crashsafe.services.net.Http
import java.io.File
import java.util.Locale
import kotlin.math.min
import kotlin.math.pow

/**
 * The posted (or typical) speed limit where the car is, kept current from GPS.
 *
 * Two layers, so a limit shows within a second of the first GPS fix:
 * - Road data for the ~1 km around the car (OpenStreetMap via Overpass, or the trip pack), kept on disk
 *   and matched locally: works offline and costs nothing per fix, but a new area takes 30–60 s to arrive,
 *   many US roads have no posted limit in it, and matching one GPS point can pick a road beside the car.
 * - A quick lookup of just the road the car is on, matched along its last few GPS points
 *   (`QuickSpeedLimitSource`, < 1 s). With a TomTom key it is the main source the whole drive and the
 *   local match only fills in when TomTom can't be reached; without one (Valhalla) it covers the wait.
 *
 * Privacy: the area lookup sends a position rounded to ~100 m; the quick lookup sends the last few
 * GPS points rounded to ~11 m. Neither sends anything that identifies the driver.
 */
class SpeedLimitService(
    private val scope: CoroutineScope,
    private val source: RoadDataSource = FallbackRoadSource.standard(),
    private val quick: QuickSpeedLimitSource? = FallbackQuickSource.standard(),
    private val store: RoadAreaStore? = null,
    private val defaults: RoadDefaults? = null,
) {
    enum class Status { idle, loading, ready, failed }

    data class Area(val lat: Double, val lon: Double, val ways: List<RoadWay>)

    var current by mutableStateOf<SpeedLimitReading?>(null)
        private set
    var status by mutableStateOf(Status.idle)
        private set
    var roadsLoaded by mutableIntStateOf(0)
        private set
    /** Seconds from a drive's first GPS fix to its first limit, and where that limit came from. */
    var firstLimit by mutableStateOf<Pair<Double, String>?>(null)
        private set

    private var cache: Area? = null
    /** Roads saved with the active trip's pack (work with no signal). */
    private var offline: List<RoadWay> = emptyList()
    private var fetching = false
    private var retryAfter = 0.0
    private var failures = 0
    private var lastFix: LocationSample? = null
    private var heading: Double? = null
    /** Recent fixes at least 6 m apart: the trace the quick lookup matches. */
    private val trail = mutableListOf<LocationSample>()
    private var quickReading: Triple<SpeedLimitReading, Double, Double>? = null
    private var quickInFlight = false
    private var quickAfter = 0.0
    private var firstFixAt: Double? = null
    /** "US-OR"-style region of the car, for that region's legal default limits on untagged roads. */
    var regionCode: () -> String? = { null }

    /** Roads downloaded with the trip pack for the drive that's starting (empty for a quick drive). */
    fun setOfflineRoads(roads: List<RoadWay>) {
        offline = roads
        roadsLoaded = (cache?.ways?.size ?: 0) + roads.size
        if (roads.isNotEmpty() && status == Status.idle) status = Status.ready
    }

    /**
     * Starts loading the roads around a position before a drive needs them (the app does this as soon
     * as it knows where the phone is, so "Start drive" usually finds them already on the phone).
     */
    fun prefetch(lat: Double, lon: Double) {
        val fix = LocationSample(uptime = SystemClock.elapsedRealtimeNanos() / 1e9, date = nowSeconds(), latitude = lat, longitude = lon,
            horizontalAccuracy = 10.0, speedMPS = -1.0, speedAccuracy = -1.0)
        if (!fix.isValid) return
        cache?.let { if (covers(it, fix)) return }
        scope.launch {
            val saved = store?.area(fix, RADIUS - REFETCH_MARGIN)
            if (saved != null) useArea(saved) else fetch(fix.latitude, fix.longitude)
        }
    }

    /** A new drive: forget the last drive's position and limit (road data stays). */
    fun startDrive() {
        current = null
        lastFix = null
        heading = null
        trail.clear()
        quickReading = null
        firstFixAt = null
        firstLimit = null
    }

    private fun match(fix: LocationSample): SpeedLimitReading? =
        RoadMatcher.match(fix.latitude, fix.longitude, heading, (cache?.ways ?: emptyList()) + offline)

    /** Feed every GPS fix. Matching is local and instant; the network is only used for a new area. */
    fun observe(fix: LocationSample) {
        if (!fix.isValid || fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > 60) return
        if (firstFixAt == null) firstFixAt = nowSeconds()
        val last = lastFix
        if (last != null) {
            val moved = TransportFeatures.haversine(last.latitude, last.longitude, fix.latitude, fix.longitude)
            if (moved >= 6) {
                heading = RoadMatcher.bearing(last.latitude, last.longitude, fix.latitude, fix.longitude)
                lastFix = fix
                trail.add(fix)
                if (trail.size > 5) trail.removeAt(0)
            }
        } else {
            lastFix = fix
            trail.clear()
            trail.add(fix)
        }
        val cached = cache
        if (cached == null || !covers(cached, fix)) {
            store?.areaInMemory(fix, RADIUS - REFETCH_MARGIN)?.let { useArea(it) }
        }
        val hasRoadData = (cache?.let { covers(it, fix) } ?: false) || offline.isNotEmpty()
        val primary = quick?.isPrimary == true
        val quickHere = quickReading?.let { (reading, lat, lon) ->
            if (TransportFeatures.haversine(lat, lon, fix.latitude, fix.longitude) <= validity(reading)) reading else null
        }
        val local = match(fix)
        when {
            primary && quickHere != null -> show(quickHere, quick?.label ?: "quick lookup")
            local != null -> show(local, "road data")
            quickHere != null -> show(quickHere, quick?.label ?: "quick lookup")
            else -> current = null
        }
        if (primary) lookUpQuickly(fix)
        if (!(cache?.let { covers(it, fix) } ?: false)) {
            if (!primary && local == null) lookUpQuickly(fix)
            if (!(current != null && hasRoadData)) fetch(fix.latitude, fix.longitude)
        }
    }

    fun reset() = startDrive()

    private fun show(reading: SpeedLimitReading, basis: String) {
        var shown = reading
        if (shown.segment == null) shown = shown.copy(segment = RoadSegment.classify(shown.highway, if (shown.isPosted) shown.mph else null))
        // An untagged road gets the legal default where the car is (e.g. 25 mph on an Oregon residential street).
        val segment = shown.segment
        if (!shown.isPosted && segment != null) {
            defaults?.typicalMPH(segment, regionCode())?.let { shown = shown.copy(mph = it) }
        }
        current = shown
        if (status != Status.ready) status = Status.ready
        val since = firstFixAt
        if (firstLimit == null && since != null) {
            val seconds = nowSeconds() - since
            firstLimit = seconds to basis
            Log.i(TAG, String.format(Locale.US, "first speed limit after %.1f s from %s", seconds, basis))
        }
    }

    private fun useArea(area: Area) {
        cache = area
        roadsLoaded = area.ways.size + offline.size
        status = Status.ready
    }

    private fun covers(area: Area, fix: LocationSample): Boolean =
        TransportFeatures.haversine(area.lat, area.lon, fix.latitude, fix.longitude) < RADIUS - REFETCH_MARGIN

    /**
     * The road the car is on, from the quick source: all drive for a primary source (TomTom), otherwise
     * while the area's road data is still on its way.
     */
    private fun lookUpQuickly(fix: LocationSample) {
        val quick = quick ?: return
        if (quickInFlight || nowSeconds() < quickAfter) return
        quickReading?.let { (reading, lat, lon) ->
            val spacing = if (reading.environment == RoadKind.highway) QUICK_HIGHWAY_SPACING else QUICK_SPACING
            if (TransportFeatures.haversine(lat, lon, fix.latitude, fix.longitude) < spacing) return
        }
        quickInFlight = true
        if (current == null && status != Status.ready) status = Status.loading
        val points = trail.map { it.latitude to it.longitude }.toMutableList()
        if (trail.lastOrNull() != fix) points.add(fix.latitude to fix.longitude)
        val started = nowSeconds()
        scope.launch {
            try {
                val reading = quick.speedLimit(points)
                Log.d(TAG, "quick lookup: ${reading?.let { "${it.mph.toInt()} mph" } ?: "no road"} in ${nowSeconds() - started} s")
                quickAfter = nowSeconds() + QUICK_INTERVAL
                if (reading != null) {
                    quickReading = Triple(reading, fix.latitude, fix.longitude)
                    // Road data that arrived meanwhile wins (unless this source is primary); a reading for where the
                    // car no longer is doesn't count.
                    val last = lastFix ?: fix
                    if ((quick.isPrimary || match(last) == null) &&
                        TransportFeatures.haversine(fix.latitude, fix.longitude, last.latitude, last.longitude) <= validity(reading)) {
                        show(reading, quick.label)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.d(TAG, "quick lookup failed: ${e.message}")
                quickAfter = nowSeconds() + 10
            } finally {
                quickInFlight = false
            }
        }
    }

    private fun fetch(lat: Double, lon: Double) {
        if (fetching || nowSeconds() < retryAfter) return
        fetching = true
        if (cache == null && current == null) status = Status.loading
        // ~100 m rounding: enough for a 1 km area, less precise than the car's real position.
        val roundedLat = (lat * 1000).roundedHalfAway() / 1000
        val roundedLon = (lon * 1000).roundedHalfAway() / 1000
        val started = nowSeconds()
        scope.launch {
            try {
                val ways = source.roads(roundedLat, roundedLon, RADIUS)
                Log.d(TAG, "roads: ${ways.size} in ${nowSeconds() - started} s")
                useArea(Area(roundedLat, roundedLon, ways))
                failures = 0
                store?.save(roundedLat, roundedLon, ways)
                lastFix?.let { last -> match(last)?.let { show(it, "road data") } }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.d(TAG, "roads failed after ${nowSeconds() - started} s: ${e.message}")
                if (cache == null && current == null) status = Status.failed
                // Back off while the public servers struggle: 20 s, 40 s, 80 s… up to 5 min.
                failures++
                retryAfter = nowSeconds() + min(300.0, 20 * 2.0.pow(failures - 1))
            } finally {
                fetching = false
            }
        }
    }

    private fun validity(reading: SpeedLimitReading): Double =
        if (reading.environment == RoadKind.highway) QUICK_HIGHWAY_VALIDITY else QUICK_VALIDITY

    companion object {
        private const val TAG = "CrashSafe.speedlimits"
        /** Area fetched around the car; refetched when it gets within `REFETCH_MARGIN` of the edge. */
        const val RADIUS = 1_000.0
        const val REFETCH_MARGIN = 400.0
        /**
         * A quick reading is used this far from where it was looked up, and refreshed after this far
         * (further apart on highways, where the limit rarely changes).
         */
        const val QUICK_VALIDITY = 250.0
        const val QUICK_SPACING = 120.0
        const val QUICK_HIGHWAY_SPACING = 400.0
        const val QUICK_HIGHWAY_VALIDITY = 600.0
        /** At most one quick lookup per this many seconds (the server's fair use is one per second). */
        const val QUICK_INTERVAL = 3.0
    }
}

/**
 * The last few road areas fetched, kept on disk so a regular route works without waiting on the network.
 * Only road data is stored (no trace of where or when the car was).
 */
class RoadAreaStore(private val directory: File, private val keep: Int = 40) {
    /** Areas read from disk, so each GPS fix doesn't reread files. */
    private var loaded: List<SpeedLimitService.Area>? = null

    suspend fun area(fix: LocationSample, radius: Double): SpeedLimitService.Area? = withContext(Dispatchers.IO) {
        all().firstOrNull { TransportFeatures.haversine(it.lat, it.lon, fix.latitude, fix.longitude) < radius }
    }

    /** Reads the saved areas into memory (once, at launch), so GPS fixes can be matched against them. */
    suspend fun preload() = withContext(Dispatchers.IO) { all() }

    /** From what's already in memory (call `area` once first to read the disk). */
    fun areaInMemory(fix: LocationSample, radius: Double): SpeedLimitService.Area? =
        loaded?.firstOrNull { TransportFeatures.haversine(it.lat, it.lon, fix.latitude, fix.longitude) < radius }

    @Synchronized
    private fun all(): List<SpeedLimitService.Area> {
        loaded?.let { return it }
        val files = directory.listFiles { file -> file.extension == "json" } ?: emptyArray()
        val areas = files.mapNotNull { file ->
            val parts = file.nameWithoutExtension.split("_").mapNotNull { it.toDoubleOrNull() }
            if (parts.size != 2) return@mapNotNull null
            val ways = runCatching { Http.json.decodeFromString(roadWaysSerializer, file.readText()) }.getOrNull() ?: return@mapNotNull null
            SpeedLimitService.Area(parts[0], parts[1], ways)
        }
        loaded = areas
        return areas
    }

    suspend fun save(lat: Double, lon: Double, ways: List<RoadWay>) = withContext(Dispatchers.IO) {
        directory.mkdirs()
        val file = File(directory, String.format(Locale.US, "%.3f_%.3f.json", lat, lon))
        runCatching { file.writeText(Http.json.encodeToString(roadWaysSerializer, ways)) }
        synchronized(this@RoadAreaStore) {
            loaded = (listOf(SpeedLimitService.Area(lat, lon, ways)) + (loaded ?: emptyList()).filter { it.lat != lat || it.lon != lon })
        }
        // Oldest first out.
        val files = (directory.listFiles() ?: emptyArray()).sortedByDescending { it.lastModified() }
        files.drop(keep).forEach { it.delete() }
    }
}
