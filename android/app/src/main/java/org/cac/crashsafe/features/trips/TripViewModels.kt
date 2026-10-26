package org.cac.crashsafe.features.trips

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.data.AppStore
import org.cac.crashsafe.model.RouteFormat
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.model.TripPackStatus
import org.cac.crashsafe.services.trips.PlaceSelection
import org.cac.crashsafe.services.trips.RouteResult
import org.cac.crashsafe.services.trips.Routing
import org.cac.crashsafe.services.trips.TripPackRequest
import org.cac.crashsafe.services.trips.TripPackService

class TripPlannerViewModel(private val userID: String, private val scope: CoroutineScope) {
    var origin by mutableStateOf<PlaceSelection?>(null)
        private set
    var destination by mutableStateOf<PlaceSelection?>(null)
        private set
    var startDate by mutableStateOf(nowSeconds())
    var endDate by mutableStateOf(nowSeconds() + 24 * 3_600)
    var route by mutableStateOf<RouteResult?>(null)
        private set
    var isRouting by mutableStateOf(false)
        private set
    var submitAttempted by mutableStateOf(false)
        private set
    var lastSaved by mutableStateOf<String?>(null)
        private set
    private var routing: Job? = null

    val originError: String? get() = if (submitAttempted && origin == null) "Choose where you're leaving from." else null
    val destinationError: String? get() = if (submitAttempted && destination == null) "Choose where you're headed." else null
    val datesError: String? get() = if (endDate < startDate) "Return date must be after the start date." else null
    val isValid: Boolean get() = origin != null && destination != null && endDate >= startDate

    val routeSummary: String? get() = route?.let { RouteFormat.summary(it.distanceMeters, it.travelSeconds) }

    fun updateOrigin(place: PlaceSelection?) {
        if (place == origin) return
        origin = place
        updateRoute()
    }

    fun updateDestination(place: PlaceSelection?) {
        if (place == destination) return
        destination = place
        updateRoute()
    }

    fun swap() {
        val oldOrigin = origin
        origin = destination
        destination = oldOrigin
        updateRoute()
    }

    private fun updateRoute() {
        routing?.cancel()
        val from = origin
        val to = destination
        if (from == null || to == null) {
            route = null
            return
        }
        routing = scope.launch {
            isRouting = true
            try {
                route = Routing.drive(from.latitude to from.longitude, to.latitude to to.longitude)
            } finally {
                isRouting = false
            }
        }
    }

    fun save(store: AppStore): Trip? {
        submitAttempted = true
        val origin = origin ?: return null
        val destination = destination ?: return null
        if (!isValid) return null
        val originName = if (origin.isCurrentLocation) origin.subtitle.ifEmpty { "Current location" } else origin.title
        val trip = Trip(ownerID = userID, origin = originName, destination = destination.title, startDate = startDate, endDate = endDate,
            originLatitude = origin.latitude, originLongitude = origin.longitude,
            destinationLatitude = destination.latitude, destinationLongitude = destination.longitude,
            routeDistanceMeters = route?.distanceMeters, routeTravelSeconds = route?.travelSeconds)
        store.insertTrip(trip)
        lastSaved = trip.routeLabel
        this.destination = null
        route = null
        submitAttempted = false
        return trip
    }

    fun dismissSavedNotice() {
        lastSaved = null
    }
}

/** Downloads the offline trip pack for one trip. */
object TripPacks {
    fun download(store: AppStore, service: TripPackService, scope: CoroutineScope, tripID: String) {
        val trip = store.trip(tripID) ?: return
        if (trip.tripPackStatus == TripPackStatus.downloading) return
        store.updateTrip(tripID) { it.copy(tripPackStatus = TripPackStatus.downloading) }
        scope.launch {
            try {
                val pack = service.downloadPack(TripPackRequest(trip.origin, trip.destination, trip.originCoordinate, trip.destinationCoordinate))
                store.updateTrip(tripID) {
                    it.copy(tripPack = pack, tripPackSummary = pack.summary, tripPackUpdatedAt = pack.generatedAt, tripPackStatus = TripPackStatus.ready)
                }
            } catch (e: CancellationException) {
                store.updateTrip(tripID) { it.copy(tripPackStatus = TripPackStatus.failed) }
                throw e
            } catch (e: Exception) {
                store.updateTrip(tripID) { it.copy(tripPackStatus = TripPackStatus.failed) }
            }
        }
    }
}
