@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package org.cac.crashsafe.features.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.cac.crashsafe.app.AppRouter
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.sensors.SensorState
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.features.recovery.ImpactReportSheet
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.CheckInRecord
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.model.TripPackStatus
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BrandPhoto
import org.cac.crashsafe.ui.components.BrandPhotoView
import org.cac.crashsafe.ui.components.CircleIconButton
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.OsmMap
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseRings
import org.cac.crashsafe.ui.components.PulseWordmark
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

@Composable
fun HomeScreen(user: AuthUser, viewModel: HomeViewModel) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val profile = env.store.profile(user.id)
    val trips = env.store.trips(user.id)
    val activeTrip = trips.firstOrNull { it.isActive }
    val upcomingTrips = trips.filter { !it.isActive && it.endDate >= nowSeconds() }
    val currentTrip = activeTrip ?: upcomingTrips.firstOrNull()
    val lastCheckIn = env.store.checkIns(user.id).firstOrNull()
    val isNight = env.driving.scenario?.isNight ?: env.conditions.isNight
    val advice = DrivingAdvice.make(env.conditions.weather, isNight)
    var showingDrivePicker by remember { mutableStateOf(false) }
    var openReport by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }

    val notice = sensorNotice()
    val isProtected = viewModel.isMonitoring || env.driving.isActive

    LaunchedEffect(Unit) {
        viewModel.resumeIfNeeded(activeTrip)
        env.location.requestPermission()
    }
    val here = env.location.location
    LaunchedEffect(here?.let { (it.latitude * 100).toInt() }) {
        if (env.driving.scenario != null) return@LaunchedEffect
        // Have the roads around here on the phone before "Start drive" needs their limits.
        here?.let { env.driving.speedLimits?.prefetch(it.latitude, it.longitude) }
        env.conditions.refresh(here)
    }

    PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
        scope.launch {
            refreshing = true
            env.conditions.refresh(env.location.location, force = true)
            refreshing = false
        }
    }, modifier = Modifier.fillMaxSize().background(Brand.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
            ReadableColumn {
                // Top bar
                Row(Modifier.padding(top = Space.sm).fadeUp(), verticalAlignment = Alignment.CenterVertically) {
                    PulseWordmark()
                    Spacer(Modifier.weight(1f))
                    CircleIconButton("person", "Profile", { env.router.selectedTab = AppRouter.Tab.profile })
                }
                // Header
                Column(Modifier.fadeUp(0.03), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(if (user.firstName.isEmpty()) "${greeting()}," else "${greeting()}, ${user.firstName}",
                        style = Type.largeTitle, color = Brand.textPrimary)
                    Text("Stay safe. We're looking out for you.", style = Type.body, color = Brand.textSecondary)
                    ActivityChip(Modifier.padding(top = 4.dp))
                }
                // Hero: scenic photo with the crash-detection status underneath.
                Column(Modifier
                    .fadeUp(0.06)
                    .clip(RoundedCornerShape(Radius.card))
                    .background(Brand.surface)
                    .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))
                    .pressable { showingDrivePicker = true }
                    .semantics { contentDescription = heroTitle(isProtected, notice) }) {
                    BrandPhotoView(BrandPhoto.roadHero, Modifier.fillMaxWidth().height(160.dp))
                    Row(Modifier.padding(Space.md), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        val tint = if (!isProtected) Brand.textSecondary.copy(alpha = 0.6f) else if (notice == null) Brand.greenInk else Brand.amberInk
                        Box(Modifier.size(14.dp), contentAlignment = Alignment.Center) {
                            if (isProtected) PulseRings(tint, count = 2, modifier = Modifier.size(14.dp))
                            Box(Modifier.size(14.dp).clip(CircleShape).background(tint))
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(heroTitle(isProtected, notice), style = Type.headline, color = Brand.textPrimary)
                            Text(heroDetail(profile, isProtected, notice), style = Type.footnote, color = Brand.textSecondary)
                        }
                        Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
                    }
                }

                notice?.let { text ->
                    Row(Modifier.card().pressable {
                        if (env.sensors.health.state == SensorState.permissionDenied || env.location.isDenied) env.permissions.openSettings()
                    }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(sf("exclamationmark.triangle"), null, tint = Brand.amberInk, modifier = Modifier.size(18.dp))
                        Text(text, style = Type.subheadline, color = Brand.amberInk)
                    }
                }

                LocationCard(Modifier.fadeUp(0.09)) {
                    when {
                        env.location.isAuthorized -> here?.let {
                            Actions.directions(context, it.latitude, it.longitude, env.location.placeName?.let { p -> "Your location · $p" } ?: "Your location")
                        }
                        env.location.isDenied -> env.permissions.openSettings()
                        else -> env.location.requestPermission()
                    }
                }

                RoadAlertCard(
                    advice = advice,
                    isNight = isNight,
                    isLoading = env.conditions.weather == null && env.conditions.isLoading,
                    windMph = env.conditions.weather?.windMph,
                    demoTitle = env.driving.scenario?.let { "Demo · ${it.title}" },
                    showsAttribution = env.conditions.weather != null && env.driving.scenario == null,
                    modifier = Modifier.fadeUp(0.12),
                )

                TripCard(currentTrip, activeTrip, Modifier.fadeUp(0.18), onEnd = { activeTrip?.let { viewModel.end(it.id) } },
                    onStart = { showingDrivePicker = true })

                lastCheckIn?.let { last -> LastCheckInRow(last, Modifier.fadeUp(0.21)) { if (last.snapshot != null) openReport = last.id } }
                Spacer(Modifier.height(Space.lg))
            }
        }
    }

    if (showingDrivePicker && profile != null) {
        DriveVehiclePicker(
            ownerID = user.id,
            mode = if (activeTrip == null) DrivePickerMode.startDrive else DrivePickerMode.changeCar,
            upcomingTrips = upcomingTrips,
            onConfirm = { trip ->
                when {
                    activeTrip != null -> viewModel.changeVehicle()
                    trip != null -> viewModel.start(trip.id)
                    else -> viewModel.startQuickTrip()
                }
                // Straight into the driving dashboard, on live data.
                env.router.showingCarPlay = true
            },
            onPlanTrip = { env.router.selectedTab = AppRouter.Tab.trips },
            onDismiss = { showingDrivePicker = false })
    }
    openReport?.let { id -> ImpactReportSheet(id, user) { openReport = null } }
}

@Composable
private fun sensorNotice(): String? {
    val env = LocalEnvironment.current
    if (env.driving.mode != org.cac.crashsafe.services.driving.DrivingMonitor.Mode.Live) return null
    val health = env.sensors.health
    return when (health.state) {
        SensorState.starting -> "Waiting for motion readings. Crash monitoring is not ready yet."
        SensorState.permissionDenied -> "Motion access is off. Enable it in Settings to monitor for crashes."
        SensorState.unavailable -> "Motion sensors are unavailable. Automatic crash monitoring is unavailable."
        SensorState.interrupted, SensorState.stale, SensorState.stopped -> "Motion readings have stopped. Automatic crash monitoring is interrupted."
        SensorState.active -> if (health.locationUnavailable) "Reliable location or speed is unavailable. Crash monitoring has limited information." else null
    }
}

/** Honest status: a running drive whose sensors aren't delivering is "limited", not "active". */
private fun heroTitle(isProtected: Boolean, notice: String?): String =
    if (!isProtected) "Crash detection ready" else if (notice == null) "Crash detection active" else "Crash detection limited"

private fun heroDetail(profile: Profile?, isProtected: Boolean, notice: String?): String {
    val car = profile?.primaryVehicle?.displayName
    if (isProtected) {
        val sensors = if (notice == null) "Sensors enabled" else "Sensors limited — see below"
        return car?.let { "$sensors · $it" } ?: sensors
    }
    return car?.let { "Tap to drive the $it" } ?: "Tap to pick your car and start"
}

private fun greeting(): String = when (Formats.hour()) {
    in 5 until 12 -> "Good morning"
    in 12 until 17 -> "Good afternoon"
    else -> "Good evening"
}

@Composable
private fun LocationCard(modifier: Modifier, onClick: () -> Unit) {
    val env = LocalEnvironment.current
    val here = env.location.location
    Column(modifier
        .clip(RoundedCornerShape(Radius.card))
        .background(Brand.surface)
        .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))
        .pressable(onClick = onClick)) {
        if (here != null) {
            OsmMap(Modifier.fillMaxWidth().height(92.dp), center = here.latitude to here.longitude, zoom = 14.0,
                user = here.latitude to here.longitude, interactive = false)
        } else {
            Box(Modifier.fillMaxWidth().height(92.dp).background(Brand.fieldFill))
        }
        Row(Modifier.padding(Space.md), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Icon(sf("mappin.and.ellipse"), null, tint = Brand.amberInk, modifier = Modifier.width(28.dp).size(26.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Your location", style = Type.headline, color = Brand.textPrimary)
                Text(if (!env.location.isAuthorized) "Location off · Tap to turn on" else env.location.placeName ?: "Locating…",
                    style = Type.footnote, color = Brand.textSecondary)
            }
            Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun TripCard(currentTrip: Trip?, activeTrip: Trip?, modifier: Modifier, onEnd: () -> Unit, onStart: () -> Unit) {
    Column(modifier.card(Space.md + 4.dp), verticalArrangement = Arrangement.spacedBy(Space.md)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (activeTrip != null) "Current trip" else "Next trip", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            currentTrip?.let { trip ->
                val ready = trip.tripPackStatus == TripPackStatus.ready
                StatusChip(if (ready) "Offline ready" else "No trip pack", if (ready) "checkmark.icloud.fill" else "icloud.slash",
                    if (ready) Brand.greenInk else Brand.textSecondary)
            }
        }
        if (currentTrip != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                IconBadge(if (currentTrip.isActive) "car.fill" else "map.fill", Brand.blue, 44.dp)
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(currentTrip.routeLabel, style = Type.headline, color = Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(if (currentTrip.isActive) "Started ${Formats.time(currentTrip.startedAt ?: nowSeconds())}"
                    else currentTrip.routeSummary ?: Formats.abbreviatedDateTime(currentTrip.startDate),
                        style = Type.subheadline, color = Brand.textSecondary)
                }
            }
        } else {
            Text("Plan a trip so we can save tow companies and hospitals along your route for offline use.", style = Type.subheadline, color = Brand.textSecondary)
        }
        if (activeTrip != null) PillButton("End trip", onEnd, kind = PillKind.secondary, icon = "stop.fill")
        else PillButton("Start a trip", onStart, icon = "car.fill")
    }
}

@Composable
private fun LastCheckInRow(last: CheckInRecord, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier
        .fillMaxWidth()
        .padding(horizontal = Space.xs)
        .heightIn(min = 44.dp)
        .pressable(enabled = last.snapshot != null, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(sf(last.outcome.systemImage), null, tint = if (last.outcome == CheckInOutcome.ok) Brand.greenInk else Brand.redInk, modifier = Modifier.size(16.dp))
        Text("Last check-in · ${last.outcome.shortLabel}", style = Type.footnote, color = Brand.textPrimary, modifier = Modifier.weight(1f))
        Text(Formats.relative(last.date), style = Type.footnote, color = Brand.textSecondary)
        if (last.snapshot != null) {
            Text("Report", style = Type.footnote, color = Brand.blueInk)
            Icon(sf("chevron.right"), null, tint = Brand.blueInk, modifier = Modifier.size(14.dp))
        }
    }
}

/** What the motion model thinks you're doing right now. */
@Composable
fun ActivityChip(modifier: Modifier = Modifier) {
    val env = LocalEnvironment.current
    val intelligence = env.intelligence
    val current = intelligence.current
    val mode = current?.transportClass
    when {
        current != null && mode != null -> StatusChip("${mode.title} · ${(current.probability * 100).roundToIntHalfAway()}%", mode.systemImage, Brand.blueInk, modifier)
        current != null -> StatusChip("Figuring out what you're doing…", "waveform.path.ecg", Brand.textSecondary, modifier)
        env.sensors.health.state == SensorState.unavailable -> StatusChip("Motion sensors unavailable here", "sensor.fill", Brand.textSecondary, modifier)
        intelligence.isSensingActivity -> StatusChip("Sensing your motion…", "waveform.path.ecg", Brand.textSecondary, modifier)
    }
}

/** How to drive right now and why — no temperature or forecast, nothing to read while driving. */
@Composable
fun RoadAlertCard(advice: DrivingAdvice, isNight: Boolean, isLoading: Boolean, windMph: Double?, demoTitle: String?,
                  showsAttribution: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val isCaution = advice.speedFactor < 1
    val tint = if (isCaution) Brand.amberInk else Brand.greenInk
    Column(modifier.card(Space.md + 4.dp), verticalArrangement = Arrangement.spacedBy(Space.md)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                Icon(sf(if (isCaution) "exclamationmark.triangle.fill" else "checkmark.shield.fill"), null, tint = tint, modifier = Modifier.size(22.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(advice.headline, style = Type.headline, color = Brand.textPrimary)
                    if (isNight) StatusChip("Night", "moon.fill", Brand.blueInk)
                    if (windMph != null && windMph >= 15) StatusChip("${windMph.toInt()} mph", "wind", Brand.amberInk)
                }
                Text(if (isLoading) "Checking the road conditions near you…" else advice.reason, style = Type.subheadline, color = Brand.textSecondary)
                demoTitle?.let {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(sf("play.circle.fill"), null, tint = Brand.blueInk, modifier = Modifier.size(14.dp))
                        Text(it, style = Type.caption.semibold(), color = Brand.blueInk)
                    }
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Brand.stroke))
        advice.tips.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { tip ->
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(sf(tip.systemImage), null, tint = Brand.blueInk, modifier = Modifier.size(18.dp))
                        Text(tip.text, style = Type.subheadline, color = Brand.textPrimary)
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        if (showsAttribution) {
            // Open-Meteo asks for credit (CC BY 4.0).
            LinkButton("Conditions data: Open-Meteo", { Actions.open(context, "https://open-meteo.com/") }, color = Brand.textSecondary,
                style = Type.caption2, modifier = Modifier.align(Alignment.End))
        }
    }
}
