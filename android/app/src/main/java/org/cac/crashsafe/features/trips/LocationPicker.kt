@file:OptIn(ExperimentalMaterial3Api::class)

package org.cac.crashsafe.features.trips

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.services.location.LocationService
import org.cac.crashsafe.services.trips.PlaceSearch
import org.cac.crashsafe.services.trips.PlaceSelection
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.FormField
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.Hairline
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.MapMarker
import org.cac.crashsafe.ui.components.OsmMap
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.sf
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/** Sheet for picking the start or destination: current location, a dropped pin, or search. */
@Composable
fun LocationPickerSheet(field: PickerField, onPick: (PlaceSelection) -> Unit, onDismiss: () -> Unit) {
    val env = LocalEnvironment.current
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<PlaceSelection>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var showingMap by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val here = env.location.location
    LaunchedEffect(query) {
        if (query.trim().length < 2) {
            results = emptyList()
            return@LaunchedEffect
        }
        delay(300) // Search as you type, once typing pauses.
        searching = true
        results = PlaceSearch.autocomplete(query, here?.let { it.latitude to it.longitude })
        searching = false
    }
    LaunchedEffect(Unit) { if (field == PickerField.destination) runCatching { focus.requestFocus() } }

    if (showingMap) {
        MapPinPickerSheet(start = here?.let { it.latitude to it.longitude }, onPick = { onPick(it); onDismiss() }) { showingMap = false }
        return
    }
    FullScreenSheet(onDismiss, title = if (field == PickerField.origin) "Starting point" else "Destination",
        leading = BarAction("Cancel", run = onDismiss), scrolls = false) {
        Column(Modifier.padding(horizontal = Space.md), verticalArrangement = Arrangement.spacedBy(Space.md)) {
            FormField("", query, { query = it }, placeholder = if (field == PickerField.origin) "Search for a starting point" else "Search for a place or address",
                icon = "magnifyingglass", imeAction = ImeAction.Search, focusRequester = focus)
            Column(Modifier.card(Space.sm)) {
                PickerRow("location.fill", Brand.blue, "Use current location",
                    env.location.placeName ?: if (env.location.isAuthorized) "Locating…" else "Location is off", enabled = here != null) {
                    here?.let {
                        onPick(PlaceSelection("Current location", env.location.placeName ?: "", it.latitude, it.longitude, isCurrentLocation = true))
                        onDismiss()
                    }
                }
                Hairline()
                PickerRow("mappin.and.ellipse", Brand.red, "Choose on map", "Drop a pin anywhere") { showingMap = true }
            }
            if (searching && results.isEmpty()) {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Brand.blueInk, modifier = Modifier.size(28.dp))
                }
            }
            if (results.isNotEmpty()) {
                Text("Results", style = Type.footnote.medium(), color = Brand.textSecondary, modifier = Modifier.padding(horizontal = Space.xs))
                LazyColumn(Modifier.card(Space.sm).weight(1f, fill = false)) {
                    items(results, key = { it.title + it.subtitle + it.latitude }) { result ->
                        PickerRow("magnifyingglass", Color(0xFF6B7280), result.title, result.subtitle) {
                            onPick(result)
                            onDismiss()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PickerRow(icon: String, tint: Color, title: String, subtitle: String, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).pressable(enabled, onClick).padding(vertical = 6.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        IconBadge(icon, tint, 36.dp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.body.medium(), color = if (enabled) Brand.textPrimary else Brand.textSecondary)
            if (subtitle.isNotEmpty()) Text(subtitle, style = Type.subheadline, color = Brand.textSecondary, maxLines = 1)
        }
    }
}

/** Tap the map to drop a pin; confirm the reverse-geocoded address. */
@Composable
fun MapPinPickerSheet(start: Pair<Double, Double>?, onPick: (PlaceSelection) -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pin by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var label by remember { mutableStateOf<Pair<String, String>?>(null) }
    FullScreenSheet(onBack, title = "Drop a pin", leading = BarAction("", icon = "chevron.left", run = onBack), scrolls = false) {
        Box(Modifier.fillMaxSize()) {
            // Opens on the given point, or on the device's live location — no hard-coded city.
            OsmMap(Modifier.fillMaxSize(), center = pin ?: start ?: (39.5 to -98.35), zoom = if (start != null) 12.0 else 4.0,
                markers = listOfNotNull(pin?.let { MapMarker(it.first, it.second, label?.first ?: "Pin", Brand.red, large = true) }),
                user = start,
                onTap = { lat, lon ->
                    pin = lat to lon
                    label = null
                    scope.launch { label = LocationService.describe(context, lat, lon) }
                })
            Column(Modifier.align(Alignment.BottomCenter).padding(Space.md).navigationBarsPadding().fillMaxWidth()
                .clip(RoundedCornerShape(26.dp)).background(Brand.surfaceRaised).padding(Space.md + 4.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val current = pin
                if (current != null) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(label?.first ?: "Finding address…", style = Type.headline, color = Brand.textPrimary)
                        Text(label?.second ?: " ", style = Type.subheadline, color = Brand.textSecondary)
                    }
                    PillButton("Use this location", {
                        onPick(PlaceSelection(label?.first ?: "Dropped pin", label?.second ?: "", current.first, current.second))
                    })
                } else {
                    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                        Icon(sf("hand.tap.fill"), null, tint = Brand.textPrimary)
                        Text("Tap the map to drop a pin", style = Type.headline, color = Brand.textPrimary)
                    }
                }
            }
        }
    }
}

/** Row with a consistently formatted date ("Oct 22, 2026 · 9:13 AM") that opens a calendar and then a clock. */
@Composable
fun DateField(title: String, icon: String, date: Double, minimum: Double?, onChange: (Double) -> Unit) {
    var pickingDate by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf<LocalDateTime?>(null) }
    val zone = ZoneId.systemDefault()
    val local = Instant.ofEpochMilli((date * 1000).toLong()).atZone(zone).toLocalDateTime()
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).pressable { pickingDate = true }
        .semantics(mergeDescendants = true) { contentDescription = "$title, ${Formats.dateAndTime(date)}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(sf(icon), null, tint = Brand.textPrimary, modifier = Modifier.size(20.dp))
        Text(title, style = Type.body, color = Brand.textPrimary, modifier = Modifier.weight(1f))
        Text(Formats.dateAndTime(date), style = Type.body, color = Brand.blueInk,
            modifier = Modifier.clip(RoundedCornerShape(50)).background(Brand.fieldFill).padding(horizontal = 12.dp, vertical = 8.dp))
    }
    if (pickingDate) {
        val minimumDay = minimum?.let { Instant.ofEpochMilli((it * 1000).toLong()).atZone(zone).toLocalDate() }
        val state = rememberDatePickerState(
            initialSelectedDateMillis = local.toLocalDate().atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val day = Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate()
                    return minimumDay == null || !day.isBefore(minimumDay)
                }
            })
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(onClick = {
                    pickingDate = false
                    state.selectedDateMillis?.let { millis ->
                        val day = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                        pickingTime = day.atTime(local.toLocalTime())
                    }
                }) { Text("Next", color = Brand.blueInk) }
            },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text("Cancel", color = Brand.textSecondary) } },
            colors = DatePickerDefaults.colors(containerColor = Brand.surfaceRaised),
        ) {
            DatePicker(state, title = { Text(title, style = Type.headline, color = Brand.textPrimary, modifier = Modifier.padding(start = 24.dp, top = 16.dp)) },
                colors = DatePickerDefaults.colors(containerColor = Brand.surfaceRaised, selectedDayContainerColor = Brand.blue,
                    todayDateBorderColor = Brand.blueInk, todayContentColor = Brand.blueInk))
        }
    }
    pickingTime?.let { day ->
        val state = rememberTimePickerState(day.hour, day.minute, is24Hour = false)
        AlertDialog(
            onDismissRequest = { pickingTime = null },
            containerColor = Brand.surfaceRaised,
            title = { Text(title, style = Type.headline, color = Brand.textPrimary) },
            text = {
                TimePicker(state, colors = TimePickerDefaults.colors(clockDialColor = Brand.fieldFill, selectorColor = Brand.blue,
                    timeSelectorSelectedContainerColor = Brand.blue.copy(alpha = 0.4f), periodSelectorSelectedContainerColor = Brand.blue.copy(alpha = 0.4f)))
            },
            confirmButton = {
                TextButton(onClick = {
                    val chosen = day.withHour(state.hour).withMinute(state.minute).atZone(zone).toInstant().toEpochMilli() / 1000.0
                    onChange(if (minimum != null && chosen < minimum) minimum else chosen)
                    pickingTime = null
                }) { Text("Done", color = Brand.blueInk) }
            },
            dismissButton = { TextButton(onClick = { pickingTime = null }) { Text("Cancel", color = Brand.textSecondary) } },
        )
    }
}
