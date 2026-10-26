package org.cac.crashsafe.core.roads

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.cac.crashsafe.core.intelligence.TransportFeatures
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin
import kotlin.math.sqrt

internal val lenientJson = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

/**
 * One road from OpenStreetMap (CrashSafe's offline speed limit data: TomTom is only reachable online).
 * Built from an Overpass `way … out tags geom` response.
 */
@Serializable
data class RoadWay(
    val id: Long,
    val highway: String,
    val maxspeed: String? = null,
    val maxspeedForward: String? = null,
    val maxspeedBackward: String? = null,
    val oneway: String? = null,
    val name: String? = null,
    val ref: String? = null,
    val points: List<Point>,
) {
    @Serializable
    data class Point(val lat: Double, val lon: Double)

    val isOneway: Boolean get() = (oneway ?: "") in listOf("yes", "true", "1", "-1") || highway == "motorway"
    val displayName: String? get() = name ?: ref?.replace(";", " / ")
}

/** Things about the road the car is on that change how carefully to drive. */
@Serializable(with = RoadFeatures.Serializer::class)
data class RoadFeatures(val rawValue: Int) {
    operator fun contains(other: RoadFeatures) = rawValue and other.rawValue == other.rawValue
    operator fun plus(other: RoadFeatures) = RoadFeatures(rawValue or other.rawValue)
    val isEmpty: Boolean get() = rawValue == 0

    val labels: List<String>
        get() = listOf(bridge to "bridge", tunnel to "tunnel", unpaved to "gravel", roundabout to "roundabout", singleLane to "one lane")
            .mapNotNull { (feature, label) -> if (feature in this) label else null }

    companion object {
        val none = RoadFeatures(0)
        val bridge = RoadFeatures(1)
        val tunnel = RoadFeatures(2)
        val unpaved = RoadFeatures(4)
        val roundabout = RoadFeatures(8)
        val singleLane = RoadFeatures(16)
    }

    object Serializer : KSerializer<RoadFeatures> {
        override val descriptor = PrimitiveSerialDescriptor("RoadFeatures", PrimitiveKind.INT)
        override fun serialize(encoder: Encoder, value: RoadFeatures) = encoder.encodeInt(value.rawValue)
        override fun deserialize(decoder: Decoder) = RoadFeatures(decoder.decodeInt())
    }
}

/** The speed limit where the car is, and how sure we are of it. */
@Serializable
data class SpeedLimitReading(
    val mph: Double,
    /** True when the road is tagged with a posted limit; false for a typical limit for that kind of road. */
    val isPosted: Boolean,
    val roadName: String? = null,
    val highway: String,
    val wayID: Long,
    val distanceMeters: Double,
    /** What kind of road this is, in finer detail (residential, arterial, ramp, gravel…). */
    val segment: RoadSegment? = null,
    /** Road features worth a word of caution. */
    val features: RoadFeatures = RoadFeatures.none,
) {
    val environment: RoadKind get() = RoadKind.of(highway, mph)
    /** The finest description available. */
    val resolvedSegment: RoadSegment get() = segment ?: RoadSegment.classify(highway, mph)
}

/** Finer road types than city / highway / rural, each with how careful to be and why. */
@Serializable
enum class RoadSegment(val title: String) {
    interstate("Interstate / freeway"),
    ramp("Highway ramp"),
    expressway("Expressway"),
    arterial("Arterial road"),
    collector("Collector street"),
    localConnector("Neighborhood connector"),
    downtown("Downtown street"),
    residential("Residential street"),
    livingStreet("Shared street"),
    alley("Alley / service road"),
    parkingLot("Parking lot"),
    ruralRoad("Rural road"),
    gravelRoad("Gravel road");

    enum class Caution { normal, elevated, high }

    val caution: Caution
        get() = when (this) {
            residential, livingStreet, alley, parkingLot, gravelRoad, downtown -> Caution.high
            ramp, arterial, collector, localConnector, ruralRoad -> Caution.elevated
            interstate, expressway -> Caution.normal
        }

    /** One line of advice, said when the car enters this kind of road. */
    val advice: String
        get() = when (this) {
            residential -> "Kids, pets and cars backing out of driveways can appear between parked cars. Go slow and cover the brake."
            livingStreet -> "Shared street: people walk in the road here. Go at walking pace."
            alley -> "Alley: blind corners and garages. Creep through."
            parkingLot -> "Parking lot: cars back out without seeing you and people walk between them."
            downtown -> "Downtown: crosswalks, cyclists and car doors opening. Cover the brake."
            gravelRoad -> "Gravel road: stopping takes much longer. Slow down before curves."
            ruralRoad -> "Rural road: sharp curves, no shoulder, and deer at dusk."
            ramp -> "Ramp: match the curve's speed and check your blind spot before merging."
            arterial -> "Busy arterial: watch for cars turning across your lane."
            collector -> "Collector street: driveways and bus stops. Watch for pedestrians."
            localConnector -> "Neighborhood road: crosswalks and bikes. Keep it easy."
            interstate -> "Freeway: keep three seconds of space and merge smoothly."
            expressway -> "Expressway: watch for cross traffic at intersections."
        }

    /** The `default_speeds.json` categories to look for, most specific first. */
    val defaultCategories: List<String>
        get() = when (this) {
            interstate -> listOf("motorway", "expressway", "rural", "default")
            expressway -> listOf("expressway", "rural", "default")
            residential -> listOf("residential", "urban")
            livingStreet -> listOf("livingStreet", "residential", "urban")
            alley, parkingLot -> listOf("alley", "residential", "urban")
            downtown -> listOf("business", "urban")
            ruralRoad, gravelRoad -> listOf("rural", "default")
            ramp -> emptyList()
            arterial, collector, localConnector -> listOf("urban")
        }

    companion object {
        /**
         * From the OpenStreetMap road class, how built-up the area is (Valhalla's 0–15 density, when
         * known), surface, and the limit.
         */
        fun classify(highway: String, mph: Double?, density: Int? = null, unpaved: Boolean = false): RoadSegment {
            val rural = density?.let { it <= 3 }
            if (unpaved && !highway.startsWith("motorway") && !highway.startsWith("trunk")) return gravelRoad
            return when {
                highway == "motorway" -> interstate
                highway.endsWith("_link") -> ramp
                highway == "trunk" -> if (rural == false || (mph ?: 0.0) >= 50) expressway else arterial
                highway == "primary" -> if (rural == true) ruralRoad else arterial
                highway == "secondary" -> if (rural == true) ruralRoad else if ((density ?: 0) >= 14 && (mph ?: 99.0) <= 25) downtown else collector
                highway == "tertiary" -> if (rural == true) ruralRoad else if ((density ?: 0) >= 14 && (mph ?: 99.0) <= 25) downtown else localConnector
                highway == "unclassified" -> if (rural == true || (mph ?: 0.0) >= 40) ruralRoad else localConnector
                highway == "residential" -> if (rural == true && (mph ?: 0.0) >= 35) ruralRoad else residential
                highway == "living_street" -> livingStreet
                highway == "service" -> alley
                highway == "parking_aisle" -> parkingLot
                else -> localConnector
            }
        }
    }
}

/**
 * Legal default speed limits by region (`default_speeds.json`, built from osm-legal-default-speeds):
 * the limit for an untagged road where the car actually is, e.g. 25 mph on an Oregon residential street.
 */
class RoadDefaults(val regions: Map<String, Map<String, Double>>) {
    /** `region` like "US-OR" (falls back to the country, "US"). */
    fun typicalMPH(segment: RoadSegment, region: String?): Double? {
        if (region == null) return null
        val codes = listOf(region, region.takeWhile { it != '-' })
        for (code in codes) {
            val row = regions[code] ?: continue
            for (category in segment.defaultCategories) row[category]?.let { return it }
        }
        return null
    }

    companion object {
        @Serializable
        private data class File(val regions: Map<String, Map<String, Double>>)

        fun fromJson(json: String): RoadDefaults = RoadDefaults(lenientJson.decodeFromString<File>(json).regions)
    }
}

/** What kind of road this is, for coaching ("city street", "highway", "rural road"). */
@Serializable
enum class RoadKind {
    city, highway, rural;

    companion object {
        fun of(highway: String, mph: Double): RoadKind = when {
            highway.startsWith("motorway") || highway.startsWith("trunk") -> RoadKind.highway
            highway == "unclassified" && mph >= 40 -> rural
            else -> city
        }
    }
}

object RoadMatcher {
    /** Driveable road classes, in the Overpass regex the service queries. */
    const val highwayPattern = "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"

    /**
     * Typical US limits when a road has no posted `maxspeed` tag (Washington's statutory defaults are
     * 25 mph on city streets, 50 on county roads, 60 on state highways; RCW 46.61.400).
     */
    fun typicalLimitMPH(highway: String): Double? = when (highway) {
        "motorway" -> 60.0
        "trunk" -> 55.0
        "primary" -> 40.0
        "secondary" -> 35.0
        "tertiary" -> 30.0
        "unclassified" -> 35.0
        "residential" -> 25.0
        "living_street" -> 15.0
        "motorway_link", "trunk_link" -> 35.0
        "primary_link", "secondary_link", "tertiary_link" -> 25.0
        else -> null
    }

    /** OpenStreetMap `maxspeed` values: "35 mph", "50" (km/h by default), "60 km/h", "none", "signals"… */
    fun parseMPH(raw: String?): Double? {
        val text = raw?.trim()?.lowercase()
        if (text.isNullOrEmpty()) return null
        val first = text.split(";").first()
        val number = first.takeWhile { it.isDigit() || it == '.' }
        val value = number.toDoubleOrNull() ?: return null
        if (value <= 0 || value >= 200) return null
        if (first.contains("mph")) return value
        if (first.contains("knots")) return value * 1.15078
        return roundHalfAway(value * 0.621371) // km/h
    }

    /** The posted limit for travel along `bearing` (direction-specific tags first). */
    fun postedMPH(way: RoadWay, forward: Boolean): Double? =
        parseMPH(if (forward) way.maxspeedForward else way.maxspeedBackward) ?: parseMPH(way.maxspeed)

    /**
     * Picks the road the car is on: the nearest one, preferring roads that run the way the car is heading.
     * @param heading direction of travel in degrees (0 = north), if known.
     * @param maxDistance GPS is usually within ~10 m; beyond this we don't guess.
     */
    fun match(lat: Double, lon: Double, heading: Double?, ways: List<RoadWay>, maxDistance: Double = 35.0): SpeedLimitReading? {
        var bestScore = 0.0
        var best: SpeedLimitReading? = null
        for (way in ways) {
            if (way.points.size < 2) continue
            val (distance, segmentBearing) = nearest(lat, lon, way.points) ?: continue
            if (distance > maxDistance) continue
            var forward = true
            var anglePenalty = 0.0
            if (heading != null) {
                val diff = angleDifference(heading, segmentBearing)
                forward = diff <= 90
                // Two-way roads match either direction; one-way roads only their own.
                val alignment = if (way.isOneway) diff else minOf(diff, 180 - diff)
                anglePenalty = if (alignment > 60) 60.0 else alignment * 0.4
            }
            val posted = postedMPH(way, forward)
            val mph = posted ?: typicalLimitMPH(way.highway) ?: continue
            val score = distance + anglePenalty
            if (best == null || score < bestScore) {
                bestScore = score
                best = SpeedLimitReading(mph = mph, isPosted = posted != null, roadName = way.displayName,
                    highway = way.highway, wayID = way.id, distanceMeters = distance)
            }
        }
        return best
    }

    /** Distance (m) from the point to the polyline, and the bearing (degrees) of the closest segment. */
    fun nearest(lat: Double, lon: Double, points: List<RoadWay.Point>): Pair<Double, Double>? {
        val mPerLat = 111_320.0
        val mPerLon = 111_320.0 * cos(lat * PI / 180)
        var best: Pair<Double, Double>? = null
        for ((a, b) in points.zipWithNext()) {
            val ax = (a.lon - lon) * mPerLon
            val ay = (a.lat - lat) * mPerLat
            val bx = (b.lon - lon) * mPerLon
            val by = (b.lat - lat) * mPerLat
            val dx = bx - ax
            val dy = by - ay
            val len2 = dx * dx + dy * dy
            val t = if (len2 > 0) (-(ax * dx + ay * dy) / len2).coerceIn(0.0, 1.0) else 0.0
            val px = ax + t * dx
            val py = ay + t * dy
            val distance = sqrt(px * px + py * py)
            val bearing = (atan2(dx, dy) * 180 / PI + 360).rem(360)
            if (best == null || distance < best.first) best = distance to bearing
        }
        return best
    }

    /** Initial bearing from one fix to the next, degrees (0 = north). */
    fun bearing(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double): Double {
        val p1 = fromLat * PI / 180
        val p2 = toLat * PI / 180
        val dl = (toLon - fromLon) * PI / 180
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / PI + 360).rem(360)
    }

    fun angleDifference(a: Double, b: Double): Double {
        val d = abs(a - b).rem(360)
        return if (d > 180) 360 - d else d
    }

    /** RoadKind-style highway tag for a Valhalla road class (`motorway`, `residential`, …; ramps are links). */
    fun highway(valhallaClass: String?, use: String?): String? {
        val roadClass = valhallaClass ?: return null
        if (use == "living_street") return "living_street"
        val known = listOf("motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential")
        if (roadClass !in known) return if (use == "ramp") "primary_link" else null
        if (use == "ramp" && roadClass in listOf("motorway", "trunk", "primary", "secondary", "tertiary")) return roadClass + "_link"
        return roadClass
    }

    @Serializable
    private data class ValhallaResponse(
        val edges: List<Edge>? = null,
        @SerialName("matched_points") val matchedPoints: List<Matched>? = null,
    ) {
        @Serializable
        data class Edge(
            @SerialName("speed_limit") val speedLimit: Double? = null,
            val names: List<String>? = null,
            @SerialName("way_id") val wayId: Long? = null,
            @SerialName("road_class") val roadClass: String? = null,
            val use: String? = null,
            val density: Int? = null,
            @SerialName("lane_count") val laneCount: Int? = null,
            val bridge: Boolean? = null,
            val tunnel: Boolean? = null,
            val unpaved: Boolean? = null,
            val roundabout: Boolean? = null,
        )

        @Serializable
        data class Matched(
            val type: String? = null,
            @SerialName("edge_index") val edgeIndex: Int? = null,
            @SerialName("distance_from_trace_point") val distanceFromTracePoint: Double? = null,
        )
    }

    /**
     * Parses Valhalla's `trace_attributes` (the OpenStreetMap community's routing server): the road the
     * last point of a short GPS trace matched, with its posted limit. Valhalla reports `speed_limit` in
     * km/h only where the road has a posted `maxspeed` tag, so a missing value falls back to the typical
     * limit for the road class, marked not posted.
     */
    fun decodeValhallaTrace(json: String, maxDistance: Double = 35.0): SpeedLimitReading? {
        val response = lenientJson.decodeFromString<ValhallaResponse>(json)
        val edges = response.edges ?: emptyList()
        val point = response.matchedPoints?.lastOrNull {
            it.type == "matched" && (it.edgeIndex ?: -1) < edges.size && (it.edgeIndex ?: -1) >= 0
        } ?: return null
        val index = point.edgeIndex ?: return null
        val distance = point.distanceFromTracePoint ?: 0.0
        if (distance > maxDistance) return null
        val edge = edges[index]
        val highway = highway(edge.roadClass, edge.use)
        // 255 means "no limit" in Valhalla; 0 or missing means none posted.
        val posted = edge.speedLimit?.let { if (it > 0 && it < 250) roundHalfAway(it * 0.621371) else null }
        // No posted limit on a service road or parking aisle: don't guess one.
        val lot = (edge.use ?: "") in listOf("parking_aisle", "driveway", "alley", "drive_through")
        val mph = posted ?: highway?.let { typicalLimitMPH(it) } ?: (if (lot) 10.0 else null) ?: return null
        var features = RoadFeatures.none
        if (edge.bridge == true) features += RoadFeatures.bridge
        if (edge.tunnel == true) features += RoadFeatures.tunnel
        if (edge.unpaved == true) features += RoadFeatures.unpaved
        if (edge.roundabout == true) features += RoadFeatures.roundabout
        if (edge.laneCount == 1 && (highway?.let { it !in listOf("residential", "service", "living_street") } ?: false)) {
            features += RoadFeatures.singleLane
        }
        val segment = when (edge.use) {
            "parking_aisle", "driveway" -> RoadSegment.parkingLot
            "alley" -> RoadSegment.alley
            else -> RoadSegment.classify(highway ?: "service", mph, density = edge.density, unpaved = edge.unpaved == true)
        }
        return SpeedLimitReading(mph = mph, isPosted = posted != null, roadName = edge.names?.firstOrNull(),
            highway = highway ?: "service", wayID = edge.wayId ?: 0, distanceMeters = distance,
            segment = segment, features = features)
    }

    /**
     * RoadKind-style highway tag for TomTom's functional road class (0 = freeway … 8 = minor), road use and
     * form of way.
     */
    fun highway(tomTomFRC: Int?, use: String?, formOfWay: String?): String {
        val form = formOfWay ?: ""
        if (form == "ServiceRoad" || form.startsWith("ETA") || form == "EntranceToOrExitFromACarPark" ||
            form == "RoadInEnclosedTrafficArea") return "service"
        if (form == "RoadInPedestrianZone") return "living_street"
        val base = when (tomTomFRC ?: 6) {
            0 -> "motorway"
            1 -> if (use == "LimitedAccess") "motorway" else "trunk"
            2 -> "primary"
            3 -> "secondary"
            4 -> "tertiary"
            5 -> "unclassified"
            6, 7 -> "residential"
            else -> "service"
        }
        if (use == "Ramp" || form.endsWith("SlipRoad")) {
            return if (base in listOf("motorway", "trunk", "primary", "secondary", "tertiary")) base + "_link" else "primary_link"
        }
        return base
    }

    @Serializable
    private data class TomTomResponse(val route: List<Route>? = null, val projectedPoints: List<Projected>? = null) {
        @Serializable
        data class Measure(val value: Double? = null, val unit: String? = null, val type: String? = null)

        @Serializable
        data class Route(val properties: Properties? = null) {
            @Serializable
            data class Properties(
                val id: String? = null,
                val speedLimits: Measure? = null,
                val address: Address? = null,
                val frc: Int? = null,
                val formOfWay: String? = null,
                val roadUse: String? = null,
                val laneInfo: Lanes? = null,
                val partOfTunnel: Boolean? = null,
                val urbanArea: Boolean? = null,
            )

            @Serializable
            data class Address(val roadName: String? = null, val roadNumbers: List<String>? = null)

            @Serializable
            data class Lanes(val numberOfLanes: Int? = null)
        }

        @Serializable
        data class Projected(val geometry: Geometry? = null, val properties: Properties? = null) {
            @Serializable
            data class Geometry(val coordinates: List<Double>? = null)

            @Serializable
            data class Properties(val routeIndex: Int? = null, val snapResult: String? = null)
        }
    }

    /**
     * Parses TomTom's Snap to Roads response: the road the last point of a short GPS trace matched, with its
     * posted limit. TomTom matches the whole trace to a route, so a frontage road or ramp beside the car
     * doesn't win just for being a few meters closer. A missing or advisory ("Recommended") limit falls back
     * to the typical limit for the road class, marked not posted.
     * @param lastPoint the trace's last GPS point, to measure how far the match is from the car.
     */
    fun decodeTomTomSnap(json: String, lastPoint: Pair<Double, Double>? = null, maxDistance: Double = 35.0): SpeedLimitReading? {
        val response = lenientJson.decodeFromString<TomTomResponse>(json)
        val routes = response.route ?: emptyList()
        val point = response.projectedPoints?.lastOrNull() ?: return null
        if (point.properties?.snapResult != "Matched") return null
        val index = point.properties.routeIndex ?: return null
        if (index !in routes.indices) return null
        val road = routes[index].properties ?: return null
        var distance = 0.0
        val snapped = point.geometry?.coordinates
        if (lastPoint != null && snapped != null && snapped.size >= 2) {
            distance = TransportFeatures.haversine(lastPoint.first, lastPoint.second, snapped[1], snapped[0])
        }
        if (distance > maxDistance) return null
        val highway = highway(road.frc, road.roadUse, road.formOfWay)
        val posted = road.speedLimits?.let { limit ->
            val value = limit.value
            if (limit.type == "Recommended" || value == null || value <= 0 || value >= 250) null
            else if (limit.unit == "mph") value else roundHalfAway(value * 0.621371)
        }
        val lot = (road.formOfWay ?: "").startsWith("ETAParking") || road.formOfWay == "EntranceToOrExitFromACarPark"
        val mph = posted ?: (if (lot) 10.0 else typicalLimitMPH(highway)) ?: return null
        var features = RoadFeatures.none
        if (road.partOfTunnel == true) features += RoadFeatures.tunnel
        if (road.formOfWay == "Roundabout" || road.roadUse == "Rotary") features += RoadFeatures.roundabout
        if (road.laneInfo?.numberOfLanes == 1 && highway !in listOf("residential", "service", "living_street")) {
            features += RoadFeatures.singleLane
        }
        // TomTom says urban or not; Valhalla-style density stands in for it (≤ 3 reads as rural).
        val segment = if (lot) RoadSegment.parkingLot
        else RoadSegment.classify(highway, mph, density = if (road.urbanArea == false) 2 else null)
        return SpeedLimitReading(mph = mph, isPosted = posted != null,
            roadName = road.address?.roadName ?: road.address?.roadNumbers?.firstOrNull(),
            highway = highway, wayID = stableID(road.id), distanceMeters = distance,
            segment = segment, features = features)
    }

    /** TomTom road IDs are strings; a stable 64-bit FNV-1a hash stands in for an OpenStreetMap way ID. */
    fun stableID(text: String?): Long {
        if (text == null) return 0
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            hash = (hash xor (byte.toLong() and 0xFF)) * 0x100000001b3L
        }
        return hash
    }

    /** Parses an Overpass JSON response (`out tags geom`). */
    fun decodeOverpass(json: String): List<RoadWay> {
        val root = lenientJson.parseToJsonElement(json).jsonObject
        val elements = root["elements"] as? kotlinx.serialization.json.JsonArray ?: return emptyList()
        return elements.mapNotNull { element ->
            val e = element as? JsonObject ?: return@mapNotNull null
            if (e["type"]?.jsonPrimitive?.content != "way") return@mapNotNull null
            val id = e["id"]?.jsonPrimitive?.content?.toLongOrNull() ?: return@mapNotNull null
            val tags = (e["tags"] as? JsonObject)?.mapValues { it.value.jsonPrimitive.content } ?: return@mapNotNull null
            val highway = tags["highway"] ?: return@mapNotNull null
            val geometry = (e["geometry"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { p ->
                val point = p as? JsonObject ?: return@mapNotNull null
                val lat = point["lat"]?.jsonPrimitive?.double ?: return@mapNotNull null
                val lon = point["lon"]?.jsonPrimitive?.double ?: return@mapNotNull null
                RoadWay.Point(lat, lon)
            } ?: return@mapNotNull null
            RoadWay(id = id, highway = highway, maxspeed = tags["maxspeed"], maxspeedForward = tags["maxspeed:forward"],
                maxspeedBackward = tags["maxspeed:backward"], oneway = tags["oneway"], name = tags["name"],
                ref = tags["ref"], points = geometry)
        }
    }

    /** Swift's `.rounded()`: to nearest, ties away from zero. */
    fun roundHalfAway(x: Double): Double = if (x >= 0) floor(x + 0.5) else -floor(-x + 0.5)
}
