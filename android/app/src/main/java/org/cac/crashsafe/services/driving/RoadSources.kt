package org.cac.crashsafe.services.driving

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.roads.RoadMatcher
import org.cac.crashsafe.core.roads.RoadWay
import org.cac.crashsafe.core.roads.SpeedLimitReading
import org.cac.crashsafe.core.util.roundedHalfAway
import org.cac.crashsafe.services.keys.PulseBackend
import org.cac.crashsafe.services.keys.PulseKeys
import org.cac.crashsafe.services.keys.appending
import org.cac.crashsafe.services.net.Http
import java.io.IOException
import java.net.URLEncoder
import java.util.Locale

/** Fetches the roads around the car (OpenStreetMap, via the free Overpass API). */
interface RoadDataSource {
    suspend fun roads(lat: Double, lon: Double, radiusMeters: Double): List<RoadWay>
    /** Roads within `radiusMeters` of a path (Overpass `around` with a polyline). */
    suspend fun roads(path: List<Pair<Double, Double>>, radiusMeters: Double): List<RoadWay>
}

/**
 * One public Overpass server. No key; please keep requests infrequent (the service fetches an area
 * once, keeps it on disk, and reuses it until the car leaves it).
 */
class OverpassRoadSource(private val server: String, private val timeoutSeconds: Double = 90.0) : RoadDataSource {
    override suspend fun roads(lat: Double, lon: Double, radiusMeters: Double): List<RoadWay> =
        run("[out:json][timeout:80];way(around:${radiusMeters.toInt()},${fmt4(lat)},${fmt4(lon)})" +
            "[highway~\"${RoadMatcher.highwayPattern}\"];out tags geom qt;")

    override suspend fun roads(path: List<Pair<Double, Double>>, radiusMeters: Double): List<RoadWay> {
        if (path.isEmpty()) return emptyList()
        val line = path.joinToString(",") { String.format(Locale.US, "%.5f,%.5f", it.first, it.second) }
        return run("[out:json][timeout:90];way(around:${radiusMeters.toInt()},$line)" +
            "[highway~\"${RoadMatcher.highwayPattern}\"];out tags geom qt;")
    }

    private suspend fun run(query: String): List<RoadWay> {
        val request = Request.Builder().url(server)
            .post(Http.formBody("data=" + URLEncoder.encode(query, "UTF-8")))
            .build()
        val result = Http.send(request, Http.client(timeoutSeconds), maxBytes = 30_000_000)
        if (!result.isOK) throw IOException("Overpass ${result.status}")
        // A 1 km area is about a megabyte of JSON; Http.send already runs off the main thread.
        return RoadMatcher.decodeOverpass(result.text)
    }

    companion object {
        val servers = listOf(
            "https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
        )

        /** All the public mirrors at once; the first to answer wins. */
        fun mirrors() = RacingRoadSource(servers.map { OverpassRoadSource(it) })

        private fun fmt4(x: Double) = String.format(Locale.US, "%.4f", x)
    }
}

/**
 * Asks every source at once and takes the first one that returns roads. The public servers are often
 * slow or down, and trying them one after another (with long timeouts) used to take minutes.
 */
class RacingRoadSource(private val sources: List<RoadDataSource>) : RoadDataSource {
    override suspend fun roads(lat: Double, lon: Double, radiusMeters: Double) = race { it.roads(lat, lon, radiusMeters) }

    override suspend fun roads(path: List<Pair<Double, Double>>, radiusMeters: Double) = race { it.roads(path, radiusMeters) }

    private suspend fun race(body: suspend (RoadDataSource) -> List<RoadWay>): List<RoadWay> = coroutineScope {
        val pending = sources.map { source -> async { runCatching { body(source) } } }.toMutableList()
        var lastError: Throwable = IOException("no road source")
        var answeredEmpty = false
        while (pending.isNotEmpty()) {
            val (done, result) = select {
                pending.forEach { deferred -> deferred.onAwait { deferred to it } }
            }
            pending.remove(done)
            val ways = result.getOrNull()
            if (ways != null && ways.isNotEmpty()) {
                pending.forEach { it.cancel() }
                return@coroutineScope ways
            }
            if (ways != null) answeredEmpty = true
            result.exceptionOrNull()?.let { if (it is CancellationException) throw it else lastError = it }
        }
        if (answeredEmpty) emptyList() else throw lastError
    }
}

/** The speed limit of the road the car is on right now, from a short trace of recent GPS points. */
interface QuickSpeedLimitSource {
    suspend fun speedLimit(points: List<Pair<Double, Double>>): SpeedLimitReading?
    /**
     * True when this source's limits beat the local OpenStreetMap match even once road data is on the
     * phone (TomTom: better limits, matched along the trace). False: only used until road data arrives.
     */
    val isPrimary: Boolean get() = false
    /** Where a limit came from, for the log. */
    val label: String get() = "quick lookup"
}

/**
 * TomTom's Snap to Roads API: matches the last few GPS points to the road the car is driving on and
 * returns TomTom's speed limit for it (the same map data as in-car navigation, far more complete than
 * OpenStreetMap's `maxspeed` tags in the US). Needs a TomTom key; the free tier covers 2,500 requests a day.
 */
class TomTomSpeedLimitSource(private val key: String, private val timeoutSeconds: Double = 6.0) : QuickSpeedLimitSource {
    override val isPrimary: Boolean get() = true
    override val label: String get() = "TomTom"

    override suspend fun speedLimit(points: List<Pair<Double, Double>>): SpeedLimitReading? {
        if (points.isEmpty()) return null
        // ~11 m rounding, like the Valhalla lookup; TomTom needs two points, so a lone one is sent twice.
        val trace = points.takeLast(5).map { round4(it.first) to round4(it.second) }.toMutableList()
        if (trace.size == 1) trace.add(trace[0])
        // Direction of travel at each point (from the one before it) keeps the match off the opposite carriageway.
        val headings = trace.indices.map { i ->
            val (a, b) = if (i == 0) trace[0] to trace[1] else trace[i - 1] to trace[i]
            if (a == b) "" else (RoadMatcher.bearing(a.first, a.second, b.first, b.second).roundedHalfAway().toInt() % 360).toString()
        }
        val url = "https://api.tomtom.com/snapToRoads/1".toHttpUrl().newBuilder()
            .addQueryParameter("key", key)
            .addQueryParameter("points", trace.joinToString(";") { String.format(Locale.US, "%.4f,%.4f", it.second, it.first) })
            .addQueryParameter("headings", headings.joinToString(";"))
            .addQueryParameter("fields", FIELDS)
            .addQueryParameter("vehicleType", "PassengerCar")
            .addQueryParameter("measurementSystem", "imperial")
            .build()
        val result = Http.send(Request.Builder().url(url).build(), Http.client(timeoutSeconds))
        // 400 with a lone point TomTom can't place counts as "no road"; 403 (bad key) and 429 (out of quota) throw.
        if (result.status == 400) return null
        if (!result.isOK) throw IOException("TomTom ${result.status}")
        return RoadMatcher.decodeTomTomSnap(result.text, lastPoint = points.last())
    }

    companion object {
        const val FIELDS = "{projectedPoints{type,geometry{type,coordinates},properties{routeIndex,snapResult}}," +
            "route{type,properties{id,speedLimits{value,unit,type},address{roadName,roadNumbers},frc,formOfWay,roadUse," +
            "laneInfo{numberOfLanes},partOfTunnel,urbanArea}}}"

        /** With a key in this build; null without one. */
        fun configured(): TomTomSpeedLimitSource? = PulseKeys.tomTom()?.let { TomTomSpeedLimitSource(it) }
    }
}

/**
 * The OpenStreetMap community's Valhalla routing server (FOSSGIS, Germany): the same OpenStreetMap
 * limits as Overpass, served from a routing graph kept in memory, so it answers in under a second.
 * Free, no key; the service only asks while the phone has no road data for where the car is.
 */
class ValhallaSpeedLimitSource(private val endpoint: String = "https://valhalla1.openstreetmap.de/trace_attributes",
                               private val timeoutSeconds: Double = 6.0) : QuickSpeedLimitSource {
    override suspend fun speedLimit(points: List<Pair<Double, Double>>): SpeedLimitReading? {
        if (points.isEmpty()) return null
        // ~11 m rounding; a lone point (parked) is sent twice, the least Valhalla accepts.
        val shape = points.takeLast(5).map {
            JsonObject(mapOf("lat" to JsonPrimitive(round4(it.first)), "lon" to JsonPrimitive(round4(it.second))))
        }.toMutableList()
        if (shape.size == 1) shape.add(shape[0])
        val attributes = listOf("edge.speed_limit", "edge.names", "edge.way_id", "edge.road_class", "edge.use",
            "edge.density", "edge.lane_count", "edge.bridge", "edge.tunnel", "edge.unpaved", "edge.roundabout",
            "matched.edge_index", "matched.type", "matched.distance_from_trace_point")
        val body = JsonObject(mapOf(
            "shape" to JsonArray(shape), "costing" to JsonPrimitive("auto"), "shape_match" to JsonPrimitive("map_snap"),
            "filters" to JsonObject(mapOf("attributes" to JsonArray(attributes.map { JsonPrimitive(it) }), "action" to JsonPrimitive("include"))),
        ))
        val request = Request.Builder().url(endpoint).post(Http.jsonBody(body.toString())).build()
        val result = Http.send(request, Http.client(timeoutSeconds))
        // 400 "no suitable edges": nowhere near a road (a field, a big parking lot).
        if (result.status == 400) return null
        if (!result.isOK) throw IOException("Valhalla ${result.status}")
        return RoadMatcher.decodeValhallaTrace(result.text)
    }
}

/**
 * Tries each quick source in order, moving on only when one fails (no key quota, server down);
 * "no road here" from the first one is an answer, not a failure.
 */
class FallbackQuickSource(private val sources: List<QuickSpeedLimitSource>) : QuickSpeedLimitSource {
    override val isPrimary: Boolean get() = sources.firstOrNull()?.isPrimary ?: false
    override val label: String get() = sources.firstOrNull()?.label ?: "quick lookup"

    override suspend fun speedLimit(points: List<Pair<Double, Double>>): SpeedLimitReading? {
        var lastError: Throwable = IOException("no quick source")
        for (source in sources) {
            try {
                return source.speedLimit(points)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError
    }

    companion object {
        /** TomTom when this build has a key, with the free Valhalla server behind it. */
        fun standard() = FallbackQuickSource(listOfNotNull(TomTomSpeedLimitSource.configured(), ValhallaSpeedLimitSource()))
    }
}

/**
 * The CrashSafe backend's cached road tiles (`GET /v1/roads`, `POST /v1/roads/route`): instant once a
 * tile has been fetched, and independent of how busy the public servers are right now.
 */
class BackendRoadSource(private val endpoint: HttpUrl) : RoadDataSource {
    @Serializable
    private data class Response(val ways: List<RoadWay>)

    override suspend fun roads(lat: Double, lon: Double, radiusMeters: Double): List<RoadWay> {
        val url = endpoint.appending("v1/roads").newBuilder()
            .addQueryParameter("lat", String.format(Locale.US, "%.3f", lat))
            .addQueryParameter("lon", String.format(Locale.US, "%.3f", lon))
            .addQueryParameter("radius", radiusMeters.toInt().toString())
            .build()
        return decode(PulseBackend.authorize(Request.Builder().url(url)).build(), 90.0)
    }

    override suspend fun roads(path: List<Pair<Double, Double>>, radiusMeters: Double): List<RoadWay> {
        val body = JsonObject(mapOf(
            "path" to JsonArray(path.map { JsonArray(listOf(JsonPrimitive(round4(it.first)), JsonPrimitive(round4(it.second)))) }),
            "radius" to JsonPrimitive(radiusMeters),
        ))
        val request = PulseBackend.authorize(Request.Builder().url(endpoint.appending("v1/roads/route")))
            .post(Http.jsonBody(body.toString())).build()
        return decode(request, 180.0)
    }

    private suspend fun decode(request: Request, timeout: Double): List<RoadWay> {
        val result = Http.send(request, Http.client(timeout), maxBytes = 30_000_000)
        if (!result.isOK) throw IOException("backend roads ${result.status}")
        return Http.json.decodeFromString(Response.serializer(), result.text).ways
    }

    companion object {
        /** Same server as Pulse: an HTTPS endpoint, or the Mac running a debug emulator. */
        fun configured(): BackendRoadSource? = PulseBackend.endpoint()?.let { BackendRoadSource(it) }
    }
}

/** Tries each source in order (backend cache, then the public servers directly, all at once). */
class FallbackRoadSource(private val sources: List<RoadDataSource>) : RoadDataSource {
    override suspend fun roads(lat: Double, lon: Double, radiusMeters: Double) = first { it.roads(lat, lon, radiusMeters) }

    override suspend fun roads(path: List<Pair<Double, Double>>, radiusMeters: Double) = first { it.roads(path, radiusMeters) }

    private suspend fun first(body: suspend (RoadDataSource) -> List<RoadWay>): List<RoadWay> {
        var lastError: Throwable = IOException("no road source")
        for (source in sources) {
            try {
                val ways = body(source)
                if (ways.isNotEmpty()) return ways
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError
    }

    companion object {
        fun standard(): FallbackRoadSource = FallbackRoadSource(listOfNotNull(BackendRoadSource.configured(), OverpassRoadSource.mirrors()))
    }
}

internal fun round4(x: Double) = (x * 1e4).roundedHalfAway() / 1e4

internal val roadWaysSerializer = ListSerializer(RoadWay.serializer())
