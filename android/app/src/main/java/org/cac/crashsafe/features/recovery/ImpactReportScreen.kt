@file:OptIn(ExperimentalMaterial3Api::class)

package org.cac.crashsafe.features.recovery

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.cac.crashsafe.core.report.ImpactReportFacts
import org.cac.crashsafe.features.checkin.ImpactSummary
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInRecord
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.FormField
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.sf
import java.io.File

/** The impact report sheet: "For you" and "For police & insurer", with ways to send or show the second. */
@Composable
fun ImpactReportSheet(recordID: String, user: AuthUser, onDismiss: () -> Unit) {
    val env = LocalEnvironment.current
    val record = env.store.checkIn(recordID) ?: return
    FullScreenSheet(onDismiss, title = "Impact report", trailing = BarAction("Done", bold = true, run = onDismiss)) {
        ImpactReportContent(record, env.store.profile(user.id), user.name)
    }
}

@Composable
private fun ImpactReportContent(record: CheckInRecord, profile: Profile?, driverName: String) {
    val env = LocalEnvironment.current
    var official by remember { mutableStateOf(false) }
    var includeMedical by remember { mutableStateOf(false) }
    val snapshot = record.snapshot
    ReadableColumn(spacing = Space.md, modifier = Modifier.padding(vertical = Space.md)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            listOf("For you", "For police & insurer").forEachIndexed { index, title ->
                SegmentedButton(selected = official == (index == 1), onClick = { official = index == 1 },
                    shape = SegmentedButtonDefaults.itemShape(index, 2),
                    colors = SegmentedButtonDefaults.colors(activeContainerColor = Brand.blue, activeContentColor = Color.White,
                        inactiveContainerColor = Brand.fieldFill, inactiveContentColor = Brand.textPrimary, activeBorderColor = Brand.stroke,
                        inactiveBorderColor = Brand.stroke)) {
                    Text(title, style = Type.subheadline)
                }
            }
        }
        if (snapshot == null) {
            Text("This check-in has no impact details saved.", style = Type.body, color = Brand.textSecondary)
            return@ReadableColumn
        }
        val vehicle = profile?.primaryVehicle?.let { car ->
            listOfNotNull(car.year?.toString(), car.make, car.model).filter { it.isNotEmpty() }.joinToString(" ") +
                (if (car.colorName.isEmpty()) "" else ", ${car.colorName.lowercase()}") + (if (car.plate.isEmpty()) "" else ", plate ${car.plate}")
        }
        val medical = if (includeMedical) profile?.let { p ->
            listOfNotNull(if (p.bloodType.isEmpty()) null else "blood type ${p.bloodType}", p.medicalNotes.ifEmpty { null }).joinToString("; ")
        } else null
        val facts = ImpactReportFacts(snapshot = snapshot, outcome = record.outcome, driverName = driverName, vehicle = vehicle,
            insurer = profile?.insurer ?: "", policyNumber = profile?.policyNumber ?: "", claimsPhone = profile?.insurerPhone ?: "",
            otherDriver = record.otherDriver, otherInsurance = record.otherInsurance, otherPlate = record.otherPlate,
            policeReportNumber = record.policeReportNumber, medical = medical)
        if (!official) {
            Personal(facts) { official = true }
        } else {
            Official(facts, record, includeMedical) { includeMedical = it }
        }
    }
}

@Composable
private fun Personal(facts: ImpactReportFacts, openOfficial: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.md)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(facts.headline, style = Type.title2.bold(), color = Brand.textPrimary)
            Text(if (facts.snapshot.latitude == null && facts.snapshot.street == null) "Location wasn't available" else facts.whereText,
                style = Type.subheadline, color = Brand.textSecondary)
        }
        facts.snapshot.impact?.let { ImpactSummary(it) }
        Section("What your phone felt", "waveform.path.ecg") { facts.whatHappened.forEach { Text(it, style = Type.callout, color = Brand.textPrimary) } }
        Section("Look after yourself", "heart.text.square.fill") { Text(ImpactReportFacts.lookAfterYourself, style = Type.callout, color = Brand.textPrimary) }
        Section("Next steps", "checklist") {
            ImpactReportFacts.nextSteps.forEachIndexed { index, step ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.size(22.dp).clip(CircleShape).background(Brand.blueInk), contentAlignment = Alignment.Center) {
                        Text("${index + 1}", style = Type.caption.bold(), color = Brand.navy)
                    }
                    Text(step, style = Type.callout, color = Brand.textPrimary)
                }
            }
        }
        PillButton("Open the police & insurer copy", openOfficial, height = 54.dp, icon = "doc.text.fill")
    }
}

@Composable
private fun Official(facts: ImpactReportFacts, record: CheckInRecord, includeMedical: Boolean, setIncludeMedical: (Boolean) -> Unit) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun edit(transform: (CheckInRecord) -> CheckInRecord) = env.store.updateCheckIn(record.id, transform)
    Column(verticalArrangement = Arrangement.spacedBy(Space.md)) {
        Text("Facts only, ready to show an officer or send to your insurer or agent.", style = Type.subheadline, color = Brand.textSecondary)
        OfficialReportCard(facts.officialText)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton("Send by text or email", { Actions.shareText(context, facts.officialText, "Collision facts") }, height = 54.dp, icon = "square.and.arrow.up")
            PillButton("Save or send as a picture", {
                scope.launch {
                    val file = withContext(Dispatchers.IO) { picture(context, facts.officialText) }
                    Actions.shareFile(context, file, "image/png")
                }
            }, kind = PillKind.secondary, height = 50.dp, icon = "photo")
            if (facts.claimsPhone.isNotEmpty()) {
                PillButton("Call ${facts.insurer.ifEmpty { "your insurer" }}", { Actions.call(context, facts.claimsPhone) }, kind = PillKind.secondary,
                    height = 50.dp, icon = "phone.fill")
            }
        }
        Section("Add the other driver's details", "person.2.fill") {
            FormField("", record.otherDriver, { v -> edit { it.copy(otherDriver = v) } }, placeholder = "Other driver's name and phone",
                capitalization = KeyboardCapitalization.Words)
            FormField("", record.otherInsurance, { v -> edit { it.copy(otherInsurance = v) } }, placeholder = "Their insurance and policy number",
                capitalization = KeyboardCapitalization.Words)
            FormField("", record.otherPlate, { v -> edit { it.copy(otherPlate = v) } }, placeholder = "Their license plate",
                capitalization = KeyboardCapitalization.Characters)
            FormField("", record.policeReportNumber, { v -> edit { it.copy(policeReportNumber = v) } }, placeholder = "Police report number",
                capitalization = KeyboardCapitalization.Characters)
        }
        Row(Modifier.card(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Add my blood type and medical notes (for a medical claim)", style = Type.subheadline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            Switch(includeMedical, setIncludeMedical, colors = SwitchDefaults.colors(checkedTrackColor = Brand.blue))
        }
    }
}

@Composable
private fun Section(title: String, icon: String, content: @Composable () -> Unit) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(sf(icon), null, tint = Brand.textPrimary, modifier = Modifier.size(20.dp))
            Text(title, style = Type.headline, color = Brand.textPrimary)
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { content() }
    }
}

/** The police & insurer copy, laid out like a printed form (black on white, readable at arm's length). */
@Composable
fun OfficialReportCard(text: String) {
    SelectionContainer {
        Text(text, style = Type.footnote.copy(fontFamily = FontFamily.Monospace), color = Color.Black,
            modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp).clip(RoundedCornerShape(12.dp)).background(Color.White)
                .border(1.dp, Color.Black.copy(alpha = 0.15f), RoundedCornerShape(12.dp)).padding(16.dp))
    }
}

/** The police & insurer copy as a PNG, for showing an officer or attaching to a message. */
private fun picture(context: Context, text: String): File {
    val density = 3f
    val width = (380 * density).toInt()
    val padding = 16 * density
    val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
        color = android.graphics.Color.BLACK
        textSize = 13 * density
        typeface = Typeface.MONOSPACE
    }
    val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, (width - 2 * padding).toInt())
        .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(0f, 1.2f).build()
    val height = (layout.height + 2 * padding).toInt()
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(android.graphics.Color.WHITE)
    canvas.translate(padding, padding)
    layout.draw(canvas)
    val folder = File(context.cacheDir, "shared").apply { mkdirs() }
    val file = File(folder, "collision-facts.png")
    file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    return file
}
