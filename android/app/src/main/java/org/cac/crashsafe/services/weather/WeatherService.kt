package org.cac.crashsafe.services.weather

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.driving.WeatherCondition
import org.cac.crashsafe.core.driving.WeatherSnapshot
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.services.location.Here
import org.cac.crashsafe.services.net.Http
import java.io.IOException
import java.util.Locale

interface WeatherService {
    suspend fun current(lat: Double, lon: Double): WeatherSnapshot
}

/** Live conditions from Open-Meteo (free, no API key). Apple Weather has no Android API, so this is the source here. */
class OpenMeteoWeatherService : WeatherService {
    @Serializable
    private data class Response(val current: Current) {
        @Serializable
        data class Current(
            @SerialName("temperature_2m") val temperature: Double,
            @SerialName("is_day") val isDay: Int,
            @SerialName("weather_code") val weatherCode: Int,
            @SerialName("wind_speed_10m") val windSpeed: Double,
            val visibility: Double? = null,
        )
    }

    override suspend fun current(lat: Double, lon: Double): WeatherSnapshot {
        val url = "https://api.open-meteo.com/v1/forecast".toHttpUrl().newBuilder()
            // Rounded to ~1 km: weather doesn't need more, and less precise location leaves the phone.
            .addQueryParameter("latitude", String.format(Locale.US, "%.2f", lat))
            .addQueryParameter("longitude", String.format(Locale.US, "%.2f", lon))
            .addQueryParameter("current", "temperature_2m,is_day,weather_code,wind_speed_10m,visibility")
            .addQueryParameter("temperature_unit", "fahrenheit")
            .addQueryParameter("wind_speed_unit", "mph")
            .build()
        val result = Http.send(Request.Builder().url(url).build(), Http.client(10.0))
        if (!result.isOK) throw IOException("Open-Meteo ${result.status}")
        val current = Http.json.decodeFromString(Response.serializer(), result.text).current
        return WeatherSnapshot(temperatureF = current.temperature, condition = WeatherCondition.ofWmo(current.weatherCode),
            windMph = current.windSpeed, visibilityMiles = current.visibility?.let { it / 1_609.34 }, isDay = current.isDay == 1)
    }
}

/** Fixed conditions for previews and tests. */
class MockWeatherService(var snapshot: WeatherSnapshot = WeatherSnapshot(48.0, WeatherCondition.rain, 9.0, 4.0, isDay = false)) : WeatherService {
    override suspend fun current(lat: Double, lon: Double): WeatherSnapshot = snapshot
}

/** Current weather at the driver's location, refreshed when they move or every 15 minutes. */
class ConditionsStore(private val service: WeatherService) {
    var weather by mutableStateOf<WeatherSnapshot?>(null)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var failed by mutableStateOf(false)
        private set

    private var lastFetch: Pair<Here, Double>? = null

    /** Night if the weather service says so, otherwise by the clock. */
    val isNight: Boolean
        get() {
            weather?.let { return !it.isDay }
            val hour = Formats.hour()
            return hour < 6 || hour >= 20
        }

    val advice: DrivingAdvice get() = DrivingAdvice.make(weather, isNight)

    suspend fun refresh(location: Here?, force: Boolean = false) {
        location ?: return
        val last = lastFetch
        if (!force && last != null &&
            TransportFeatures.haversine(last.first.latitude, last.first.longitude, location.latitude, location.longitude) < 5_000 &&
            nowSeconds() - last.second < 15 * 60) return
        isLoading = weather == null
        try {
            weather = service.current(location.latitude, location.longitude)
            lastFetch = location to nowSeconds()
            failed = false
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = weather == null
        } finally {
            isLoading = false
        }
    }

    /** Demo scenarios supply their own conditions. */
    fun override(snapshot: WeatherSnapshot?) {
        weather = snapshot
        lastFetch = null
    }
}
