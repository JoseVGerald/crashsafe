package org.cac.crashsafe.features.home

import org.cac.crashsafe.core.driving.DriveScenario
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.data.AppStore
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.services.crash.CrashDetector
import org.cac.crashsafe.services.driving.DrivingMonitor
import org.cac.crashsafe.services.location.LocationService
import org.cac.crashsafe.services.weather.ConditionsStore

/** Starts/ends trips and keeps crash detection and the driving monitor in sync with the active trip. */
class HomeViewModel(
    private val store: AppStore,
    private val detector: CrashDetector,
    private val driving: DrivingMonitor,
    private val conditions: ConditionsStore,
    private val userID: String,
) {
    val isMonitoring: Boolean get() = detector.isMonitoring

    private val profile get() = store.profile(userID)
    private val carType get() = profile?.carType ?: CarType.sedan

    fun start(tripID: String) {
        store.update { data ->
            data.copy(trips = data.trips.map { trip ->
                when {
                    trip.id == tripID -> trip.copy(isActive = true, startedAt = nowSeconds())
                    trip.ownerID == userID && trip.isActive -> trip.copy(isActive = false, startedAt = null)
                    else -> trip
                }
            })
        }
        driving.speedLimits?.setOfflineRoads(store.trip(tripID)?.tripPack?.roads ?: emptyList())
        detector.startMonitoring(carType)
        if (driving.scenario == null) driving.startLive(background = profile?.autoDetectDrives ?: true)
    }

    /** A trip with no planned route, for short drives. */
    fun startQuickTrip() {
        val trip = Trip(ownerID = userID, origin = "Current location", destination = "Quick drive",
            startDate = nowSeconds(), endDate = nowSeconds() + 12 * 3_600)
        store.insertTrip(trip)
        start(trip.id)
    }

    /** Switching cars mid-drive re-tunes crash detection to the new vehicle type. */
    fun changeVehicle() {
        if (!detector.isMonitoring) return
        detector.stopMonitoring()
        detector.startMonitoring(carType)
    }

    fun end(tripID: String) {
        store.updateTrip(tripID) { it.copy(isActive = false, startedAt = null) }
        detector.stopMonitoring()
        if (driving.mode == DrivingMonitor.Mode.Live) driving.stop()
    }

    /** After relaunch an active trip is restored from disk but nothing is running yet. */
    fun resumeIfNeeded(activeTrip: Trip?) {
        activeTrip ?: return
        if (!detector.isMonitoring) detector.startMonitoring(carType)
        if (!driving.isActive) driving.startLive(background = profile?.autoDetectDrives ?: true)
    }

    fun startDemo(scenario: DriveScenario) {
        driving.startDemo(scenario)
        conditions.override(scenario.weather)
    }

    suspend fun stopDemo(location: LocationService) {
        driving.stop()
        conditions.override(null)
        conditions.refresh(location.location, force = true)
    }

    fun simulateCrash() = detector.simulateCrash()
}
