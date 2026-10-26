@file:OptIn(ExperimentalFoundationApi::class)

package org.cac.crashsafe.features.trips

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.features.home.DrivePickerMode
import org.cac.crashsafe.features.home.DriveVehiclePicker
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.model.TripPackStatus
import org.cac.crashsafe.services.trips.PlaceSelection
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BrandPhoto
import org.cac.crashsafe.ui.components.BrandPhotoView
import org.cac.crashsafe.ui.components.ConfirmDialog
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.MapMarker
import org.cac.crashsafe.ui.components.OsmMap
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.SectionHeader
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

enum class PickerField { origin, destination }

@Composable
fun TripPlannerScreen(userID: String, viewModel: TripPlannerViewModel) {
    val env = LocalEnvironment.current
    var openTrip by remember { mutableStateOf<String?>(null) }
    openTrip?.let { id ->
        TripDetailScreen(id) { openTrip = null }
        return
    }
    val trips = env.store.trips(userID)
    val profile = env.store.profile(userID)
    var picking by remember { mutableStateOf<PickerField?>(null) }
    var pickingVehicle by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<Trip?>(null) }

    fun useCurrentLocation() {
        val here = env.location.location
        if (here == null) {
            env.location.requestPermission()
            return
        }
        viewModel.updateOrigin(PlaceSelection("Current location", env.location.placeName ?: "", here.latitude, here.longitude, isCurrentLocation = true))
    }
    LaunchedEffect(Unit) { env.location.requestPermission() }
    LaunchedEffect(env.location.location == null) { if (viewModel.origin == null && env.location.location != null) useCurrentLocation() }

    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().verticalScroll(rememberScrollState())) {
        ReadableColumn {
            Text("Plan a drive", style = Type.largeTitle.bold(), color = Brand.textPrimary, modifier = Modifier.padding(top = Space.sm).fadeUp())
            Column(Modifier.fadeUp(0.05), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                MapCard(viewModel)
                BrandPhotoView(BrandPhoto.roadBanner, Modifier.fillMaxWidth().height(84.dp).clip(RoundedCornerShape(Radius.card))
                    .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card)))
            }
            RouteCard(viewModel, Modifier.fadeUp(0.1), onPick = { picking = it }, onUseCurrentLocation = ::useCurrentLocation)
            Column(Modifier.card().fadeUp(0.13), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                DateField("Leave", "calendar", viewModel.startDate, minimum = null) { viewModel.startDate = it }
                Box(Modifier.fillMaxWidth().height(1.dp).background(Brand.stroke))
                DateField("Return", "calendar.badge.clock", viewModel.endDate, minimum = viewModel.startDate) { viewModel.endDate = it }
                viewModel.datesError?.let { Text(it, style = Type.footnote, color = Brand.redInk) }
            }
            // Crash detection row
            Row(Modifier.card().fadeUp(0.16).pressable { pickingVehicle = true }, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(sf("shield.lefthalf.filled"), null, tint = Brand.amberInk, modifier = Modifier.width(32.dp).size(28.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Crash detection ready", style = Type.headline, color = Brand.textPrimary)
                    Text(profile?.primaryVehicle?.let { "Driving the ${it.displayName} · Tap to change" } ?: "Pick the car you're driving.",
                        style = Type.footnote, color = Brand.textSecondary)
                }
                Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
            }
            Column(Modifier.fadeUp(0.2), verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                PillButton("Save trip", {
                    viewModel.save(env.store)?.let { trip -> TripPacks.download(env.store, env.tripPacks, env.scope, trip.id) }
                }, icon = "checkmark")
                AnimatedVisibility(viewModel.lastSaved != null) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(sf("checkmark.circle.fill"), null, tint = Brand.greenInk, modifier = Modifier.size(16.dp))
                        Text("Saved ${viewModel.lastSaved ?: ""}", style = Type.footnote.medium(), color = Brand.greenInk)
                    }
                }
            }
            if (trips.isNotEmpty()) {
                Column(Modifier.fadeUp(0.25), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeader("Saved trips")
                    trips.forEach { trip ->
                        TripCard(trip, Modifier.combinedClickable(onClick = { openTrip = trip.id }, onLongClick = { deleting = trip })
                            .semantics { contentDescription = "${trip.destination}, from ${trip.origin}. Touch and hold to delete." })
                    }
                }
            }
            Spacer(Modifier.height(Space.lg))
        }
    }

    picking?.let { field ->
        LocationPickerSheet(field, onPick = { selection ->
            when (field) {
                PickerField.origin -> viewModel.updateOrigin(selection)
                PickerField.destination -> viewModel.updateDestination(selection)
            }
            viewModel.dismissSavedNotice()
        }) { picking = null }
    }
    if (pickingVehicle) DriveVehiclePicker(userID, DrivePickerMode.chooseForTrip) { pickingVehicle = false }
    deleting?.let { trip ->
        ConfirmDialog("Delete trip?", "${trip.routeLabel} and its offline trip pack will be removed from this phone.", "Delete trip",
            onConfirm = { env.store.deleteTrip(trip.id) }, onDismiss = { deleting = null })
    }
}

@Composable
private fun MapCard(viewModel: TripPlannerViewModel) {
    val env = LocalEnvironment.current
    val here = env.location.location
    val origin = viewModel.origin
    val destination = viewModel.destination
    val markers = listOfNotNull(
        origin?.takeIf { !it.isCurrentLocation }?.let { MapMarker(it.latitude, it.longitude, it.title, Brand.blue) },
        destination?.let { MapMarker(it.latitude, it.longitude, it.title, Brand.navy, large = true) },
    )
    Box(Modifier.fillMaxWidth().height(240.dp).clip(RoundedCornerShape(Radius.card)).border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))) {
        OsmMap(Modifier.fillMaxSize(), center = (destination ?: origin)?.let { it.latitude to it.longitude } ?: here?.let { it.latitude to it.longitude },
            zoom = 12.0, markers = markers, route = viewModel.route?.points, user = here?.let { it.latitude to it.longitude },
            fitToContent = viewModel.route != null)
        if (viewModel.isRouting || viewModel.routeSummary != null) {
            Row(Modifier.align(Alignment.BottomEnd).padding(12.dp).heightIn(min = 36.dp).clip(CircleShape)
                .background(Brand.navy.copy(alpha = 0.88f)).border(1.dp, Brand.stroke, CircleShape).padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (viewModel.isRouting) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Brand.textPrimary, strokeWidth = 2.dp)
                    Text("Finding route…", style = Type.subheadline.semibold(), color = Brand.textPrimary)
                } else {
                    Icon(sf("car.fill"), null, tint = Brand.textPrimary, modifier = Modifier.size(16.dp))
                    Text(viewModel.routeSummary ?: "", style = Type.subheadline.semibold(), color = Brand.textPrimary)
                }
            }
        }
    }
}

@Composable
private fun RouteCard(viewModel: TripPlannerViewModel, modifier: Modifier, onPick: (PickerField) -> Unit, onUseCurrentLocation: () -> Unit) {
    Row(modifier.card(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            PlaceRow(PickerField.origin, "From", viewModel.origin, "Choose a starting point", viewModel.originError, onPick, onUseCurrentLocation) {
                Box(Modifier.size(28.dp).border(3.dp, Brand.blueInk, CircleShape), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(Brand.blueInk))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Canvas(Modifier.width(32.dp).height(22.dp)) {
                    drawLine(Brand.textSecondary, Offset(size.width / 2, 0f), Offset(size.width / 2, size.height), strokeWidth = 2.dp.toPx(),
                        cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.5f, 5.dp.toPx())))
                }
                Box(Modifier.weight(1f).height(1.dp).background(Brand.stroke))
            }
            PlaceRow(PickerField.destination, "To", viewModel.destination, "Search destination", viewModel.destinationError, onPick, null) {
                Box(Modifier.size(28.dp).clip(CircleShape).background(Color(0xFFF4EEDF)), contentAlignment = Alignment.Center) {
                    Icon(sf("mappin.and.ellipse"), null, tint = Brand.navy, modifier = Modifier.size(15.dp))
                }
            }
        }
        Box(Modifier.size(56.dp).clip(CircleShape).background(Brand.fieldFill).border(1.dp, Brand.stroke, CircleShape)
            .pressable(enabled = viewModel.origin != null || viewModel.destination != null) { viewModel.swap() }
            .semantics { contentDescription = "Swap start and destination" }, contentAlignment = Alignment.Center) {
            Icon(sf("arrow.up.arrow.down"), null, tint = Brand.blueInk, modifier = Modifier.size(24.dp))
        }
    }
}

@Composable
private fun PlaceRow(field: PickerField, label: String, value: PlaceSelection?, placeholder: String, error: String?,
                     onPick: (PickerField) -> Unit, onUseCurrentLocation: (() -> Unit)?, glyph: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.weight(1f).heightIn(min = 58.dp).pressable { onPick(field) }, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.width(32.dp), contentAlignment = Alignment.Center) { glyph() }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(label, style = Type.subheadline, color = Brand.textSecondary)
                if (value != null) {
                    Text(if (value.isCurrentLocation) "Current location" else value.title, style = Type.title3.medium(),
                        color = if (field == PickerField.origin) Brand.blueInk else Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (value.subtitle.isNotEmpty()) Text(value.subtitle, style = Type.subheadline, color = Brand.textSecondary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                } else {
                    Text(error ?: placeholder, style = Type.title3, color = if (error == null) Brand.textSecondary else Brand.redInk)
                }
            }
        }
        if (onUseCurrentLocation != null && value?.isCurrentLocation != true) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(Brand.blueInk.copy(alpha = 0.1f)).pressable(onClick = onUseCurrentLocation)
                .semantics { contentDescription = "Use current location" }, contentAlignment = Alignment.Center) {
                Icon(sf("location.fill"), null, tint = Brand.blueInk, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
fun TripCard(trip: Trip, modifier: Modifier = Modifier) {
    Row(modifier.card(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        IconBadge(if (trip.isActive) "car.fill" else "map.fill", if (trip.isActive) Brand.green else Brand.blue, 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(trip.destination, style = Type.headline, color = Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                if (trip.isActive) StatusChip("Active", tint = Brand.greenInk)
            }
            Text("From ${trip.origin} · ${Formats.monthDay(trip.startDate)}", style = Type.subheadline, color = Brand.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            when (trip.tripPackStatus) {
                TripPackStatus.downloading -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CircularProgressIndicator(Modifier.size(12.dp), color = Brand.textSecondary, strokeWidth = 1.5.dp)
                    Text("Saving offline help…", style = Type.caption.medium(), color = Brand.textSecondary)
                }
                TripPackStatus.ready -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(sf("checkmark.icloud.fill"), null, tint = Brand.greenInk, modifier = Modifier.size(14.dp))
                    Text(trip.routeSummary?.let { "Offline ready · $it" } ?: "Offline ready", style = Type.caption.medium(), color = Brand.greenInk)
                }
                TripPackStatus.notDownloaded, TripPackStatus.failed -> Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(sf("icloud.slash"), null, tint = Brand.textSecondary, modifier = Modifier.size(14.dp))
                    Text(trip.tripPackStatus.label, style = Type.caption.medium(), color = Brand.textSecondary)
                }
            }
        }
        Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
    }
}
