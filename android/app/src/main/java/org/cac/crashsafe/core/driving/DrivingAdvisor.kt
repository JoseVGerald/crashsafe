package org.cac.crashsafe.core.driving

import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.core.util.roundedHalfAway
import kotlin.math.max

/** How to drive right now, given weather and light. Pure logic — easy to test and to tune. */
data class DrivingAdvice(
    val headline: String,
    /** Why the headline matters right now, in one plain sentence. */
    val reason: String,
    val speedFactor: Double,
    val followingSeconds: Int,
    val tips: List<Tip>,
) {
    data class Tip(val systemImage: String, val text: String) {
        val id: String get() = text
    }

    val speedReductionPercent: Int get() = ((1 - speedFactor) * 100).roundToIntHalfAway()

    companion object {
        fun make(weather: WeatherSnapshot?, isNight: Boolean): DrivingAdvice {
            val condition = weather?.condition ?: WeatherCondition.clear
            var factor = condition.speedFactor
            if (isNight) factor -= 0.05
            val visibility = weather?.visibilityMiles
            if (visibility != null && visibility < 1) factor -= 0.1
            factor = max(0.45, factor)

            var following = 3
            if (condition.isWet) following = if (condition.roadFriction < 0.3) 8 else 5
            if (isNight) following += 1

            val tips = mutableListOf<Tip>()
            if (factor < 1) {
                tips.add(Tip("gauge.with.dots.needle.33percent", "Drive about ${((1 - factor) * 100).roundToIntHalfAway()}% under the limit"))
            } else {
                tips.add(Tip("gauge.with.dots.needle.50percent", "Normal speeds are fine"))
            }
            tips.add(Tip("car.rear.and.tire.marks", "Keep a $following-second gap"))
            if (isNight || condition == WeatherCondition.fog || condition.isWet) {
                tips.add(Tip("headlight.low.beam.fill", "Headlights on"))
            }
            if (condition == WeatherCondition.snow || condition == WeatherCondition.freezingRain) {
                tips.add(Tip("snowflake", "Brake early and gently"))
            } else if (condition.isWet && condition != WeatherCondition.fog) {
                tips.add(Tip("drop.fill", "Avoid sudden braking"))
            } else if (condition == WeatherCondition.fog) {
                tips.add(Tip("eye.fill", "Low beams, not high beams"))
            }
            val wind = weather?.windMph
            if (wind != null && wind > 25) {
                tips.add(Tip("wind", "Strong gusts — both hands on the wheel"))
            }

            val light = if (isNight) " at night" else ""
            val headline = when (condition) {
                WeatherCondition.clear, WeatherCondition.partlyCloudy, WeatherCondition.cloudy ->
                    if (isNight) "Dark roads — stay alert" else "Good driving conditions"
                WeatherCondition.fog -> "Low visibility$light"
                WeatherCondition.drizzle, WeatherCondition.rain -> "Wet roads$light"
                WeatherCondition.heavyRain, WeatherCondition.thunderstorm -> "Heavy rain$light — slow down"
                WeatherCondition.snow -> "Snow on the roads"
                WeatherCondition.freezingRain -> "Ice risk — drive only if you must"
            }

            var reason = when (condition) {
                WeatherCondition.clear, WeatherCondition.partlyCloudy, WeatherCondition.cloudy ->
                    if (isNight) "It's dark out, so people, animals and debris are harder to see and other drivers react later."
                    else "Roads look clear and dry. Keep your eyes up and your phone down."
                WeatherCondition.fog -> "Fog cuts how far ahead you can see, so hazards appear with less warning."
                WeatherCondition.drizzle, WeatherCondition.rain -> "Wet pavement takes longer to stop on, especially in the first rain after a dry spell."
                WeatherCondition.heavyRain, WeatherCondition.thunderstorm -> "Heavy rain hides lane lines and can make tires hydroplane on standing water."
                WeatherCondition.snow -> "Snow hides lane lines and makes stopping and turning slower than usual."
                WeatherCondition.freezingRain -> "Ice can form where you can't see it, especially on bridges and in shade."
            }
            if (isNight && condition != WeatherCondition.clear && condition != WeatherCondition.partlyCloudy &&
                condition != WeatherCondition.cloudy) {
                reason += " Darkness makes it harder still."
            }

            return DrivingAdvice(headline = headline, reason = reason, speedFactor = factor, followingSeconds = following, tips = tips)
        }
    }
}

/** How the driver's actual behavior compares to the advice. */
data class DrivingComparison(
    val status: Status,
    val recommendedMaxMPH: Double?,
    val message: String,
) {
    enum class Status(val label: String) {
        noData("Not driving"), onTrack("On track"), caution("Ease up"), tooFast("Too fast")
    }

    companion object {
        fun make(snapshot: DrivingSnapshot, advice: DrivingAdvice, isDriving: Boolean): DrivingComparison {
            if (!isDriving) {
                return DrivingComparison(Status.noData, null, "Start a trip to compare your driving with today's conditions.")
            }
            val recommended = snapshot.speedLimitMPH?.let { ((it * advice.speedFactor) / 5).roundedHalfAway() * 5 }
            // Small buffers so normal speedometer wobble doesn't trigger a nag.
            if (recommended != null && snapshot.speedMPH > recommended + 7) {
                return DrivingComparison(Status.tooFast, recommended,
                    "You're at ${snapshot.speedMPH.toInt()} mph. In these conditions, aim for ${recommended.toInt()} or less.")
            }
            if (recommended != null && snapshot.speedMPH > recommended + 2) {
                return DrivingComparison(Status.caution, recommended,
                    "A little over the ${recommended.toInt()} mph we'd suggest right now.")
            }
            if (snapshot.hardBrakes >= 3) {
                return DrivingComparison(Status.caution, recommended,
                    "${snapshot.hardBrakes} hard brakes this drive — leave more room ahead.")
            }
            val limitNote = if (recommended == null) " (speed limit data not available here)" else ""
            return DrivingComparison(Status.onTrack, recommended, "Smooth and steady — matches the conditions$limitNote.")
        }
    }
}
