package org.cac.crashsafe.model

import kotlinx.serialization.Serializable
import org.cac.crashsafe.core.crash.ImpactReport
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.roads.RoadWay
import org.cac.crashsafe.core.util.newID
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.core.util.roundToIntHalfAway

// Auth

/** The signed-in account, independent of which AuthService produced it. */
@Serializable
data class AuthUser(val id: String, val name: String, val email: String) {
    val firstName: String get() = name.split(" ").firstOrNull { it.isNotEmpty() } ?: "there"
}

// Driver profile

@Serializable
enum class CarType(val label: String) {
    sedan("Sedan"), suv("SUV"), truck("Truck"), minivan("Minivan"), hatchback("Hatchback"),
    coupe("Coupe"), ev("EV"), motorcycle("Motorcycle"), other("Other");

    val systemImage: String
        get() = when (this) {
            suv, minivan -> "suv.side.fill"
            truck -> "truck.pickup.side.fill"
            ev -> "bolt.car.fill"
            motorcycle -> "motorcycle"
            else -> "car.side.fill"
        }
}

/** How Pulse should coach this driver. Drives the tone of every safety message. */
@Serializable
enum class CoachingStyle(val title: String, val subtitle: String, val systemImage: String) {
    /** Numbers and consequences: stopping distance, time saved vs. risk. */
    logical("Give me the facts", "Stopping distances, numbers and clear consequences.", "chart.bar.xaxis"),
    /** The people and things that matter to them. */
    emotional("Remind me what matters", "A calm nudge about the people waiting for you.", "heart.fill");

    companion object {
        /**
         * Picks the style from the About-you answers: people in the car, nerves and past crashes point to a calm,
         * people-first nudge; building experience, driving for work and confidence point to the facts. Ties go to
         * the facts. Returns the reasons that decided it, in plain words, so the choice is never a mystery.
         */
        fun recommended(experience: DrivingExperience, passengers: UsualPassengers?, feeling: DrivingFeeling?,
                        pastCrash: PastCrash?, purpose: DrivingPurpose?): Pair<CoachingStyle, List<String>> {
            val heart = mutableListOf<Pair<Int, String>>()
            val facts = mutableListOf<Pair<Int, String>>()
            when (passengers) {
                UsualPassengers.kids -> heart.add(2 to "kids ride with you")
                UsualPassengers.adults -> heart.add(1 to "people often ride with you")
                else -> {}
            }
            when (feeling) {
                DrivingFeeling.nervous -> heart.add(2 to "driving makes you nervous")
                DrivingFeeling.confident -> facts.add(1 to "you feel confident behind the wheel")
                else -> {}
            }
            when (pastCrash) {
                PastCrash.serious -> heart.add(2 to "you've been through a serious crash")
                PastCrash.minor -> heart.add(1 to "you've been in a crash before")
                else -> {}
            }
            when (purpose) {
                DrivingPurpose.work -> facts.add(1 to "you drive for work")
                DrivingPurpose.family -> heart.add(1 to "you drive for your family")
                else -> {}
            }
            if (experience == DrivingExperience.learner || experience == DrivingExperience.newDriver) {
                facts.add(1 to "you're still building experience")
            }
            val heartScore = heart.sumOf { it.first }
            val factsScore = facts.sumOf { it.first }
            val (style, why) = if (heartScore > factsScore) emotional to heart else logical to facts
            return style to why.sortedByDescending { it.first }.take(2).map { it.second }
        }
    }
}

@Serializable
enum class DrivingExperience(val label: String) {
    learner("Permit"), newDriver("< 2 yrs"), experienced("2–10 yrs"), veteran("10+ yrs")
}

// About you (onboarding)
// Each answer changes how Pulse helps (who may be in the car after a crash, how to calm you, which
// guidance comes first), and together they pick the coaching style. Stored on the phone only.

@Serializable
enum class AgeBand(val label: String) {
    teen("16–19"), young("20–24"), adult("25–44"), midlife("45–64"), senior("65+");

    companion object {
        fun of(age: Int): AgeBand? = when {
            age < 0 -> null
            age < 20 -> teen
            age < 25 -> young
            age < 45 -> adult
            age < 65 -> midlife
            else -> senior
        }
    }
}

interface AboutYouOption {
    val label: String
    val systemImage: String
}

@Serializable
enum class DrivingPurpose(override val label: String, override val systemImage: String) : AboutYouOption {
    commute("Commute or school", "building.2.fill"),
    work("Work or rideshare", "briefcase.fill"),
    family("Errands and family", "cart.fill"),
    roadTrips("Long road trips", "road.lanes"),
}

@Serializable
enum class UsualPassengers(override val label: String, override val systemImage: String) : AboutYouOption {
    alone("Just me", "person.fill"),
    kids("Kids", "figure.and.child.holdinghands"),
    adults("Other adults", "person.2.fill"),
}

@Serializable
enum class DrivingFeeling(override val label: String, override val systemImage: String) : AboutYouOption {
    confident("Confident", "hand.thumbsup.fill"),
    okay("Mostly fine", "face.smiling"),
    nervous("Nervous", "heart.text.square.fill"),
}

@Serializable
enum class PastCrash(override val label: String, override val systemImage: String) : AboutYouOption {
    none("Never", "checkmark.shield.fill"),
    minor("A minor one", "car.side.rear.and.collision.and.car.side.front"),
    serious("A serious one", "cross.case.fill"),
}

/**
 * The big US auto insurers, for one-tap setup. The claims number is prefilled and can be edited;
 * it is the number each company lists for reporting an auto claim (check your insurance card).
 */
data class InsurerPreset(val name: String, val claimsPhone: String) {
    companion object {
        val all = listOf(
            InsurerPreset("State Farm", "(800) 732-5246"),
            InsurerPreset("GEICO", "(800) 841-3000"),
            InsurerPreset("Progressive", "(800) 776-4737"),
            InsurerPreset("Allstate", "(800) 255-7828"),
            InsurerPreset("USAA", "(800) 531-8722"),
            InsurerPreset("Liberty Mutual", "(800) 225-2467"),
            InsurerPreset("Farmers", "(800) 435-7764"),
            InsurerPreset("Nationwide", "(800) 421-3535"),
            InsurerPreset("Travelers", "(800) 252-4633"),
            InsurerPreset("American Family", "(800) 692-6326"),
        )
    }
}

@Serializable
data class Vehicle(
    val id: String = newID(),
    val make: String,
    val model: String,
    val year: Int? = null,
    val type: CarType = CarType.sedan,
    val colorName: String = "",
    val plate: String = "",
    val isPrimary: Boolean = false,
    val createdAt: Double = nowSeconds(),
) {
    val displayName: String
        get() {
            val base = listOf(make, model).filter { it.isNotEmpty() }.joinToString(" ")
            if (year == null) return base.ifEmpty { type.label }
            return "$year $base"
        }

    val detail: String get() = listOf(type.label, colorName, plate).filter { it.isNotEmpty() }.joinToString(" · ")
}

@Serializable
data class FamilyContact(
    val id: String = newID(),
    val name: String,
    val phone: String,
    val relationship: String = "",
    val createdAt: Double = nowSeconds(),
)

/** One per user. Stored on-device only. */
@Serializable
data class Profile(
    val ownerID: String,
    val medicalNotes: String = "",
    val bloodType: String = "",
    val insurer: String = "",
    val policyNumber: String = "",
    val insurerPhone: String = "",
    val coachingStyle: CoachingStyle = CoachingStyle.logical,
    val experience: DrivingExperience = DrivingExperience.newDriver,
    val onboardingCompleted: Boolean = false,
    /** Keep monitoring drives in the background (CarPlay-style coaching). */
    val autoDetectDrives: Boolean = true,
    // About-you answers; null until answered.
    val ageBand: AgeBand? = null,
    val drivingPurpose: DrivingPurpose? = null,
    val passengers: UsualPassengers? = null,
    val drivingFeeling: DrivingFeeling? = null,
    val pastCrash: PastCrash? = null,
    val familyContacts: List<FamilyContact> = emptyList(),
    val vehicles: List<Vehicle> = emptyList(),
) {
    /** The coaching style the About-you answers point to, with the reasons. */
    val recommendedCoaching: Pair<CoachingStyle, List<String>>
        get() = CoachingStyle.recommended(experience, passengers, drivingFeeling, pastCrash, drivingPurpose)

    val sortedContacts: List<FamilyContact> get() = familyContacts.sortedBy { it.createdAt }

    val sortedVehicles: List<Vehicle>
        get() = vehicles.sortedWith(compareBy<Vehicle>({ if (it.isPrimary) 0 else 1 }, { it.createdAt }))

    val primaryVehicle: Vehicle? get() = sortedVehicles.firstOrNull()

    /** Detection tuning falls back to a sedan when no vehicle is set. */
    val carType: CarType get() = primaryVehicle?.type ?: CarType.sedan

    fun makingPrimary(vehicleID: String): Profile =
        copy(vehicles = vehicles.map { it.copy(isPrimary = it.id == vehicleID) })

    fun removingVehicle(vehicleID: String): Profile {
        val wasPrimary = vehicles.firstOrNull { it.id == vehicleID }?.isPrimary == true
        val rest = copy(vehicles = vehicles.filter { it.id != vehicleID })
        val next = rest.sortedVehicles.firstOrNull()
        return if (wasPrimary && next != null) rest.makingPrimary(next.id) else rest
    }

    /** Fills in what a health import found, without overwriting what the person typed. Returns what changed. */
    fun applying(bloodType: String?, ageBand: AgeBand?, medications: List<String>): Pair<Profile, List<String>> {
        var profile = this
        val filled = mutableListOf<String>()
        if (bloodType != null && profile.bloodType != bloodType) {
            profile = profile.copy(bloodType = bloodType)
            filled.add("blood type $bloodType")
        }
        if (ageBand != null && profile.ageBand == null) {
            profile = profile.copy(ageBand = ageBand)
            filled.add("age")
        }
        val new = medications.filter { !profile.medicalNotes.contains(it, ignoreCase = true) }
        if (new.isNotEmpty()) {
            val line = "Medications: " + new.joinToString(", ")
            val notes = profile.medicalNotes.trim()
            profile = profile.copy(medicalNotes = if (notes.isEmpty()) line else notes + "\n" + line)
            filled.add(if (new.size == 1) "1 medication" else "${new.size} medications")
        }
        return profile to filled
    }
}

// Trips

@Serializable
enum class TripPackStatus(val label: String) {
    notDownloaded("Not downloaded"), downloading("Downloading…"), ready("Ready for offline"), failed("Download failed")
}

/** A hospital, police station or tow company. */
@Serializable
data class HelpPlace(
    val name: String,
    val phone: String,
    val category: Category,
    val latitude: Double,
    val longitude: Double,
) {
    @Serializable
    enum class Category(val title: String, val systemImage: String) {
        hospital("Hospital", "cross.fill"),
        police("Police", "shield.lefthalf.filled"),
        towing("Tow truck", "car.side.fill"),
    }

    val id: String get() = "${category.name}|$name|$latitude"

    fun distanceMiles(lat: Double, lon: Double): Double =
        TransportFeatures.haversine(latitude, longitude, lat, lon) / 1_609.34
}

/** Offline data for one trip, downloaded before the signal drops. */
@Serializable
data class TripPack(
    val towCompanies: List<HelpPlace>,
    val hospitals: List<HelpPlace>,
    val police: List<HelpPlace>,
    /** Pre-generated guides/scripts the offline assistant can read. */
    val guides: List<String>,
    val generatedAt: Double,
    /** Roads along the route with their speed limits (OpenStreetMap), so coaching works with no signal. */
    val roads: List<RoadWay>? = null,
) {
    val allPlaces: List<HelpPlace> get() = hospitals + police + towCompanies

    val summary: String
        get() = "${towCompanies.size} tow · ${hospitals.size} hospitals · ${police.size} police · ${guides.size} guides" +
            (roads?.let { if (it.isEmpty()) "" else " · speed limits" } ?: "")

    companion object {
        val standardGuides = listOf("After a crash: the first 10 minutes", "Talking to a tow driver", "Insurance: facts only")
    }
}

@Serializable
data class Trip(
    val id: String = newID(),
    val ownerID: String,
    val origin: String,
    val destination: String,
    val startDate: Double,
    val endDate: Double,
    val createdAt: Double = nowSeconds(),
    val isActive: Boolean = false,
    val startedAt: Double? = null,
    val tripPackStatus: TripPackStatus = TripPackStatus.notDownloaded,
    val tripPackUpdatedAt: Double? = null,
    val tripPackSummary: String? = null,
    /** So help along the route works with no signal. */
    val tripPack: TripPack? = null,
    val originLatitude: Double? = null,
    val originLongitude: Double? = null,
    val destinationLatitude: Double? = null,
    val destinationLongitude: Double? = null,
    val routeDistanceMeters: Double? = null,
    val routeTravelSeconds: Double? = null,
) {
    val routeLabel: String get() = "$origin → $destination"

    val originCoordinate: Pair<Double, Double>?
        get() = if (originLatitude != null && originLongitude != null) originLatitude to originLongitude else null

    val destinationCoordinate: Pair<Double, Double>?
        get() = if (destinationLatitude != null && destinationLongitude != null) destinationLatitude to destinationLongitude else null

    val routeSummary: String?
        get() {
            val distance = routeDistanceMeters ?: return null
            val seconds = routeTravelSeconds ?: return null
            return RouteFormat.summary(distance, seconds)
        }
}

object RouteFormat {
    /** "120 mi · 1 hr, 50 min" (as iOS formats a route). */
    fun summary(distanceMeters: Double, seconds: Double): String {
        val miles = (distanceMeters / 1_609.344).roundToIntHalfAway()
        return "$miles mi · ${duration(seconds)}"
    }

    fun duration(seconds: Double): String {
        val total = (seconds / 60).roundToIntHalfAway()
        val hours = total / 60
        val minutes = total % 60
        return when {
            hours > 0 && minutes > 0 -> "$hours hr, $minutes min"
            hours > 0 -> "$hours hr"
            else -> "$minutes min"
        }
    }
}

// Check-ins

@Serializable
enum class CheckInOutcome(val label: String, val shortLabel: String, val systemImage: String) {
    /** Driver tapped "I'm OK" → conscious path. */
    ok("You said you were OK", "You were OK", "checkmark.circle.fill"),
    /** Driver tapped "I need help" → 911 prompt + family alert + assistant. */
    needsHelp("You asked for help", "Asked for help", "cross.case.fill"),
    /** Countdown ran out → unconscious path, family alerted. */
    noResponse("No response — family alerted", "No response", "bell.badge.fill");

    /** How the check-in ended, as stated in the report. */
    val reportLabel: String
        get() = when (this) {
            ok -> "driver answered \"I'm okay\""
            needsHelp -> "driver asked for help"
            noResponse -> "no answer from the driver"
        }
}

/**
 * What the phone knew when the crash happened, kept with the check-in so the impact report can be opened
 * later (Home → last check-in). Stays on the phone.
 */
@Serializable
data class CrashSnapshot(
    val date: Double,
    val peakG: Double,
    val speedDropMPH: Double? = null,
    val impact: ImpactReport? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val accuracyMeters: Double? = null,
    val street: String? = null,
    val place: String? = null,
    /** e.g. "Rain, 48°F, visibility 2 mi, dark". */
    val weather: String? = null,
    val isSimulated: Boolean,
)

@Serializable
data class CheckInRecord(
    val id: String = newID(),
    val ownerID: String,
    val date: Double = nowSeconds(),
    val outcome: CheckInOutcome,
    val wasSimulated: Boolean,
    val snapshot: CrashSnapshot? = null,
    // Filled in by the driver on the impact report, for the police/insurer copy.
    val otherDriver: String = "",
    val otherInsurance: String = "",
    val otherPlate: String = "",
    val policeReportNumber: String = "",
)

// Assistant

data class ChatMessage(val role: Role, val text: String, val id: String = newID(), val date: Double = nowSeconds()) {
    enum class Role { user, assistant }
}

/** Everything stored on the phone, as one document. */
@Serializable
data class AppData(
    val profiles: List<Profile> = emptyList(),
    val trips: List<Trip> = emptyList(),
    val checkIns: List<CheckInRecord> = emptyList(),
)
