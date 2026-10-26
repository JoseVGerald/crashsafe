package org.cac.crashsafe.features.profile

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.util.PhoneFormat
import org.cac.crashsafe.core.util.Validation
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.model.FamilyContact
import org.cac.crashsafe.model.InsurerPreset
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Vehicle
import org.cac.crashsafe.ui.ActivityResults
import org.cac.crashsafe.ui.LocalActivityResults
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.ChoiceTile
import org.cac.crashsafe.ui.components.FormField
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.VehicleThumbnail
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

private val vehicleColors = listOf(
    "Black" to Color.Black, "White" to Color.White, "Silver" to Color(0xFFC0C4CC), "Gray" to Color.Gray,
    "Blue" to Brand.blue, "Red" to Brand.red, "Green" to Brand.green, "Other" to Color(0xFFB08D57),
)

/** Add or edit a vehicle. Used by onboarding, Profile and the drive picker. */
@Composable
fun VehicleEditorSheet(ownerID: String, vehicle: Vehicle? = null, onSaved: (Vehicle) -> Unit = {}, onDismiss: () -> Unit) {
    val env = LocalEnvironment.current
    var make by remember { mutableStateOf(vehicle?.make ?: "") }
    var model by remember { mutableStateOf(vehicle?.model ?: "") }
    var year by remember { mutableStateOf(vehicle?.year?.toString() ?: "") }
    var type by remember { mutableStateOf(vehicle?.type ?: CarType.sedan) }
    var colorName by remember { mutableStateOf(vehicle?.colorName ?: "") }
    var plate by remember { mutableStateOf(vehicle?.plate ?: "") }
    var attempted by remember { mutableStateOf(false) }
    val modelFocus = remember { FocusRequester() }
    val yearFocus = remember { FocusRequester() }
    val makeError = if (attempted && make.isBlank()) "Enter the make." else null
    val yearError = if (attempted && year.isNotEmpty() && (year.toIntOrNull()?.let { it in 1950..2030 } != true)) "Enter a year like 2019." else null

    fun save() {
        attempted = true
        if (make.isBlank() || (year.isNotEmpty() && year.toIntOrNull()?.let { it in 1950..2030 } != true)) return
        val saved = (vehicle ?: Vehicle(make = "", model = "")).copy(make = make.trim(), model = model.trim(), year = year.toIntOrNull(),
            type = type, colorName = colorName, plate = plate.trim().uppercase())
        env.store.updateProfile(ownerID) { profile ->
            if (vehicle == null) profile.copy(vehicles = profile.vehicles + saved.copy(isPrimary = profile.vehicles.isEmpty()))
            else profile.copy(vehicles = profile.vehicles.map { if (it.id == saved.id) saved else it })
        }
        onSaved(saved)
        onDismiss()
    }

    FullScreenSheet(onDismiss, title = if (vehicle == null) "Add vehicle" else "Edit vehicle",
        leading = BarAction("Cancel", run = onDismiss), trailing = BarAction("Save", bold = true, run = ::save)) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg, modifier = Modifier.padding(vertical = Space.md)) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Type", style = Type.subheadline.medium(), color = Brand.textSecondary)
                CarType.entries.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { option ->
                            ChoiceTile(option.label, option.systemImage, type == option, Modifier.weight(1f)) { type = option }
                        }
                    }
                }
            }
            FormField("Make", make, { make = it }, error = makeError, placeholder = "e.g. Toyota", icon = "car.fill",
                capitalization = KeyboardCapitalization.Words, onImeAction = { modelFocus.requestFocus() })
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FormField("Model", model, { model = it }, placeholder = "e.g. Camry", capitalization = KeyboardCapitalization.Words,
                    focusRequester = modelFocus, onImeAction = { yearFocus.requestFocus() }, modifier = Modifier.weight(1f))
                FormField("Year", year, { year = it.filter(Char::isDigit).take(4) }, error = yearError, placeholder = "2019",
                    keyboardType = KeyboardType.Number, focusRequester = yearFocus, modifier = Modifier.width(110.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Color", style = Type.subheadline.medium(), color = Brand.textSecondary)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    vehicleColors.forEach { (name, color) ->
                        val selected = colorName == name
                        Box(Modifier
                            .size(44.dp)
                            .border(if (selected) 2.5.dp else 0.dp, if (selected) Brand.blueInk else Color.Transparent, CircleShape)
                            .padding(5.dp)
                            .clip(CircleShape)
                            .background(color)
                            .border(1.dp, Brand.stroke, CircleShape)
                            .pressable { colorName = if (selected) "" else name }
                            .semantics { contentDescription = name + if (selected) ", selected" else "" })
                    }
                }
            }
            FormField("License plate (optional)", plate, { plate = it }, placeholder = "e.g. ABC1234", icon = "number",
                capitalization = KeyboardCapitalization.Characters, onImeAction = ::save)
        }
    }
}

/** Add a family contact: from the phone's contacts, or typed in. */
@Composable
fun ContactEditorSheet(ownerID: String, prefill: ActivityResults.PickedContact? = null, onDismiss: () -> Unit) {
    val env = LocalEnvironment.current
    val results = LocalActivityResults.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(prefill?.name ?: "") }
    var phone by remember { mutableStateOf(prefill?.phone ?: "") }
    var relationship by remember { mutableStateOf(prefill?.relationship ?: "") }
    var attempted by remember { mutableStateOf(false) }
    val nameFocus = remember { FocusRequester() }
    val phoneFocus = remember { FocusRequester() }
    val relationshipFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        runCatching { if (prefill == null) nameFocus.requestFocus() else relationshipFocus.requestFocus() }
    }
    fun add() {
        attempted = true
        if (name.isBlank() || Validation.phone(phone) != null) return
        val contact = FamilyContact(name = name.trim(), phone = PhoneFormat.display(phone.trim()), relationship = relationship.trim())
        env.store.updateProfile(ownerID) { it.copy(familyContacts = it.familyContacts + contact) }
        onDismiss()
    }
    FullScreenSheet(onDismiss, title = "Family contact", leading = BarAction("Cancel", run = onDismiss),
        trailing = BarAction("Add", bold = true, run = ::add)) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = 18.dp, modifier = Modifier.padding(vertical = Space.md)) {
            if (results != null) {
                PillButton("Choose from Contacts", {
                    scope.launch {
                        results.pickContact()?.let { picked ->
                            name = picked.name
                            phone = picked.phone
                            if (picked.relationship.isNotEmpty()) relationship = picked.relationship
                            runCatching { relationshipFocus.requestFocus() }
                        }
                    }
                }, kind = PillKind.secondary, height = 50.dp, icon = "person.crop.circle.badge.plus")
            }
            FormField("Name", name, { name = it }, error = if (attempted && name.isBlank()) "Enter a name." else null,
                placeholder = "e.g. Maria Lopez", icon = "person.fill", capitalization = KeyboardCapitalization.Words,
                focusRequester = nameFocus, onImeAction = { phoneFocus.requestFocus() })
            FormField("Phone", phone, { phone = it }, error = if (attempted) Validation.phone(phone) else null,
                placeholder = "(206) 555-0100", icon = "phone.fill", keyboardType = KeyboardType.Phone,
                focusRequester = phoneFocus, onImeAction = { relationshipFocus.requestFocus() })
            FormField("Relationship", relationship, { relationship = it }, placeholder = "e.g. Mom", icon = "heart.fill",
                capitalization = KeyboardCapitalization.Words, focusRequester = relationshipFocus, onImeAction = ::add)
        }
    }
}

/**
 * Insurance setup: one tap on a big insurer (fills in its claims number) or Other to type a name, then the
 * policy number. Used in onboarding and Profile → Insurance.
 */
@Composable
fun InsurerPicker(profile: Profile, onChange: (Profile) -> Unit) {
    var manual by remember { mutableStateOf(profile.insurer.isNotEmpty() && InsurerPreset.all.none { it.name == profile.insurer }) }
    val insurerFocus = remember { FocusRequester() }
    val policyFocus = remember { FocusRequester() }
    val phoneFocus = remember { FocusRequester() }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Your insurance company", style = Type.headline, color = Brand.textPrimary)
            val chips = InsurerPreset.all.map { it.name } + "Other"
            chips.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { name ->
                        val isOther = name == "Other"
                        val selected = if (isOther) manual else !manual && profile.insurer == name
                        InsurerChip(name, if (isOther) "pencil" else "building.columns.fill", selected, Modifier.weight(1f)) {
                            if (isOther) {
                                manual = true
                                if (InsurerPreset.all.any { it.name == profile.insurer }) onChange(profile.copy(insurer = "", insurerPhone = ""))
                                runCatching { insurerFocus.requestFocus() }
                            } else {
                                manual = false
                                val preset = InsurerPreset.all.first { it.name == name }
                                onChange(profile.copy(insurer = preset.name, insurerPhone = preset.claimsPhone))
                                runCatching { policyFocus.requestFocus() }
                            }
                        }
                    }
                    if (row.size == 1) Box(Modifier.weight(1f))
                }
            }
        }
        AnimatedVisibility(manual) {
            FormField("Insurance company", profile.insurer, { onChange(profile.copy(insurer = it)) }, placeholder = "Company name",
                icon = "building.columns.fill", capitalization = KeyboardCapitalization.Words, focusRequester = insurerFocus,
                onImeAction = { policyFocus.requestFocus() })
        }
        FormField("Policy number", profile.policyNumber, { onChange(profile.copy(policyNumber = it)) }, placeholder = "On your insurance card",
            icon = "number", capitalization = KeyboardCapitalization.Characters, focusRequester = policyFocus,
            onImeAction = { phoneFocus.requestFocus() })
        FormField("Claims phone number", profile.insurerPhone, { onChange(profile.copy(insurerPhone = it)) }, placeholder = "(800) 555-0123",
            icon = "phone.fill", keyboardType = KeyboardType.Phone, focusRequester = phoneFocus,
            onFocusLost = { onChange(profile.copy(insurerPhone = PhoneFormat.display(profile.insurerPhone))) })
        if (!manual && InsurerPreset.all.any { it.name == profile.insurer }) {
            Text("Filled in with ${profile.insurer}'s auto-claims line. If your card shows a different number, use that one.",
                style = Type.footnote, color = Brand.textSecondary)
        }
    }
}

@Composable
private fun InsurerChip(title: String, icon: String, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier
        .heightIn(min = 48.dp)
        .clip(RoundedCornerShape(Radius.small))
        .background(if (selected) Brand.blue else Brand.fieldFill)
        .pressable(onClick = onClick)
        .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
        val fg = if (selected) Color.White else Brand.textPrimary
        Icon(sf(icon), null, tint = fg, modifier = Modifier.size(16.dp))
        Text(title, style = Type.subheadline.semibold(), color = fg, maxLines = 1)
    }
}

/** Vehicle with a thumbnail, "Primary" and its details. */
@Composable
fun VehicleRow(vehicle: Vehicle, onMakePrimary: (() -> Unit)? = null, onDelete: (() -> Unit)? = null) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        VehicleThumbnail(72.dp, 50.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(vehicle.displayName, style = Type.headline, color = Brand.textPrimary, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (vehicle.isPrimary) StatusChip("Primary", "star.fill", Brand.blueInk)
                Text(vehicle.detail, style = Type.subheadline, color = Brand.textSecondary, maxLines = 1)
            }
        }
        if (onMakePrimary != null || onDelete != null) {
            Box {
                Box(Modifier.size(44.dp).clip(CircleShape).pressable { menu = true }.semantics { contentDescription = "Options for ${vehicle.displayName}" },
                    contentAlignment = Alignment.Center) {
                    Icon(sf("ellipsis"), null, tint = Brand.textSecondary)
                }
                org.cac.crashsafe.ui.components.ChoiceMenu(menu, { menu = false }, listOfNotNull(
                    if (!vehicle.isPrimary && onMakePrimary != null) org.cac.crashsafe.ui.components.MenuItem("Make primary", "star", run = onMakePrimary) else null,
                    onDelete?.let { org.cac.crashsafe.ui.components.MenuItem("Remove", "trash", run = it) },
                ))
            }
        }
    }
}

/** Contact with initials, relationship and number. */
@Composable
fun ContactRow(contact: FamilyContact, onRemove: (() -> Unit)? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Initials(contact.name, 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(contact.name, style = Type.headline, color = Brand.textPrimary)
            Text(listOf(contact.relationship, PhoneFormat.display(contact.phone)).filter { it.isNotEmpty() }.joinToString(" · "),
                style = Type.subheadline, color = Brand.textSecondary)
        }
        if (onRemove != null) {
            Box(Modifier.size(44.dp).clip(CircleShape).pressable(onClick = onRemove).semantics { contentDescription = "Remove ${contact.name}" },
                contentAlignment = Alignment.Center) {
                Icon(sf("minus.circle.fill"), null, tint = Brand.redInk)
            }
        }
    }
}

@Composable
fun Initials(name: String, size: androidx.compose.ui.unit.Dp) {
    val initials = name.split(" ").filter { it.isNotEmpty() }.take(2).mapNotNull { it.firstOrNull()?.toString() }.joinToString("").uppercase()
    Box(Modifier.size(size).clip(CircleShape).background(Brand.teal), contentAlignment = Alignment.Center) {
        Text(initials, style = if (size > 50.dp) Type.title3.semibold() else Type.headline, color = Color.White)
    }
}
