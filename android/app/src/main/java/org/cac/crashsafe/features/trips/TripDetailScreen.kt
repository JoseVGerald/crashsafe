package org.cac.crashsafe.features.trips

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.model.HelpPlace
import org.cac.crashsafe.model.TripPackStatus
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.MapMarker
import org.cac.crashsafe.ui.components.OsmMap
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PushedScreen
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.StatusRow
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

fun helpTint(category: HelpPlace.Category): Color = when (category) {
    HelpPlace.Category.hospital -> Brand.red
    HelpPlace.Category.police -> Brand.blue
    HelpPlace.Category.towing -> Brand.amber
}

@Composable
fun TripDetailScreen(tripID: String, onBack: () -> Unit) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val trip = env.store.trip(tripID)
    if (trip == null) {
        onBack()
        return
    }
    Box(Modifier.statusBarsPadding()) {
        PushedScreen(trip.destination, onBack) {
            ReadableColumn(modifier = Modifier.padding(bottom = Space.lg)) {
                val from = trip.originCoordinate
                val to = trip.destinationCoordinate
                if (from != null && to != null) {
                    val markers = listOf(MapMarker(from.first, from.second, trip.origin, Brand.green), MapMarker(to.first, to.second, trip.destination, Brand.red, large = true)) +
                        (trip.tripPack?.allPlaces ?: emptyList()).map { MapMarker(it.latitude, it.longitude, it.name, helpTint(it.category)) }
                    OsmMap(Modifier.fillMaxWidth().height(220.dp).clip(RoundedCornerShape(Radius.card)).fadeUp(), center = to,
                        markers = markers, interactive = false, fitToContent = true)
                }
                Column(Modifier.card(Space.md + 4.dp).fadeUp(0.05), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatusRow("circle.circle.fill", "From", trip.origin, Brand.greenInk)
                    StatusRow("mappin.circle.fill", "To", trip.destination, Brand.redInk)
                    StatusRow("calendar", "Dates", "${Formats.monthDayTime(trip.startDate)} – ${Formats.monthDay(trip.endDate)}")
                    trip.routeSummary?.let { StatusRow("car.fill", "Drive", it) }
                }
                Column(Modifier.card(Space.md + 4.dp).fadeUp(0.1), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Offline trip pack", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
                        if (trip.tripPackStatus == TripPackStatus.downloading) {
                            CircularProgressIndicator(Modifier.size(20.dp), color = Brand.blueInk, strokeWidth = 2.dp)
                        } else {
                            StatusChip(trip.tripPackStatus.label, tint = if (trip.tripPackStatus == TripPackStatus.ready) Brand.greenInk else Brand.textSecondary)
                        }
                    }
                    Text("Tow companies, hospitals and police along your route, saved so help works with no signal.", style = Type.subheadline, color = Brand.textSecondary)
                    trip.tripPack?.let { pack ->
                        pack.allPlaces.take(9).forEach { place ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                IconBadge(place.category.systemImage, helpTint(place.category), 34.dp)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Text(place.name, style = Type.subheadline.semibold(), color = Brand.textPrimary, maxLines = 1)
                                    Text(place.phone.ifEmpty { place.category.title }, style = Type.caption, color = Brand.textSecondary)
                                }
                                if (place.phone.isNotEmpty()) {
                                    Box(Modifier.size(44.dp).clip(CircleShape).pressable { Actions.call(context, place.phone) }
                                        .semantics { contentDescription = "Call ${place.name}" }, contentAlignment = Alignment.Center) {
                                        Icon(sf("phone.circle.fill"), null, tint = Brand.greenInk, modifier = Modifier.size(28.dp))
                                    }
                                }
                            }
                        }
                        trip.tripPackUpdatedAt?.let { Text("Updated ${Formats.relative(it)}", style = Type.caption, color = Brand.textSecondary) }
                    }
                    val ready = trip.tripPackStatus == TripPackStatus.ready
                    PillButton(if (ready) "Refresh trip pack" else "Download trip pack", { TripPacks.download(env.store, env.tripPacks, env.scope, trip.id) },
                        kind = if (ready) PillKind.secondary else PillKind.primary, enabled = trip.tripPackStatus != TripPackStatus.downloading)
                }
                Spacer(Modifier.height(Space.md))
            }
        }
    }
}
