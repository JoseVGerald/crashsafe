package org.cac.crashsafe.features.home

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.features.profile.VehicleEditorSheet
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.model.Vehicle
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.Hairline
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.SafetyNotice
import org.cac.crashsafe.ui.components.VehicleThumbnail
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

enum class DrivePickerMode {
    /** Home, no drive yet: pick a car (and optionally a planned trip), then start. */
    startDrive,
    /** A drive is running: swap the car. */
    changeCar,
    /** Trip planner: pick the car for the trip being planned. */
    chooseForTrip,
}

/**
 * "Which car are you driving?" — opened from "Crash detection ready". The car you pick tunes crash
 * detection to its type and becomes your primary car, so the next drive starts with it selected.
 */
@Composable
fun DriveVehiclePicker(
    ownerID: String,
    mode: DrivePickerMode,
    upcomingTrips: List<Trip> = emptyList(),
    onConfirm: (Trip?) -> Unit = {},
    onPlanTrip: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    val env = LocalEnvironment.current
    val profile = env.store.profile(ownerID) ?: return
    var selected by remember { mutableStateOf(profile.primaryVehicle?.id ?: profile.sortedVehicles.firstOrNull()?.id) }
    var trip by remember { mutableStateOf<Trip?>(null) }
    var addingVehicle by remember { mutableStateOf(false) }
    var showingInfo by remember { mutableStateOf(false) }
    // Select a car the user just added.
    var knownCount by remember { mutableStateOf(profile.vehicles.size) }
    LaunchedEffect(profile.vehicles.size) {
        if (profile.vehicles.size > knownCount) profile.vehicles.maxByOrNull { it.createdAt }?.let { selected = it.id }
        knownCount = profile.vehicles.size
    }
    val confirmTitle = when (mode) {
        DrivePickerMode.startDrive -> "Start drive"
        DrivePickerMode.changeCar -> "Drive this car"
        DrivePickerMode.chooseForTrip -> "Use this car"
    }
    fun confirm() {
        selected?.let { id -> env.store.updateProfile(ownerID) { it.makingPrimary(id) } }
        onConfirm(trip)
        onDismiss()
    }
    FullScreenSheet(onDismiss, title = "Crash detection", leading = BarAction("Cancel", run = onDismiss),
        bottomBar = {
            PillButton(confirmTitle, ::confirm, icon = if (mode == DrivePickerMode.startDrive) "car.fill" else "checkmark",
                enabled = selected != null || profile.vehicles.isEmpty(),
                modifier = Modifier.padding(horizontal = Space.lg, vertical = Space.sm))
        }) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg, modifier = Modifier.padding(vertical = Space.md)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Which car are you driving?", style = Type.title2.semibold(), color = Brand.textPrimary)
                Text("Crash detection is tuned to the size and type of the car you pick.", style = Type.subheadline, color = Brand.textSecondary)
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                profile.sortedVehicles.forEach { vehicle -> VehicleOption(vehicle, selected == vehicle.id) { selected = vehicle.id } }
                if (profile.vehicles.isEmpty()) {
                    Text("No cars yet. Add the one you're driving so crash detection fits it.", style = Type.subheadline,
                        color = Brand.textSecondary, modifier = Modifier.card())
                }
                PillButton("Add a vehicle", { addingVehicle = true }, kind = PillKind.secondary, height = 48.dp, icon = "plus.circle")
            }
            if (mode == DrivePickerMode.startDrive) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Where to?", style = Type.headline, color = Brand.textPrimary)
                    Column(Modifier.card()) {
                        TripRow("Quick drive", "No planned route", trip == null) { trip = null }
                        upcomingTrips.take(3).forEach { option ->
                            Hairline()
                            TripRow(option.destination, "From ${option.origin}", trip?.id == option.id) { trip = option }
                        }
                        if (onPlanTrip != null) {
                            Hairline()
                            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).pressable { onDismiss(); onPlanTrip() },
                                verticalAlignment = Alignment.CenterVertically) {
                                Icon(sf("map"), null, tint = Brand.blueInk, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Plan a new trip", style = Type.body, color = Brand.blueInk, modifier = Modifier.weight(1f))
                                Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }
            LinkButton("How crash detection works", { showingInfo = true }, icon = "info.circle")
        }
    }
    if (addingVehicle) VehicleEditorSheet(ownerID, onSaved = { selected = it.id }) { addingVehicle = false }
    if (showingInfo) CrashDetectionInfoSheet { showingInfo = false }
}

@Composable
private fun VehicleOption(vehicle: Vehicle, isSelected: Boolean, onClick: () -> Unit) {
    Row(Modifier
        .card(Space.sm + 2.dp)
        .border(if (isSelected) 2.dp else 0.dp, if (isSelected) Brand.blueInk else Color.Transparent, RoundedCornerShape(Radius.card))
        .pressable(onClick = onClick)
        .semantics { this.selected = isSelected },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        VehicleThumbnail(84.dp, 58.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(vehicle.displayName, style = Type.headline, color = Brand.textPrimary, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (vehicle.isPrimary) {
                    Text("Primary", style = Type.subheadline.semibold(), color = Brand.amberInk)
                    Text("·", style = Type.subheadline, color = Brand.textSecondary)
                }
                Text(vehicle.type.label, style = Type.subheadline, color = Brand.textSecondary)
            }
        }
        Icon(sf(if (isSelected) "checkmark.circle.fill" else "circle"), null,
            tint = if (isSelected) Brand.blueInk else Brand.textSecondary.copy(alpha = 0.6f), modifier = Modifier.size(26.dp))
    }
}

@Composable
private fun TripRow(title: String, subtitle: String, isSelected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).pressable(onClick = onClick).semantics { this.selected = isSelected },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.body.medium(), color = Brand.textPrimary, maxLines = 1)
            Text(subtitle, style = Type.footnote, color = Brand.textSecondary, maxLines = 1)
        }
        Icon(sf(if (isSelected) "checkmark.circle.fill" else "circle"), null,
            tint = if (isSelected) Brand.blueInk else Brand.textSecondary.copy(alpha = 0.6f), modifier = Modifier.size(22.dp))
    }
}

/** What "Crash detection ready" means, in plain words. */
@Composable
fun CrashDetectionInfoSheet(onDismiss: () -> Unit) {
    val points = listOf(
        "play.circle.fill" to "Turns on when your drive starts and off when it ends.",
        "waveform.path.ecg" to "Watches motion and GPS together for a sudden, severe impact.",
        "car.fill" to "Tuned to the car you pick: an SUV, a sedan and a motorcycle crash differently.",
        "questionmark.bubble.fill" to "Asks if you're okay. If you don't answer, your family contacts get your location.",
        "location.fill" to "With location allowed all the time, Pulse can notice drives that start while the app is closed.",
    )
    FullScreenSheet(onDismiss, title = "How it works", trailing = BarAction("Done", bold = true, run = onDismiss)) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg, modifier = Modifier.padding(vertical = Space.lg)) {
            points.forEach { (icon, text) ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.width(28.dp).size(24.dp))
                    Text(text, style = Type.body.copy(fontWeight = FontWeight.Normal), color = Brand.textPrimary)
                }
            }
            SafetyNotice()
        }
    }
}
