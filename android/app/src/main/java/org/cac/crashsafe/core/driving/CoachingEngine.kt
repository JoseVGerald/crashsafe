package org.cac.crashsafe.core.driving

import org.cac.crashsafe.core.roads.RoadFeatures
import org.cac.crashsafe.core.roads.RoadSegment
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.DrivingExperience
import kotlin.math.max
import kotlin.math.sqrt

/** A spoken/visual nudge from Pulse while driving. */
data class CoachingMessage(
    val title: String,
    val body: String,
    val severity: Severity,
    /**
     * Pulse speaks out loud when the driver is over the speed limit, and once on entering an area that
     * needs extra care (residential streets, parking lots…); everything else is on screen only.
     */
    val speaksAloud: Boolean = false,
    /** Don't say the same thing again within this many seconds. */
    val repeatAfter: Double = 60.0,
) {
    enum class Severity { positive, caution, warning }
}

/**
 * Turns driving data + the driver profile into a short message in the style that works for them.
 *
 * AI TEAM: this is the rules-based proof of concept. A model can replace `message(...)` later;
 * keep the same inputs (it's everything the model needs) and outputs.
 */
object CoachingEngine {
    data class Input(
        val snapshot: DrivingSnapshot,
        val advice: DrivingAdvice,
        val weather: WeatherSnapshot?,
        val isNight: Boolean,
        val style: CoachingStyle,
        val experience: DrivingExperience,
        /** First family contact, used by the emotional style. */
        val lovedOne: String?,
    )

    /**
     * How far over the limit before Pulse speaks: a little room for speedometer/GPS wobble, more when
     * the limit is only the typical one for that kind of road.
     */
    fun speakingThreshold(limit: Double, isPosted: Boolean): Double = limit + if (isPosted) 4 else 9

    fun message(input: Input): CoachingMessage {
        val snapshot = input.snapshot
        val limit = snapshot.speedLimitMPH
        if (limit != null && snapshot.speedMPH > speakingThreshold(limit, snapshot.speedLimitIsPosted)) {
            return speeding(input, limit)
        }
        val comparison = DrivingComparison.make(snapshot, input.advice, isDriving = true)
        val friction = input.weather?.condition?.roadFriction ?: 0.7
        val place = (if (input.isNight) "dark " else "") + (snapshot.roadSegment?.title?.lowercase() ?: snapshot.environment.label)

        when (comparison.status) {
            DrivingComparison.Status.tooFast, DrivingComparison.Status.caution -> {
                val recommended = comparison.recommendedMaxMPH
                if (recommended == null || snapshot.speedMPH <= recommended + 2) return harshEvents(input)
                val now = stoppingDistanceFeet(snapshot.speedMPH, friction)
                val safer = stoppingDistanceFeet(recommended, friction)
                val severity = if (comparison.status == DrivingComparison.Status.tooFast) CoachingMessage.Severity.warning
                else CoachingMessage.Severity.caution
                return when (input.style) {
                    CoachingStyle.logical -> {
                        val delay = minutesLost(10.0, snapshot.speedMPH, recommended)
                        var body = "At ${snapshot.speedMPH.toInt()} mph on a $place, you need about $now ft to stop"
                        body += if (input.weather?.condition?.isWet == true) " on wet pavement" else ""
                        body += if (input.isNight) " — low beams only light ~200 ft." else "."
                        body += " At ${recommended.toInt()} mph that drops to $safer ft. Over 10 miles you'd lose about $delay min."
                        CoachingMessage("Slow to ${recommended.toInt()} mph", body, severity)
                    }
                    CoachingStyle.emotional -> {
                        val who = input.lovedOne ?: "the people who love you"
                        val body = "${capitalized(who)} would rather you get home a few minutes late. " +
                            "On a $place, watch for ${snapshot.environment.hazard}. Easing to ${recommended.toInt()} mph gives you room to react."
                        CoachingMessage("Let's take it easy", body, severity)
                    }
                }
            }
            DrivingComparison.Status.noData, DrivingComparison.Status.onTrack -> {
                areaCaution(snapshot)?.let { return it }
                if (snapshot.hardBrakes >= 3) return harshEvents(input)
                return when (input.style) {
                    CoachingStyle.logical -> CoachingMessage(
                        "Right on target",
                        "${snapshot.speedMPH.toInt()} mph suits these conditions. Keep a ${input.advice.followingSeconds}-second gap to the car ahead.",
                        CoachingMessage.Severity.positive)
                    CoachingStyle.emotional -> CoachingMessage(
                        "You're driving beautifully",
                        "Calm and steady — exactly how you make it home safe${if (input.isNight) " tonight" else ""}.",
                        CoachingMessage.Severity.positive)
                }
            }
        }
    }

    /** Entering a residential street, parking lot, gravel road…: say once to be extra careful there. */
    fun areaCaution(snapshot: DrivingSnapshot): CoachingMessage? {
        val segment = snapshot.roadSegment ?: return null
        if (segment.caution != RoadSegment.Caution.high && RoadFeatures.unpaved !in snapshot.roadFeatures) return null
        var body = segment.advice
        if (RoadFeatures.bridge in snapshot.roadFeatures) body += " Bridges ice first in the cold."
        val title = if (segment == RoadSegment.residential) "Residential area: be extra careful" else segment.title
        return CoachingMessage(title, body, CoachingMessage.Severity.caution, speaksAloud = true, repeatAfter = 300.0)
    }

    /** "Imagine…" — what speeding would turn a near miss into, from the car's real speed and the road. */
    fun speeding(input: Input, limit: Double): CoachingMessage {
        val snapshot = input.snapshot
        val speed = snapshot.speedMPH
        val friction = input.weather?.condition?.roadFriction ?: 0.7
        val hazardDistance = stoppingDistanceFeet(limit, friction)
        val impact = impactSpeedMPH(speed, hazardDistance.toDouble(), friction)
        val limitText = if (snapshot.speedLimitIsPosted) "a ${limit.toInt()}" else "a road that's usually ${limit.toInt()}"
        val place = (if (input.isNight) "dark " else "") + (snapshot.roadSegment?.title?.lowercase() ?: snapshot.environment.label)
        val over = speed - limit
        val severity = if (over >= max(7.0, limit * 0.15)) CoachingMessage.Severity.warning else CoachingMessage.Severity.caution
        val title = "Slow to ${limit.toInt()} mph"
        val what = hazard(snapshot.environment)

        val consequence = when (snapshot.environment) {
            RoadEnvironment.city -> "At ${limit.toInt()} you'd stop in time. At ${speed.toInt()} you'd still hit them at about $impact mph" +
                if (impact >= 20) " — ${pedestrianRisk(impact.toDouble())}." else "."
            RoadEnvironment.highway, RoadEnvironment.forest ->
                "At ${limit.toInt()} you'd stop in time. At ${speed.toInt()} you'd hit at about $impact mph — " +
                    "like falling ${storiesEquivalent(impact.toDouble())}."
        }

        return when (input.style) {
            CoachingStyle.logical -> {
                val body = "You're doing ${speed.toInt()} in $limitText on a $place. Imagine $what $hazardDistance ft ahead. " +
                    consequence + " You need ${stoppingDistanceFeet(speed, friction)} ft to stop at this speed."
                CoachingMessage(title, body, severity, speaksAloud = true)
            }
            CoachingStyle.emotional -> {
                val who = input.lovedOne ?: "the people who love you"
                val body = "${capitalized(who)} is waiting for you to get home. " +
                    "Imagine $what right now. At ${limit.toInt()} you'd stop in time; at ${speed.toInt()} you wouldn't. " +
                    "Please ease back to ${limit.toInt()}."
                CoachingMessage(title, body, severity, speaksAloud = true)
            }
        }
    }

    fun hazard(environment: RoadEnvironment): String = when (environment) {
        RoadEnvironment.city -> "a child running out from between parked cars"
        RoadEnvironment.highway -> "traffic stopped just past a curve"
        RoadEnvironment.forest -> "a deer stepping onto the road"
    }

    /**
     * Speed (mph) at which the car reaches an obstacle `obstacleFeet` ahead, after 1.5 s of reaction
     * and hard braking at friction μ. 0 means it stops in time.
     */
    fun impactSpeedMPH(mph: Double, obstacleFeet: Double, friction: Double): Int {
        val v = mph * 0.44704
        val distance = obstacleFeet / 3.28084
        val braking = distance - v * 1.5
        if (braking <= 0) return mph.roundToIntHalfAway()
        val squared = v * v - 2 * friction * 9.81 * braking
        return if (squared <= 0) 0 else (sqrt(squared) / 0.44704).roundToIntHalfAway()
    }

    /**
     * Risk of death for a pedestrian struck at this speed (AAA Foundation, Tefft 2011:
     * 10% at 23 mph, 25% at 32, 50% at 42, 75% at 50, 90% at 58).
     */
    fun pedestrianRisk(impactMPH: Double): String {
        val curve = listOf(0.0 to 0.0, 23.0 to 10.0, 32.0 to 25.0, 42.0 to 50.0, 50.0 to 75.0, 58.0 to 90.0, 80.0 to 98.0)
        var risk = 98.0
        for ((a, b) in curve.zipWithNext()) {
            if (impactMPH <= b.first) {
                risk = a.second + (b.second - a.second) * (impactMPH - a.first) / (b.first - a.first)
                break
            }
        }
        val oneIn = max(1, (100 / max(risk, 1.0)).roundToIntHalfAway())
        return if (oneIn <= 1) "most people hit that hard don't survive" else "about 1 in $oneIn people hit that hard don't survive"
    }

    /** The fall with the same impact speed: h = v² / 2g, in stories (~3 m each). */
    fun storiesEquivalent(impactMPH: Double): String {
        val v = impactMPH * 0.44704
        val stories = (v * v / (2 * 9.81) / 3).roundToIntHalfAway()
        return if (stories <= 1) "off a one-story roof" else "off a $stories-story building"
    }

    private fun harshEvents(input: Input): CoachingMessage {
        val count = input.snapshot.hardBrakes
        return when (input.style) {
            CoachingStyle.logical -> CoachingMessage(
                "$count hard brakes",
                "Hard braking means you're following too close. A ${input.advice.followingSeconds}-second gap gives you time to slow down smoothly.",
                CoachingMessage.Severity.caution)
            CoachingStyle.emotional -> CoachingMessage(
                "Give yourself some space",
                "A little more room ahead means fewer surprises — and a calmer drive for everyone in the car.",
                CoachingMessage.Severity.caution)
        }
    }

    /** Reaction distance (1.5 s) + braking distance v² / (2 μ g), in feet. */
    fun stoppingDistanceFeet(mph: Double, friction: Double): Int {
        val v = mph * 0.44704
        val meters = v * 1.5 + (v * v) / (2 * friction * 9.81)
        return ((meters * 3.28084 / 5).roundToIntHalfAway() * 5)
    }

    fun minutesLost(miles: Double, fast: Double, slow: Double): Int {
        if (fast <= 0 || slow <= 0) return 0
        return max(1, ((miles / slow - miles / fast) * 60).roundToIntHalfAway())
    }

    private fun capitalized(text: String): String = text.take(1).uppercase() + text.drop(1)
}
