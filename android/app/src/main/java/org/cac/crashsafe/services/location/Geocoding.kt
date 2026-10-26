package org.cac.crashsafe.services.location

import android.content.Context
import android.location.Address
import android.location.Geocoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.cac.crashsafe.services.net.Http
import java.util.Locale

/** A reverse-geocoded place, in the pieces the app shows. */
data class PlaceDescription(
    /** "Seattle, WA". */
    val shortName: String?,
    /** "1200 5th Ave". */
    val street: String?,
    /** "US-WA", "DE": picks the legal default speed limits for untagged roads. */
    val regionCode: String?,
    /** A name for a dropped pin: the street address or point of interest. */
    val title: String?,
)

/**
 * Android's Geocoder when the phone has one (Google Play services), otherwise OpenStreetMap's Nominatim
 * (free, no key; one request per position the app moves 400 m from).
 */
object Geocoding {
    suspend fun describe(context: Context, lat: Double, lon: Double): PlaceDescription? = withContext(Dispatchers.IO) {
        android(context, lat, lon) ?: nominatim(lat, lon)
    }

    @Suppress("DEPRECATION")
    private fun android(context: Context, lat: Double, lon: Double): PlaceDescription? {
        if (!Geocoder.isPresent()) return null
        val address: Address = runCatching { Geocoder(context, Locale.US).getFromLocation(lat, lon, 1)?.firstOrNull() }.getOrNull()
            ?: return null
        val state = address.adminArea?.let { usStateCodes[it] ?: it.takeIf { s -> s.length == 2 }?.uppercase() }
        val country = address.countryCode?.uppercase()
        val locality = address.locality ?: address.subAdminArea
        val street = address.thoroughfare?.let { t -> address.subThoroughfare?.let { "$it $t" } ?: t }
        val region = if (country == null) null else if (country == "US" && state != null) "US-$state" else country
        val short = listOfNotNull(locality, if (country == "US") state else address.adminArea).joinToString(", ").ifEmpty { null }
        val title = street ?: address.featureName?.takeIf { it != address.subThoroughfare }
        return PlaceDescription(short, street, region, title)
    }

    private suspend fun nominatim(lat: Double, lon: Double): PlaceDescription? = runCatching {
        val url = "https://nominatim.openstreetmap.org/reverse".toHttpUrl().newBuilder()
            .addQueryParameter("format", "jsonv2")
            .addQueryParameter("lat", String.format(Locale.US, "%.5f", lat))
            .addQueryParameter("lon", String.format(Locale.US, "%.5f", lon))
            .addQueryParameter("zoom", "18")
            .addQueryParameter("addressdetails", "1")
            .build()
        val result = Http.send(Request.Builder().url(url).header("Accept-Language", "en").build(), Http.client(8.0))
        if (!result.isOK) return null
        val root = Http.json.parseToJsonElement(result.text).jsonObject
        val address = root["address"]?.jsonObject ?: return null
        fun field(vararg keys: String) = keys.firstNotNullOfOrNull { address[it]?.jsonPrimitive?.content }
        val country = field("country_code")?.uppercase()
        val iso = field("ISO3166-2-lvl4")
        val state = iso?.substringAfter("-")?.takeIf { country == "US" }
        val locality = field("city", "town", "village", "hamlet", "county")
        val road = field("road")
        val street = road?.let { r -> field("house_number")?.let { "$it $r" } ?: r }
        val region = when {
            country == null -> null
            country == "US" && iso != null -> iso
            else -> country
        }
        val short = listOfNotNull(locality, state ?: field("state")).joinToString(", ").ifEmpty { null }
        val title = street ?: root["name"]?.jsonPrimitive?.content?.ifEmpty { null }
        PlaceDescription(short, street, region, title)
    }.getOrNull()

    private val usStateCodes = mapOf(
        "Alabama" to "AL", "Alaska" to "AK", "Arizona" to "AZ", "Arkansas" to "AR", "California" to "CA",
        "Colorado" to "CO", "Connecticut" to "CT", "Delaware" to "DE", "District of Columbia" to "DC", "Florida" to "FL",
        "Georgia" to "GA", "Hawaii" to "HI", "Idaho" to "ID", "Illinois" to "IL", "Indiana" to "IN", "Iowa" to "IA",
        "Kansas" to "KS", "Kentucky" to "KY", "Louisiana" to "LA", "Maine" to "ME", "Maryland" to "MD",
        "Massachusetts" to "MA", "Michigan" to "MI", "Minnesota" to "MN", "Mississippi" to "MS", "Missouri" to "MO",
        "Montana" to "MT", "Nebraska" to "NE", "Nevada" to "NV", "New Hampshire" to "NH", "New Jersey" to "NJ",
        "New Mexico" to "NM", "New York" to "NY", "North Carolina" to "NC", "North Dakota" to "ND", "Ohio" to "OH",
        "Oklahoma" to "OK", "Oregon" to "OR", "Pennsylvania" to "PA", "Rhode Island" to "RI", "South Carolina" to "SC",
        "South Dakota" to "SD", "Tennessee" to "TN", "Texas" to "TX", "Utah" to "UT", "Vermont" to "VT",
        "Virginia" to "VA", "Washington" to "WA", "West Virginia" to "WV", "Wisconsin" to "WI", "Wyoming" to "WY",
        "Puerto Rico" to "PR",
    )
}
