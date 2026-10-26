package org.cac.crashsafe.features.recovery

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.app.AppRouter
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.features.trips.helpTint
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.HelpPlace
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.TripPack
import org.cac.crashsafe.features.profile.ContactRow
import org.cac.crashsafe.services.location.Here
import org.cac.crashsafe.services.trips.PlaceSearch
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.ActionDialog
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.Hairline
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.MapMarker
import org.cac.crashsafe.ui.components.OsmMap
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseOrbDisc
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.StatusRow
import org.cac.crashsafe.ui.components.TopBar
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf
import java.util.Locale

data class RecoveryBanner(val text: String, val icon: String, val tint: Color)

/** Nearby hospitals, police and tow: live from OpenStreetMap when online, else the active trip's pack. */
class NearbyHelpViewModel {
    enum class Source { live, tripPack, none }

    var places by mutableStateOf<List<HelpPlace>>(emptyList())
        private set
    var source by mutableStateOf(Source.none)
        private set
    var isLoading by mutableStateOf(false)
        private set
    private var loadedFor: Here? = null

    suspend fun load(near: Here?, isOnline: Boolean, fallback: TripPack?) {
        if (near == null) {
            useFallback(fallback, null)
            return
        }
        val last = loadedFor
        if (last != null && places.isNotEmpty() && TransportFeatures.haversine(last.latitude, last.longitude, near.latitude, near.longitude) < 300) return
        isLoading = places.isEmpty()
        try {
            val live = if (isOnline) PlaceSearch.helpPlaces(near.latitude, near.longitude, radiusMeters = 12_000.0, perCategory = 3) else emptyList()
            if (live.isEmpty()) {
                useFallback(fallback, near)
            } else {
                places = live.sortedBy { it.distanceMiles(near.latitude, near.longitude) }
                source = Source.live
                loadedFor = near
            }
        } finally {
            isLoading = false
        }
    }

    private fun useFallback(pack: TripPack?, near: Here?) {
        if (pack == null) {
            places = emptyList()
            source = Source.none
            return
        }
        places = near?.let { here -> pack.allPlaces.sortedBy { it.distanceMiles(here.latitude, here.longitude) } } ?: pack.allPlaces
        source = Source.tripPack
    }
}

private val scenePhotos = listOf(
    "Every vehicle, from all four corners",
    "License plates",
    "The road, signs and traffic lights",
    "Weather and lighting (rain, darkness)",
    "Other driver's license and insurance card",
)

/**
 * Everything a driver needs after a crash, in one place: help nearby, 911, Pulse, family, medical and insurance info.
 * Shown after the check-in, and from Profile → Testing → Nearby help.
 */
@Composable
fun RecoveryScreen(user: AuthUser, outcome: CheckInOutcome?, banner: RecoveryBanner? = null, onClose: () -> Unit) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val help = remember { NearbyHelpViewModel() }
    var filter by remember { mutableStateOf<HelpPlace.Category?>(null) }
    var checked by remember { mutableStateOf(setOf<String>()) }
    var placeToCall by remember { mutableStateOf<HelpPlace?>(null) }
    var openReport by remember { mutableStateOf<String?>(null) }
    val profile = env.store.profile(user.id)
    val activeTrip = env.store.trips(user.id).firstOrNull { it.isActive }
    val latest = env.store.checkIns(user.id).firstOrNull()
    val here = env.location.location
    val visible = help.places.filter { filter == null || it.category == filter }

    BackHandler(onBack = onClose)
    LaunchedEffect(here?.let { (it.latitude * 1000).toInt() }) {
        help.load(here, env.connectivity.isOnline, activeTrip?.tripPack)
    }
    LaunchedEffect(Unit) { env.location.requestPermission() }

    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding()) {
        TopBar("Get help", trailing = BarAction("", icon = "xmark", run = onClose))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            ReadableColumn(modifier = Modifier.padding(bottom = Space.xl)) {
                if (env.crashCenter.isSirenOn || outcome == CheckInOutcome.noResponse) AlarmCard()
                banner?.let {
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.small)).background(it.tint.copy(alpha = 0.16f)).padding(14.dp)
                        .animateContentSize(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(sf(it.icon), null, tint = it.tint, modifier = Modifier.size(20.dp))
                        Text(it.text, style = Type.subheadline.semibold(), color = Brand.textPrimary)
                    }
                }
                // Emergency actions
                Row(Modifier.fadeUp(0.03), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PillButton("Call 911", { Actions.call(context, "911") }, Modifier.weight(1f), kind = PillKind.danger, height = 60.dp, icon = "phone.fill")
                    PillButton("Talk to Pulse", {
                        if (outcome != null) env.router.openAssistant(outcome) else {
                            env.router.selectedTab = AppRouter.Tab.assistant
                            onClose()
                        }
                    }, Modifier.weight(1f), height = 60.dp, leading = { PulseOrbDisc(diameter = 28.dp) })
                }
                if (latest != null && latest.snapshot != null && latest.date > nowSeconds() - 12 * 3600) {
                    Row(Modifier.card().fadeUp(0.05).pressable { openReport = latest.id }, verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        IconBadge("doc.text.fill", Brand.blue, 46.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text("Impact report", style = Type.headline, color = Brand.textPrimary)
                            Text("What happened, for you, and a copy to show the police or send your insurer.", style = Type.subheadline, color = Brand.textSecondary)
                        }
                        Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
                    }
                }
                MapCard(outcome, here, visible, Modifier.fadeUp(0.06))
                NearbyHelp(help, filter, { filter = it }, visible, here, Modifier.fadeUp(0.1)) { placeToCall = it }
                here?.let { location ->
                    PillButton("Share my location", {
                        Actions.shareText(context, "I've been in a car crash. I'm here: https://maps.google.com/?q=${location.latitude},${location.longitude}")
                    }, kind = PillKind.secondary, icon = "square.and.arrow.up", modifier = Modifier.fadeUp(0.14))
                }
                profile?.let { MedicalCard(user, it, Modifier.fadeUp(0.18)) }
                profile?.takeIf { it.familyContacts.isNotEmpty() }?.let { p ->
                    Column(Modifier.card(Space.md + 4.dp).fadeUp(0.2), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("Family", style = Type.headline, color = Brand.textPrimary)
                        p.sortedContacts.forEach { contact ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.weight(1f)) { ContactRow(contact) }
                                Box(Modifier.size(44.dp).clip(CircleShape).pressable { Actions.call(context, contact.phone) }
                                    .semantics { contentDescription = "Call ${contact.name}" }, contentAlignment = Alignment.Center) {
                                    Icon(sf("phone.circle.fill"), null, tint = Brand.greenInk, modifier = Modifier.size(30.dp))
                                }
                            }
                        }
                    }
                }
                // Document the scene
                Column(Modifier.card(Space.md + 4.dp).fadeUp(0.22), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row {
                        Text("Document the scene", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
                        Text("${checked.size}/${scenePhotos.size}", style = Type.subheadline.semibold(), color = Brand.textSecondary)
                    }
                    Text("Only once you're safely off the road. Photograph:", style = Type.subheadline, color = Brand.textSecondary)
                    scenePhotos.forEach { item ->
                        val done = item in checked
                        Row(Modifier.fillMaxWidth().heightIn(min = 40.dp).pressable { checked = if (done) checked - item else checked + item },
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(sf(if (done) "checkmark.circle.fill" else "circle"), null, tint = if (done) Brand.greenInk else Brand.textSecondary,
                                modifier = Modifier.size(22.dp))
                            Text(item, style = Type.body.copy(textDecoration = if (done) TextDecoration.LineThrough else null), color = Brand.textPrimary)
                        }
                    }
                }
                profile?.takeIf { it.insurer.isNotEmpty() }?.let { p ->
                    Column(Modifier.card(Space.md + 4.dp).fadeUp(0.24), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Insurance", style = Type.headline, color = Brand.textPrimary)
                        StatusRow("building.columns.fill", p.insurer, if (p.policyNumber.isEmpty()) "No policy number saved" else "Policy ${p.policyNumber}", Brand.blueInk)
                        Text("Report it promptly and stick to facts: time, place, weather, what you saw. Don't guess or admit fault at the scene. Not legal advice.",
                            style = Type.footnote, color = Brand.textSecondary)
                        if (p.insurerPhone.isNotEmpty()) {
                            PillButton("Call ${p.insurer}", { Actions.call(context, p.insurerPhone) }, kind = PillKind.secondary, height = 48.dp, icon = "phone.fill")
                        }
                    }
                }
            }
        }
    }
    placeToCall?.let { place ->
        ActionDialog(place.name, listOfNotNull(
            if (place.phone.isNotEmpty()) "Call ${place.phone}" to { Actions.call(context, place.phone) } else null,
            "Directions in Maps" to { Actions.directions(context, place.latitude, place.longitude, place.name) },
        )) { placeToCall = null }
    }
    openReport?.let { id -> ImpactReportSheet(id, user) { openReport = null } }
}

/** No answer: the siren is sounding for anyone nearby, and the 911 call was started. */
@Composable
private fun AlarmCard() {
    val env = LocalEnvironment.current
    val center = env.crashCenter
    val simulated = center.current?.event?.isSimulated ?: false
    val pulse by rememberInfiniteTransition(label = "alarm").animateFloat(1f, 0.75f, infiniteRepeatable(tween(500), RepeatMode.Reverse), label = "alpha")
    Column(Modifier
        .fillMaxWidth()
        .alpha(if (center.isSirenOn) pulse else 1f)
        .clip(RoundedCornerShape(Radius.card))
        .background(Brand.red)
        .padding(Space.md), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(sf(if (center.isSirenOn) "speaker.wave.3.fill" else "speaker.slash.fill"), null, tint = Color.White)
            Text(if (center.isSirenOn) "Alarm sounding" else "Alarm stopped", style = Type.headline, color = Color.White)
        }
        Text(when {
            simulated -> "Test crash: the siren is real, but no 911 call was started and no one was contacted."
            center.startedEmergencyCall -> "No answer, so we opened a 911 call (tap call to connect) and are alerting your family. If you're a bystander: this driver may be hurt — call 911."
            else -> "No answer. If you're a bystander: this driver may be hurt — call 911."
        }, style = Type.subheadline, color = Color.White.copy(alpha = 0.9f))
        PillButton(if (center.isSirenOn) "I'm okay — stop the alarm" else "Sound the alarm again",
            { if (center.isSirenOn) center.stopSiren() else center.startSiren() }, kind = PillKind.dark, height = 50.dp)
    }
}

@Composable
private fun MapCard(outcome: CheckInOutcome?, here: Here?, places: List<HelpPlace>, modifier: Modifier) {
    val env = LocalEnvironment.current
    val markers = listOfNotNull(
        if (here != null && outcome != null) MapMarker(here.latitude, here.longitude, "Crash location", Brand.red, large = true) else null,
    ) + places.map { MapMarker(it.latitude, it.longitude, it.name, helpTint(it.category)) }
    Box(modifier.fillMaxWidth().height(230.dp).clip(RoundedCornerShape(Radius.card)).border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))) {
        OsmMap(Modifier.fillMaxSize(), center = here?.let { it.latitude to it.longitude }, zoom = 13.0, markers = markers,
            user = here?.let { it.latitude to it.longitude })
        if (here != null) {
            Column(Modifier.align(Alignment.TopStart).padding(12.dp).clip(RoundedCornerShape(12.dp)).background(Brand.surfaceRaised.copy(alpha = 0.92f))
                .padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(if (outcome != null) "Crash location" else "You're here", style = Type.caption.semibold(), color = Brand.textSecondary)
                Text(env.location.streetName ?: env.location.placeName ?: "Finding address…", style = Type.subheadline.semibold(), color = Brand.textPrimary)
            }
        }
    }
}

@Composable
private fun NearbyHelp(help: NearbyHelpViewModel, filter: HelpPlace.Category?, setFilter: (HelpPlace.Category?) -> Unit,
                       visible: List<HelpPlace>, here: Here?, modifier: Modifier, onPlace: (HelpPlace) -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Nearby help", style = Type.title3.semibold(), color = Brand.textPrimary, modifier = Modifier.weight(1f))
            if (help.source == NearbyHelpViewModel.Source.tripPack) StatusChip("Offline · trip pack", "icloud.slash", Brand.amberInk)
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip("All", filter == null) { setFilter(null) }
            HelpPlace.Category.entries.forEach { FilterChip(it.title, filter == it) { setFilter(it) } }
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.card)).background(Brand.surface).border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))) {
            when {
                help.isLoading -> repeat(3) { PlaceholderRow() }
                visible.isEmpty() -> Text(if (here == null) "Turn on location to find help nearby." else "Nothing found nearby. Call 911 for emergencies.",
                    style = Type.subheadline, color = Brand.textSecondary, modifier = Modifier.padding(Space.md))
                else -> visible.take(8).forEachIndexed { index, place ->
                    if (index > 0) Hairline(Modifier.padding(start = 70.dp))
                    Row(Modifier.fillMaxWidth().pressable { onPlace(place) }.padding(horizontal = Space.md, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        IconBadge(place.category.systemImage, helpTint(place.category), 42.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(place.name, style = Type.headline, color = Brand.textPrimary, maxLines = 2)
                            Text(distanceText(place, here), style = Type.subheadline, color = Brand.textSecondary)
                        }
                        Icon(sf(if (place.phone.isEmpty()) "arrow.triangle.turn.up.right.circle.fill" else "phone.circle.fill"), null,
                            tint = Brand.greenInk, modifier = Modifier.size(30.dp))
                    }
                }
            }
        }
    }
}

private fun distanceText(place: HelpPlace, here: Here?): String {
    here ?: return place.category.title
    val miles = place.distanceMiles(here.latitude, here.longitude)
    val minutes = maxOf(1, Math.round(miles / 30 * 60).toInt() + 1)
    return String.format(Locale.US, "%.1f mi · ~%d min", miles, minutes)
}

@Composable
private fun FilterChip(title: String, selected: Boolean, onClick: () -> Unit) {
    Box(Modifier.heightIn(min = 44.dp), contentAlignment = Alignment.Center) {
        Text(title, style = Type.subheadline.semibold(), color = if (selected) Color.White else Brand.textPrimary,
            modifier = Modifier.clip(CircleShape).background(if (selected) Brand.blue else Brand.fieldFill).pressable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 8.dp))
    }
}

@Composable
private fun PlaceholderRow() {
    val phase by rememberInfiniteTransition(label = "loading").animateFloat(0.5f, 1f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "a")
    Row(Modifier.padding(Space.md).alpha(phase), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(Brand.fieldFill))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.width(160.dp).height(12.dp).clip(CircleShape).background(Brand.fieldFill))
            Box(Modifier.width(90.dp).height(10.dp).clip(CircleShape).background(Brand.fieldFill))
        }
    }
}

@Composable
private fun MedicalCard(user: AuthUser, profile: Profile, modifier: Modifier) {
    Column(modifier.card(Space.md + 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(sf("staroflife.fill"), null, tint = Brand.redInk, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("For responders", style = Type.headline, color = Brand.redInk, modifier = Modifier.weight(1f))
            if (profile.bloodType.isNotEmpty()) {
                Text(profile.bloodType, style = Type.headline, color = Color.White,
                    modifier = Modifier.clip(CircleShape).background(Brand.red).padding(horizontal = 12.dp, vertical = 4.dp)
                        .semantics { contentDescription = "Blood type ${profile.bloodType}" })
            }
        }
        Text(user.name, style = Type.title3.semibold(), color = Brand.textPrimary)
        Text(profile.medicalNotes.ifEmpty { "No medical notes added." }, style = Type.body, color = Brand.textPrimary)
        profile.primaryVehicle?.let { vehicle ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(sf(vehicle.type.systemImage), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
                Text(vehicle.displayName + if (vehicle.plate.isEmpty()) "" else " · ${vehicle.plate}", style = Type.subheadline, color = Brand.textSecondary)
            }
        }
    }
}
