package org.cac.crashsafe.services.trips

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.util.PhoneFormat
import org.cac.crashsafe.model.HelpPlace
import org.cac.crashsafe.services.driving.OverpassRoadSource
import org.cac.crashsafe.services.net.Http
import java.net.URLEncoder
import java.util.Locale

/** A chosen place: from search, the current location, or a dropped pin. */
data class PlaceSelection(
    val title: String,
    val subtitle: String,
    val latitude: Double,
    val longitude: Double,
    val isCurrentLocation: Boolean = false,
)

/**
 * OpenStreetMap searches shared by the trip planner, the trip pack and the post-crash help hub (the iOS app
 * uses Apple Maps for these): Photon (komoot) for search-as-you-type, Overpass for hospitals, police and tow
 * companies around a point. Free, no key.
 */
object PlaceSearch {
    /** Search-as-you-type results near `bias`, best first. */
    suspend fun autocomplete(query: String, bias: Pair<Double, Double>?): List<PlaceSelection> {
        if (query.trim().length < 2) return emptyList()
        val url = "https://photon.komoot.io/api/".toHttpUrl().newBuilder()
            .addQueryParameter("q", query.trim())
            .addQueryParameter("limit", "8")
            .addQueryParameter("lang", "en")
            .apply {
                bias?.let {
                    addQueryParameter("lat", String.format(Locale.US, "%.3f", it.first))
                    addQueryParameter("lon", String.format(Locale.US, "%.3f", it.second))
                }
            }
            .build()
        return try {
            val result = Http.send(Request.Builder().url(url).build(), Http.client(8.0))
            if (!result.isOK) return emptyList()
            val features = Http.json.parseToJsonElement(result.text).jsonObject["features"]?.jsonArray ?: return emptyList()
            features.mapNotNull { feature ->
                val f = feature as? JsonObject ?: return@mapNotNull null
                val coordinates = f["geometry"]?.jsonObject?.get("coordinates")?.jsonArray ?: return@mapNotNull null
                val p = f["properties"]?.jsonObject ?: return@mapNotNull null
                fun field(name: String) = p[name]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
                val street = field("street")?.let { s -> field("housenumber")?.let { "$it $s" } ?: s }
                val title = field("name") ?: street ?: return@mapNotNull null
                val state = field("state")
                val subtitle = listOfNotNull(if (title == street) null else street, field("city") ?: field("county"),
                    state, field("country")?.takeIf { it != "United States" }).distinct().joinToString(", ")
                PlaceSelection(title, subtitle, coordinates[1].jsonPrimitive.double, coordinates[0].jsonPrimitive.double)
            }.distinctBy { "${it.title}|${it.subtitle}" }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
    }

    suspend fun helpPlaces(lat: Double, lon: Double, radiusMeters: Double = 15_000.0, perCategory: Int = 4): List<HelpPlace> {
        val all = overpass(lat, lon, radiusMeters)
        return HelpPlace.Category.entries.flatMap { category ->
            all.filter { it.category == category }.sortedBy { it.distanceMiles(lat, lon) }.take(perCategory)
        }
    }

    /** Hospitals, police stations and tow companies within `radiusMeters`, from OpenStreetMap. */
    private suspend fun overpass(lat: Double, lon: Double, radiusMeters: Double): List<HelpPlace> {
        val around = "(around:${radiusMeters.toInt()},${String.format(Locale.US, "%.4f,%.4f", lat, lon)})"
        val query = "[out:json][timeout:25];(" +
            "nwr[\"amenity\"=\"hospital\"]$around;" +
            "nwr[\"amenity\"=\"police\"]$around;" +
            "nwr[\"service:vehicle:towing\"=\"yes\"]$around;" +
            "nwr[\"name\"~\"towing|wrecker|roadside\",i]$around;" +
            ");out center tags 120;"
        for (server in OverpassRoadSource.servers) {
            try {
                val request = Request.Builder().url(server).post(Http.formBody("data=" + URLEncoder.encode(query, "UTF-8"))).build()
                val result = Http.send(request, Http.client(30.0))
                if (!result.isOK) continue
                return decode(result.text)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                continue
            }
        }
        return emptyList()
    }

    internal fun decode(json: String): List<HelpPlace> {
        val elements = Http.json.parseToJsonElement(json).jsonObject["elements"] as? JsonArray ?: return emptyList()
        return elements.mapNotNull { element ->
            val e = element as? JsonObject ?: return@mapNotNull null
            val tags = (e["tags"] as? JsonObject)?.mapValues { it.value.jsonPrimitive.content } ?: return@mapNotNull null
            val center = e["center"] as? JsonObject
            val lat = (e["lat"] ?: center?.get("lat"))?.jsonPrimitive?.doubleOrNull ?: return@mapNotNull null
            val lon = (e["lon"] ?: center?.get("lon"))?.jsonPrimitive?.doubleOrNull ?: return@mapNotNull null
            val category = when {
                tags["amenity"] == "hospital" -> HelpPlace.Category.hospital
                tags["amenity"] == "police" -> HelpPlace.Category.police
                else -> HelpPlace.Category.towing
            }
            val name = tags["name"] ?: category.title
            val phone = (tags["phone"] ?: tags["contact:phone"] ?: "").split(";").first().trim().let { if (it.isEmpty()) it else PhoneFormat.display(it) }
            HelpPlace(name = name, phone = phone, category = category, latitude = lat, longitude = lon)
        }.distinctBy { it.id }
    }
}

/** A driving route between two points (OSRM, the OpenStreetMap routing engine). */
data class RouteResult(val distanceMeters: Double, val travelSeconds: Double, val points: List<Pair<Double, Double>>)

object Routing {
    suspend fun drive(from: Pair<Double, Double>, to: Pair<Double, Double>): RouteResult? {
        val path = String.format(Locale.US, "%.6f,%.6f;%.6f,%.6f", from.second, from.first, to.second, to.first)
        val url = "https://router.project-osrm.org/route/v1/driving/$path".toHttpUrl().newBuilder()
            .addQueryParameter("overview", "full")
            .addQueryParameter("geometries", "geojson")
            .build()
        return try {
            val result = Http.send(Request.Builder().url(url).build(), Http.client(15.0))
            if (!result.isOK) return null
            val route = Http.json.parseToJsonElement(result.text).jsonObject["routes"]?.jsonArray?.firstOrNull()?.jsonObject ?: return null
            val coordinates = route["geometry"]?.jsonObject?.get("coordinates")?.jsonArray ?: return null
            val points = coordinates.map { val c = it.jsonArray; c[1].jsonPrimitive.double to c[0].jsonPrimitive.double }
            RouteResult(route["distance"]!!.jsonPrimitive.double, route["duration"]!!.jsonPrimitive.double, points)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
    }

    /** Points along the route at least `spacing` apart, capped so the query stays small. */
    fun samples(points: List<Pair<Double, Double>>, spacing: Double = 400.0, cap: Int = 400): List<Pair<Double, Double>> {
        val kept = mutableListOf<Pair<Double, Double>>()
        for (point in points) {
            val last = kept.lastOrNull()
            if (last == null || TransportFeatures.haversine(last.first, last.second, point.first, point.second) >= spacing) kept.add(point)
        }
        points.lastOrNull()?.let { kept.add(it) }
        if (kept.size <= cap) return kept
        val stride = (kept.size - 1).toDouble() / (cap - 1)
        return (0 until cap).map { kept[kotlin.math.round(it * stride).toInt()] }
    }
}
