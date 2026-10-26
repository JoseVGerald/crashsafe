package org.cac.crashsafe.core.driving

import org.cac.crashsafe.core.util.nowSeconds

enum class WeatherCondition(val label: String) {
    clear("Clear"),
    partlyCloudy("Partly cloudy"),
    cloudy("Cloudy"),
    fog("Fog"),
    drizzle("Drizzle"),
    rain("Rain"),
    heavyRain("Heavy rain"),
    freezingRain("Freezing rain"),
    snow("Snow"),
    thunderstorm("Thunderstorm");

    fun systemImage(isDay: Boolean): String = when (this) {
        clear -> if (isDay) "sun.max.fill" else "moon.stars.fill"
        partlyCloudy -> if (isDay) "cloud.sun.fill" else "cloud.moon.fill"
        cloudy -> "cloud.fill"
        fog -> "cloud.fog.fill"
        drizzle -> "cloud.drizzle.fill"
        rain -> "cloud.rain.fill"
        heavyRain -> "cloud.heavyrain.fill"
        freezingRain -> "cloud.sleet.fill"
        snow -> "cloud.snow.fill"
        thunderstorm -> "cloud.bolt.rain.fill"
    }

    /** Approximate tire–road friction used for stopping distances. */
    val roadFriction: Double
        get() = when (this) {
            clear, partlyCloudy, cloudy -> 0.7
            fog, drizzle -> 0.55
            rain, thunderstorm -> 0.45
            heavyRain -> 0.4
            snow -> 0.25
            freezingRain -> 0.15
        }

    /** Share of the posted limit that's sensible in these conditions. */
    val speedFactor: Double
        get() = when (this) {
            clear, partlyCloudy, cloudy -> 1.0
            drizzle -> 0.9
            rain -> 0.85
            fog, heavyRain, thunderstorm -> 0.75
            snow -> 0.6
            freezingRain -> 0.5
        }

    val isWet: Boolean get() = roadFriction < 0.7

    companion object {
        /** WMO weather interpretation codes (used by Open-Meteo). */
        fun ofWmo(code: Int): WeatherCondition = when (code) {
            0 -> clear
            1, 2 -> partlyCloudy
            3 -> cloudy
            45, 48 -> fog
            51, 53, 55 -> drizzle
            56, 57, 66, 67 -> freezingRain
            61, 63, 80, 81 -> rain
            65, 82 -> heavyRain
            in 71..77, 85, 86 -> snow
            in 95..99 -> thunderstorm
            else -> cloudy
        }
    }
}

data class WeatherSnapshot(
    val temperatureF: Double,
    val condition: WeatherCondition,
    val windMph: Double,
    val visibilityMiles: Double?,
    val isDay: Boolean,
    val fetchedAt: Double = nowSeconds(),
)
