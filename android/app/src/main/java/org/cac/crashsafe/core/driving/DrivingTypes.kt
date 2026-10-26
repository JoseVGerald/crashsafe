package org.cac.crashsafe.core.driving

import org.cac.crashsafe.core.roads.RoadFeatures
import org.cac.crashsafe.core.roads.RoadSegment

enum class RoadEnvironment(val label: String, val hazard: String) {
    city("city street", "pedestrians, cyclists and sudden stops"),
    highway("highway", "spray, hydroplaning and fast-closing traffic"),
    forest("wooded rural road", "deer, blind curves and no streetlights"),
}

/** Scripted drives so the full experience can be shown in the emulator or a parked car. */
enum class DriveScenario(
    val title: String,
    val systemImage: String,
    val environment: RoadEnvironment,
    val speedLimit: Double,
    /** The (slightly too fast) speed the demo driver drifts toward. */
    val cruiseSpeed: Double,
    /** Time of day the demo is set at (shown instead of the real clock). */
    val demoClock: String,
) {
    forestNight("Forest road at night", "tree.fill", RoadEnvironment.forest, 50.0, 58.0, "11:40 PM"),
    cityRushHour("City rush hour", "building.2.fill", RoadEnvironment.city, 30.0, 34.0, "5:30 PM"),
    highwayRain("Highway in the rain", "road.lanes", RoadEnvironment.highway, 65.0, 71.0, "2:15 PM");

    val isNight: Boolean get() = this == forestNight

    val weather: WeatherSnapshot
        get() = when (this) {
            forestNight -> WeatherSnapshot(41.0, WeatherCondition.drizzle, 6.0, 3.0, isDay = false)
            cityRushHour -> WeatherSnapshot(63.0, WeatherCondition.partlyCloudy, 8.0, 10.0, isDay = true)
            highwayRain -> WeatherSnapshot(52.0, WeatherCondition.heavyRain, 17.0, 1.5, isDay = true)
        }
}

data class DrivingSnapshot(
    val speedMPH: Double = 0.0,
    val speedLimitMPH: Double? = null,
    /** True for a posted limit (OpenStreetMap `maxspeed`, TomTom or a demo); false for a typical limit for the road type. */
    val speedLimitIsPosted: Boolean = true,
    val roadName: String? = null,
    /** Residential street, arterial, ramp, gravel… (from the road data). */
    val roadSegment: RoadSegment? = null,
    val roadFeatures: RoadFeatures = RoadFeatures.none,
    val averageSpeedMPH: Double = 0.0,
    val maxSpeedMPH: Double = 0.0,
    val hardBrakes: Int = 0,
    val hardAccelerations: Int = 0,
    val peakG: Double = 0.0,
    val currentG: Double = 0.0,
    val environment: RoadEnvironment = RoadEnvironment.city,
    val elapsed: Double = 0.0,
) {
    val isMoving: Boolean get() = speedMPH > 3
}
