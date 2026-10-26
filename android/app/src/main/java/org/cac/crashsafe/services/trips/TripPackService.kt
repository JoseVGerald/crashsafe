package org.cac.crashsafe.services.trips

import kotlinx.coroutines.delay
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.HelpPlace
import org.cac.crashsafe.model.TripPack
import org.cac.crashsafe.services.driving.FallbackRoadSource
import org.cac.crashsafe.services.driving.RoadDataSource

data class TripPackRequest(
    val origin: String,
    val destination: String,
    val originCoordinate: Pair<Double, Double>?,
    val destinationCoordinate: Pair<Double, Double>?,
)

class TripPackException(message: String) : Exception(message)

/** Builds the trip pack for a planned route. */
interface TripPackService {
    suspend fun downloadPack(request: TripPackRequest): TripPack
}

/** Searches OpenStreetMap around the start, middle and end of the route, and saves the route's speed limits. */
class OsmTripPackService(private val roads: () -> RoadDataSource = { FallbackRoadSource.standard() }) : TripPackService {
    private val fallback = MockTripPackService()

    override suspend fun downloadPack(request: TripPackRequest): TripPack {
        // Search around whatever real coordinates the trip has (start, middle, end) — never a default city.
        val anchors = listOfNotNull(request.originCoordinate, request.destinationCoordinate).toMutableList()
        val from = request.originCoordinate
        val to = request.destinationCoordinate
        if (from != null && to != null) anchors.add(1, (from.first + to.first) / 2 to (from.second + to.second) / 2)
        if (anchors.isEmpty()) return fallback.downloadPack(request)
        val found = anchors.flatMap { PlaceSearch.helpPlaces(it.first, it.second, radiusMeters = 20_000.0, perCategory = 3) }
        val unique = found.distinctBy { it.id }
        if (unique.isEmpty()) return fallback.downloadPack(request)
        var pack = TripPack(
            towCompanies = unique.filter { it.category == HelpPlace.Category.towing },
            hospitals = unique.filter { it.category == HelpPlace.Category.hospital },
            police = unique.filter { it.category == HelpPlace.Category.police },
            guides = TripPack.standardGuides,
            generatedAt = nowSeconds())
        // Best effort: a pack without speed limits is still useful.
        if (from != null && to != null) {
            val route = Routing.drive(from, to)
            if (route != null) {
                pack = pack.copy(roads = runCatching { roads().roads(Routing.samples(route.points), radiusMeters = 60.0) }.getOrNull())
            }
        }
        return pack
    }
}

/**
 * Returns sample places after a short delay, placed around the trip's real coordinates.
 * Without any coordinates it fails instead of inventing a location.
 */
class MockTripPackService : TripPackService {
    override suspend fun downloadPack(request: TripPackRequest): TripPack {
        delay(1200)
        val base = request.originCoordinate ?: request.destinationCoordinate
            ?: throw TripPackException("Choose a start or destination on the map first.")
        fun place(name: String, phone: String, category: HelpPlace.Category, dLat: Double, dLon: Double) =
            HelpPlace(name, phone, category, base.first + dLat, base.second + dLon)
        return TripPack(
            towCompanies = listOf(place("Evergreen Towing", "555-0101", HelpPlace.Category.towing, 0.01, 0.02),
                place("Cascade Roadside", "555-0102", HelpPlace.Category.towing, -0.02, 0.01)),
            hospitals = listOf(place("${request.origin} General Hospital", "555-0201", HelpPlace.Category.hospital, 0.02, -0.01)),
            police = listOf(place("${request.origin} Police", "555-0301", HelpPlace.Category.police, -0.01, -0.02)),
            guides = TripPack.standardGuides,
            generatedAt = nowSeconds())
    }
}
