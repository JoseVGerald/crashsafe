package org.cac.crashsafe.features.profile

import android.content.Intent
import android.media.MediaPlayer
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.cac.crashsafe.R
import org.cac.crashsafe.core.driving.DriveScenario
import org.cac.crashsafe.core.intelligence.HarshEvent
import org.cac.crashsafe.core.intelligence.TransportClass
import org.cac.crashsafe.core.sensors.SensorState
import org.cac.crashsafe.core.util.PhoneFormat
import org.cac.crashsafe.features.recovery.RecoveryScreen
import org.cac.crashsafe.features.sensorlab.SensorLabScreen
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.model.FamilyContact
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Vehicle
import org.cac.crashsafe.services.intelligence.MotionIntelligence
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.BrandSwitch
import org.cac.crashsafe.ui.components.ChoiceMenu
import org.cac.crashsafe.ui.components.ChoiceTile
import org.cac.crashsafe.ui.components.ConfirmDialog
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.Hairline
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.MenuItem
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.RowLabel
import org.cac.crashsafe.ui.components.SafetyNotice
import org.cac.crashsafe.ui.components.SectionHeader
import org.cac.crashsafe.ui.components.SegmentedControl
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.VehicleThumbnail
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

@Composable
fun ProfileScreen(user: AuthUser) {
    val env = LocalEnvironment.current
    val profile = env.store.profile(user.id)
    if (profile == null) {
        Box(Modifier.fillMaxSize().background(Brand.background))
        return
    }
    ProfileContent(user, profile) { transform -> env.store.updateProfile(user.id, transform) }
}

@Composable
private fun ProfileContent(user: AuthUser, profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    val env = LocalEnvironment.current
    var addingVehicle by remember { mutableStateOf(false) }
    var editingVehicle by remember { mutableStateOf<Vehicle?>(null) }
    var addingContact by remember { mutableStateOf(false) }
    var editingMedical by remember { mutableStateOf(false) }
    var editingInsurance by remember { mutableStateOf(false) }
    var showingNearbyHelp by remember { mutableStateOf(false) }
    var showingSensorLab by remember { mutableStateOf(false) }
    var confirmingSignOut by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        // Tidy numbers saved before formatting existed.
        val tidy = PhoneFormat.display(profile.insurerPhone)
        if (tidy != profile.insurerPhone) update { it.copy(insurerPhone = tidy) }
    }

    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().verticalScroll(rememberScrollState())) {
        ReadableColumn(spacing = Space.lg, modifier = Modifier.padding(bottom = Space.lg)) {
            PageHeader("Your safety profile", "Key information to keep you safe on the road and help in an emergency.",
                Modifier.padding(top = Space.lg).fadeUp())
            Vehicles(profile, update, onAdd = { addingVehicle = true }, onEdit = { editingVehicle = it }, Modifier.fadeUp(0.04))
            Medical(profile, onEdit = { editingMedical = true }, Modifier.fadeUp(0.08))

            PageHeader("Support details", "Insurance and emergency contacts, so the right people can be reached quickly.",
                Modifier.padding(top = Space.sm).fadeUp(0.1))
            Insurance(profile, onEdit = { editingInsurance = true }, Modifier.fadeUp(0.12))
            Contacts(profile, update, onAdd = { addingContact = true }, Modifier.fadeUp(0.16))
            LockRow("Stored on this phone", "Only you can see this information.", Modifier.card().fadeUp(0.18))

            DrivingSection(profile, update)

            SafetyNotice(Modifier.padding(horizontal = Space.xs))

            Account(user, onSignOut = { confirmingSignOut = true }, onDelete = { confirmingDelete = true }, deleteError)

            Testing(profile, update, onSensorLab = { showingSensorLab = true }, onNearbyHelp = { showingNearbyHelp = true })
        }
    }

    if (addingVehicle) VehicleEditorSheet(user.id, onDismiss = { addingVehicle = false })
    editingVehicle?.let { vehicle -> VehicleEditorSheet(user.id, vehicle, onDismiss = { editingVehicle = null }) }
    if (addingContact) ContactEditorSheet(user.id, onDismiss = { addingContact = false })
    if (editingMedical) MedicalEditorSheet(profile, update) { editingMedical = false }
    if (editingInsurance) InsuranceEditorSheet(profile, update) { editingInsurance = false }
    if (showingNearbyHelp) {
        FullScreenSheet(onDismiss = { showingNearbyHelp = false }, showsBar = false, scrolls = false) {
            RecoveryScreen(user, outcome = null) { showingNearbyHelp = false }
        }
    }
    if (showingSensorLab) {
        FullScreenSheet(onDismiss = { showingSensorLab = false }, showsBar = false, scrolls = false) {
            SensorLabScreen { showingSensorLab = false }
        }
    }
    if (confirmingDelete) {
        ConfirmDialog("Delete your account?",
            "This permanently deletes your account, profile, vehicles, contacts, trips and check-ins from this phone.",
            "Delete account and data", onConfirm = {
                env.scope.launch {
                    try {
                        env.session.deleteAccount()
                        env.store.deleteAll(user.id)
                    } catch (e: Exception) {
                        deleteError = e.message ?: "Couldn't delete the account."
                    }
                }
            }, onDismiss = { confirmingDelete = false })
    }
    if (confirmingSignOut) {
        ConfirmDialog("Sign out of CrashSafe?", "Your profile and trips stay saved on this phone.", "Sign out",
            onConfirm = { env.session.signOut() }, onDismiss = { confirmingSignOut = false })
    }
}

// Safety profile

@Composable
private fun Vehicles(profile: Profile, update: ((Profile) -> Profile) -> Unit, onAdd: () -> Unit, onEdit: (Vehicle) -> Unit, modifier: Modifier) {
    Column(modifier.animateContentSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle("Vehicles", "Add vehicle", "plus.circle", onAdd)
        if (profile.vehicles.isEmpty()) EmptyRow("Add the cars you drive.", "car.fill", onAdd)
        profile.sortedVehicles.forEach { vehicle ->
            VehicleCard(vehicle, onClick = { onEdit(vehicle) },
                onMakePrimary = if (vehicle.isPrimary) null else ({ update { it.makingPrimary(vehicle.id) } }),
                onRemove = { update { it.removingVehicle(vehicle.id) } })
        }
    }
}

@Composable
private fun Medical(profile: Profile, onEdit: () -> Unit, modifier: Modifier) {
    val summary = medicalSummary(profile)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle("Medical information", "Edit", "pencil", onEdit)
        Column(Modifier.card(Space.md + 4.dp)) {
            Row(Modifier.fillMaxWidth().pressable(onClick = onEdit).padding(vertical = Space.sm), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.md)) {
                Icon(sf("staroflife.fill"), null, tint = Brand.blueInk, modifier = Modifier.width(40.dp).size(30.dp))
                Text(summary ?: "Add allergies, conditions and medications", modifier = Modifier.weight(1f),
                    style = Type.body.copy(fontWeight = if (summary == null) FontWeight.Normal else FontWeight.Medium),
                    color = if (summary == null) Brand.textSecondary else Brand.textPrimary)
            }
            Hairline(Modifier.padding(vertical = 12.dp))
            LockRow("Stored on this phone", "Shown on your crash screen so responders can help.")
        }
    }
}

/** One item per sentence, comma or line: "Allergic to penicillin. Asthma" → "Allergic to penicillin · Asthma". */
internal fun medicalSummary(profile: Profile): String? {
    val parts = profile.medicalNotes.replace(". ", "\n")
        .split('\n', ',', ';')
        .map { it.trim(' ', '\t', '.') }
        .filter { it.isNotEmpty() }
        .toMutableList()
    if (profile.bloodType.isNotEmpty()) parts.add("Blood type ${profile.bloodType}")
    return if (parts.isEmpty()) null else parts.joinToString(" · ")
}

// Support details

@Composable
private fun Insurance(profile: Profile, onEdit: () -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val haptics = LocalHapticFeedback.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle("Insurance", "Edit", "pencil", onEdit)
        Column(Modifier.card(Space.md + 4.dp)) {
            Row(Modifier.padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.md)) {
                Icon(sf("building.columns"), null, tint = Brand.blueInk, modifier = Modifier.width(40.dp).size(26.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(profile.insurer.ifEmpty { "Add your insurer" }, style = Type.headline,
                        color = if (profile.insurer.isEmpty()) Brand.textSecondary else Brand.textPrimary)
                    Text("Auto insurance", style = Type.subheadline, color = Brand.textSecondary)
                }
            }
            Hairline()
            DetailRow("Policy number", maskedPolicy(profile.policyNumber)) {
                if (profile.policyNumber.isNotEmpty()) {
                    Box(Modifier.size(44.dp).clip(CircleShape).pressable {
                        clipboard.setText(AnnotatedString(profile.policyNumber))
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        copied = true
                    }.semantics { contentDescription = if (copied) "Copied" else "Copy policy number" }, contentAlignment = Alignment.Center) {
                        Icon(sf(if (copied) "checkmark" else "doc.on.doc"), null, tint = Brand.blueInk)
                    }
                }
            }
            Hairline()
            val phone = profile.insurerPhone.takeIf { it.isNotEmpty() }?.let { PhoneFormat.display(it) }
            DetailRow("Claims phone", phone, icon = "phone.fill") {
                if (PhoneFormat.dialable(profile.insurerPhone).isNotEmpty()) {
                    Box(Modifier.size(44.dp).clip(CircleShape).pressable { Actions.call(context, profile.insurerPhone) }
                        .semantics { contentDescription = "Call claims" }, contentAlignment = Alignment.Center) {
                        Icon(sf("phone.fill"), null, tint = Brand.blueInk)
                    }
                }
            }
        }
    }
}

internal fun maskedPolicy(policyNumber: String): String? {
    val policy = policyNumber.trim()
    if (policy.isEmpty()) return null
    return if (policy.length <= 4) policy else "•••• · " + policy.takeLast(4)
}

@Composable
private fun Contacts(profile: Profile, update: ((Profile) -> Profile) -> Unit, onAdd: () -> Unit, modifier: Modifier) {
    Column(modifier.animateContentSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionTitle("Family contacts", "Add contact", "plus.circle", onAdd)
        if (profile.familyContacts.isEmpty()) EmptyRow("Add people to alert if you don't respond.", "person.2.fill", onAdd)
        profile.sortedContacts.forEach { contact ->
            FamilyContactCard(contact) { update { p -> p.copy(familyContacts = p.familyContacts.filter { it.id != contact.id }) } }
        }
    }
}

// Driving

@Composable
private fun DrivingSection(profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val permissions = env.permissions
    @Suppress("UNUSED_EXPRESSION") permissions.version
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionHeader("Driving")
        Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Watch every drive", style = Type.body.medium(), color = Brand.textPrimary)
                    Text("Keeps coaching and crash checks running in the background during trips.", style = Type.footnote, color = Brand.textSecondary)
                }
                BrandSwitch(profile.autoDetectDrives, { on ->
                    update { it.copy(autoDetectDrives = on) }
                    // Watching drives that start while the app is closed needs "Allow all the time" location.
                    if (on && !env.location.hasAlwaysAccess && env.location.canPromptForAlways) env.location.requestAlwaysPermission()
                }, Modifier.semantics { contentDescription = "Watch every drive" })
            }
            Hairline()
            val location = locationStatus(env.location.hasAlwaysAccess, env.location.isAuthorized, env.location.isDenied, env.location.canPromptForAlways)
            PermissionRow("Background location", "location.fill", location.first, env.location.hasAlwaysAccess, location.second) {
                if (!env.location.requestAlwaysPermission() && !env.location.hasAlwaysAccess) permissions.openSettings()
            }
            Hairline()
            PermissionRow("Physical activity", "figure.walk.motion", status(permissions.motionGranted, permissions.motionDenied), permissions.motionGranted,
                if (permissions.motionDenied) "Open Settings" else "Allow") { scope.launch { permissions.requestMotion() } }
            Hairline()
            PermissionRow("Notifications", "bell.badge.fill", status(permissions.notificationsGranted, permissions.notificationsDenied),
                permissions.notificationsGranted, if (permissions.notificationsDenied) "Open Settings" else "Allow") {
                scope.launch { permissions.requestNotifications() }
            }
            if (!permissions.notificationsGranted) {
                Text("Without notifications, a crash check-in can't reach you while the phone is locked.", style = Type.footnote, color = Brand.amberInk)
            }
            if (profile.autoDetectDrives && !env.location.hasAlwaysAccess) {
                Text("Without “Allow all the time”, Pulse can only watch drives while CrashSafe is open or recently used.",
                    style = Type.footnote, color = Brand.amberInk)
            }
        }
    }
}

private fun locationStatus(always: Boolean, authorized: Boolean, denied: Boolean, canPrompt: Boolean): Pair<String, String> = when {
    always -> "All the time" to ""
    authorized -> "While using the app" to if (canPrompt) "Allow all the time" else "Open Settings"
    denied -> "Off" to "Open Settings"
    else -> "Not set" to "Allow"
}

private fun status(granted: Boolean, denied: Boolean) = if (granted) "Allowed" else if (denied) "Off" else "Not set"

@Composable
private fun PermissionRow(title: String, icon: String, status: String, ok: Boolean, action: String, run: () -> Unit) {
    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(sf(icon), null, tint = if (ok) Brand.greenInk else Brand.amberInk, modifier = Modifier.width(28.dp).size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.body.medium(), color = Brand.textPrimary)
            Text(status, style = Type.footnote, color = Brand.textSecondary)
        }
        if (ok) {
            Icon(sf("checkmark.circle.fill"), "Allowed", tint = Brand.greenInk, modifier = Modifier.size(24.dp))
        } else {
            Box(Modifier.heightIn(min = 44.dp), contentAlignment = Alignment.Center) {
                Text(action, style = Type.subheadline.semibold(), color = Brand.blueInk,
                    modifier = Modifier.clip(CircleShape).background(Brand.blueInk.copy(alpha = 0.12f)).pressable(onClick = run)
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }
        }
    }
}

// Account

@Composable
private fun Account(user: AuthUser, onSignOut: () -> Unit, onDelete: () -> Unit, deleteError: String?) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Column(Modifier.padding(bottom = Space.xs), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(user.name.ifEmpty { "Signed in" }, style = Type.subheadline.semibold(), color = Brand.textPrimary)
            Text(user.email, style = Type.footnote, color = Brand.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        PillButton("Sign out", onSignOut, kind = PillKind.ghost, height = 48.dp, foreground = Brand.redInk)
        LinkButton("Delete account", onDelete, color = Brand.textSecondary, style = Type.subheadline)
        deleteError?.let { Text(it, style = Type.footnote, color = Brand.redInk) }
    }
}

// Testing

/** Everything that exists for demos and development lives here, out of the everyday flow. */
@Composable
private fun Testing(profile: Profile, update: ((Profile) -> Profile) -> Unit, onSensorLab: () -> Unit, onNearbyHelp: () -> Unit) {
    val env = LocalEnvironment.current
    var delayedCrashSeconds by remember { mutableStateOf<Int?>(null) }
    var demoMenu by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.padding(horizontal = Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Text("Testing", style = Type.title3.semibold(), color = Brand.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
            StatusChip("For testing only", "hammer.fill", Brand.amberInk)
        }
        Text("Demo and development tools. You don't need these for everyday driving.", style = Type.footnote, color = Brand.textSecondary,
            modifier = Modifier.padding(horizontal = Space.xs))

        Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("How Pulse coaches you", style = Type.headline, color = Brand.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CoachingStyle.entries.forEach { style ->
                    ChoiceTile(if (style == CoachingStyle.logical) "Facts" else "Heart", style.systemImage, profile.coachingStyle == style,
                        Modifier.weight(1f)) { update { it.copy(coachingStyle = style) } }
                }
            }
            Text(profile.coachingStyle.subtitle, style = Type.footnote, color = Brand.textSecondary)
            SegmentedControl(DrivingExperience.entries, profile.experience, { it.label }) { option -> update { it.copy(experience = option) } }
        }

        PulseVoiceCard()

        Column(Modifier.card()) {
            TestRow("Sensor lab: tilt, gyro, speed, replays", "gyroscope", onClick = onSensorLab)
            Hairline()
            val scenario = env.driving.scenario
            if (scenario != null) {
                TestRow("Stop demo drive · ${scenario.title}", "stop.fill") {
                    env.driving.stop()
                    env.conditions.override(null)
                    env.scope.launch { env.conditions.refresh(env.location.location, force = true) }
                }
            } else {
                Box {
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).pressable { demoMenu = true }, verticalAlignment = Alignment.CenterVertically) {
                        RowLabel("Try a demo drive", "play.fill")
                        Icon(sf("chevron.up.chevron.down"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
                    }
                    ChoiceMenu(demoMenu, { demoMenu = false }, DriveScenario.entries.map { s ->
                        MenuItem(s.title, s.systemImage) {
                            env.driving.startDemo(s)
                            env.conditions.override(s.weather)
                        }
                    })
                }
            }
            Hairline()
            TestRow("Drive mode (Android Auto style)", "car.rear.fill") { env.router.showingCarPlay = true }
            Hairline()
            TestRow("Nearby help", "cross.case.fill", onClick = onNearbyHelp)
            Hairline()
            TestRow("Test crash", "car.side.rear.and.collision.and.car.side.front", Brand.redInk) { env.crashDetector.simulateCrash() }
            Hairline()
            TestRow(delayedCrashSeconds?.let { "Lock your phone now… $it" } ?: "Test crash in 10 s (lock phone)", "lock.iphone", Brand.redInk,
                enabled = delayedCrashSeconds == null) {
                // Fires a simulated crash after 10 s so the lock-screen check-in can be tried for real.
                val release = env.crashCenter.keepAlive("Locked test crash")
                delayedCrashSeconds = 10
                env.scope.launch {
                    for (remaining in 9 downTo 0) {
                        delay(1000)
                        delayedCrashSeconds = if (remaining == 0) null else remaining
                    }
                    env.crashDetector.simulateCrash()
                    delay(1000)
                    release()
                }
            }
            Hairline()
            TestRow("Redo setup", "arrow.counterclockwise") { update { it.copy(onboardingCompleted = false) } }
        }

        BackgroundSensorCheckCard()
        MotionAnalysisCard()
    }
}

@Composable
private fun TestRow(title: String, icon: String, tint: Color = Brand.textPrimary, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).pressable(enabled, onClick), verticalAlignment = Alignment.CenterVertically) {
        RowLabel(title, icon, tint)
        Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
    }
}

/** The transport-mode model and harsh-event rules, live. */
@Composable
private fun MotionAnalysisCard() {
    val env = LocalEnvironment.current
    val intelligence = env.intelligence
    var menu by remember { mutableStateOf(false) }
    val ranked = intelligence.current?.probabilities?.withIndex()?.sortedByDescending { it.value }?.take(3)
        ?.mapNotNull { (i, p) -> TransportClass.entries.getOrNull(i)?.let { it to p } } ?: emptyList()
    val recent = intelligence.harshEvents(600.0)
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Motion analysis", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            Text("${intelligence.windowsAnalyzed} windows", style = Type.footnote, color = Brand.textSecondary)
        }
        Text("5-second windows at 50 Hz (the transport repo's input), every 2.5 s, from the rolling sensor history.",
            style = Type.footnote, color = Brand.textSecondary)
        if (ranked.isEmpty()) {
            Text(if (env.sensors.health.state == SensorState.unavailable) "No motion sensor on this device." else "Waiting for the first window…",
                style = Type.subheadline, color = Brand.textSecondary)
        }
        ranked.forEach { (mode, p) ->
            Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(sf(mode.systemImage), null, tint = Brand.blueInk, modifier = Modifier.width(24.dp).size(20.dp))
                Text(mode.title, style = Type.subheadline, color = Brand.textPrimary, modifier = Modifier.width(96.dp))
                Box(Modifier.weight(1f).heightIn(min = 8.dp, max = 8.dp).clip(CircleShape).background(Brand.fieldFill)) {
                    Box(Modifier.fillMaxWidth(p.toFloat().coerceIn(0.03f, 1f)).heightIn(min = 8.dp, max = 8.dp).clip(CircleShape).background(Brand.blue))
                }
                Text("${Math.round(p * 100)}%", style = Type.footnote, color = Brand.textSecondary, modifier = Modifier.width(40.dp))
            }
        }
        Hairline()
        Text("Hard brakes / accelerations, last 10 min: ${recent.count { it.event.kind == HarshEvent.Kind.harshBrake }} / " +
            "${recent.count { it.event.kind == HarshEvent.Kind.harshAccel }}", style = Type.footnote, color = Brand.textSecondary)
        Text("Model: ${intelligence.model.modelID}", style = Type.caption.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
            color = Brand.textSecondary)
        Box {
            LinkButton("Replay test motion", { menu = true }, icon = "play.circle")
            ChoiceMenu(menu, { menu = false }, MotionIntelligence.TestMotion.entries.map { kind -> MenuItem(kind.title) { intelligence.replay(kind) } })
        }
    }
}

/** Proof that sensors keep running with the app closed or the phone locked. */
@Composable
private fun BackgroundSensorCheckCard() {
    val env = LocalEnvironment.current
    val log = env.sensors.backgroundLog
    val running = env.sensors.isRunning
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Background sensor check", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            StatusChip(if (running) "Sensors on" else "Sensors off", if (running) "dot.radiowaves.left.and.right" else "pause.circle",
                if (running) Brand.greenInk else Brand.textSecondary)
        }
        Text("Start a drive, lock the phone for a minute, then come back. These counts only go up while CrashSafe is off screen.",
            style = Type.footnote, color = Brand.textSecondary)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            GridRow("", "Motion", "GPS", header = true)
            GridRow("In background", "%,d".format(log.backgroundMotion), "%,d".format(log.backgroundLocation))
            GridRow("While locked", "%,d".format(log.lockedMotion), "%,d".format(log.lockedLocation))
        }
        Text(if (log.isEmpty) "No off-screen readings yet." else "Longest motion gap off screen: ${"%.2f".format(log.longestBackgroundGap)} s",
            style = Type.footnote, color = Brand.textSecondary)
        LinkButton("Reset counts", { env.sensors.resetBackgroundLog() })
    }
}

@Composable
private fun GridRow(title: String, motion: String, gps: String, header: Boolean = false) {
    val style = if (header) Type.caption.semibold() else Type.subheadline
    val color = if (header) Brand.textSecondary else Brand.textPrimary
    Row(horizontalArrangement = Arrangement.spacedBy(Space.md)) {
        Text(title, style = Type.subheadline, color = Brand.textPrimary, modifier = Modifier.width(120.dp))
        Text(motion, style = style, color = color, modifier = Modifier.width(72.dp))
        Text(gps, style = style, color = color, modifier = Modifier.width(72.dp))
    }
}

/**
 * Profile → Testing: pick the voice Pulse speaks with offline, hear it, and get a better one for free.
 * Android's best voices are free downloads in the text-to-speech settings (Speech Services by Google).
 */
@Composable
private fun PulseVoiceCard() {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val voice = env.voice
    var menu by remember { mutableStateOf(false) }
    var showingHowTo by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(voice.preferredID) }
    var clip by remember { mutableStateOf<MediaPlayer?>(null) }
    DisposableEffect(Unit) { onDispose { clip?.release(); voice.stop() } }
    val current = voice.options.firstOrNull { it.id == selected } ?: voice.options.firstOrNull()

    fun preview(id: String?) {
        clip?.stop()
        env.scope.launch { voice.say("Hi, I'm Pulse. You're doing 42 in a 30. Imagine a child running out 110 feet ahead.", rate = 0.96f, voiceID = id) }
    }

    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Pulse's voice", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            current?.let {
                StatusChip(it.qualityLabel, if (it.isNatural) "sparkles" else "waveform", if (it.isNatural) Brand.greenInk else Brand.amberInk)
            }
        }
        Box {
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).pressable(enabled = voice.options.isNotEmpty()) { menu = true },
                verticalAlignment = Alignment.CenterVertically) {
                Text("Voice", style = Type.body, color = Brand.textPrimary, modifier = Modifier.weight(1f))
                Text(current?.let { "${it.name} · ${it.qualityLabel}" } ?: if (voice.isReady) "None installed" else "Loading…",
                    style = Type.subheadline, color = Brand.blueInk, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1.4f, fill = false))
                Icon(sf("chevron.up.chevron.down"), null, tint = Brand.blueInk, modifier = Modifier.padding(start = 4.dp).size(14.dp))
            }
            ChoiceMenu(menu, { menu = false }, voice.options.map { option ->
                MenuItem("${option.name} · ${option.qualityLabel} · ${option.language}") {
                    voice.choose(option.id)
                    selected = option.id
                    preview(option.id)
                }
            })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.md)) {
            LinkButton("Hear it", { preview(current?.id) }, icon = "play.circle")
            LinkButton("Get a better voice", { showingHowTo = true }, icon = "arrow.down.circle")
        }
        Hairline()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Crash check-in voice", style = Type.subheadline.medium(), color = Brand.textPrimary)
                Text("Pulse speaks as Corey (Cartesia) when online. “Are you okay?” is pre-recorded in Corey's voice, so the check-in sounds the same offline and locked.",
                    style = Type.caption, color = Brand.textSecondary)
            }
            LinkButton("Hear", {
                voice.stop()
                clip?.release()
                clip = MediaPlayer.create(context, R.raw.checkin_tap_ok)?.also { it.start() }
            }, icon = "play.circle")
        }
        if (voice.options.isNotEmpty() && !voice.hasNaturalVoice) {
            Text("Only a basic voice is installed. A free high-quality voice sounds far more natural and works offline and while locked.",
                style = Type.footnote, color = Brand.amberInk)
        }
    }

    if (showingHowTo) {
        FullScreenSheet(onDismiss = { showingHowTo = false }, title = "A better free voice",
            trailing = BarAction("Done", bold = true) { showingHowTo = false }) {
            ReadableColumn(spacing = Space.md, modifier = Modifier.padding(vertical = Space.md)) {
                Text("Android's best voices are free; the phone just doesn't download them until you ask. Pulse uses the best one you have, automatically.",
                    style = Type.body, color = Brand.textSecondary)
                listOf(
                    "Open Settings → System → Languages → Text-to-speech output (or tap the button below).",
                    "Choose Speech Services by Google as the preferred engine, then tap its settings gear.",
                    "Tap Install voice data → English (United States) and download the voice pack.",
                    "Come back here: the voice shows up in the list, and Pulse switches to it.",
                ).forEachIndexed { i, step ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("${i + 1}", style = Type.headline, color = Brand.blueInk, modifier = Modifier.width(20.dp))
                        Text(step, style = Type.body, color = Brand.textPrimary)
                    }
                }
                Text("High-quality voices are marked Enhanced or Premium here. Each is a small download over Wi-Fi.", style = Type.footnote, color = Brand.textSecondary)
                PillButton("Open text-to-speech settings", {
                    val tts = Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { context.startActivity(tts) }.onFailure {
                        context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                }, height = 50.dp)
            }
        }
    }
}

// Building blocks

@Composable
private fun PageHeader(title: String, subtitle: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Type.largeTitle, color = Brand.textPrimary, modifier = Modifier.semantics { heading() })
        Text(subtitle, style = Type.body, color = Brand.textSecondary)
    }
}

@Composable
private fun SectionTitle(title: String, action: String, icon: String, run: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Space.xs), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Type.title3.semibold(), color = Brand.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
        LinkButton(action, run, icon = icon, modifier = Modifier.semantics { contentDescription = "$action, $title" })
    }
}

@Composable
private fun LockRow(title: String, detail: String, modifier: Modifier = Modifier) {
    Row(modifier.semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(Space.md)) {
        Icon(sf("lock.fill"), null, tint = Brand.textSecondary, modifier = Modifier.width(24.dp).size(18.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.subheadline, color = Brand.textPrimary)
            Text(detail, style = Type.footnote, color = Brand.textSecondary)
        }
    }
}

@Composable
private fun DetailRow(title: String, value: String?, icon: String? = null, trailing: @Composable () -> Unit) {
    Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = Type.subheadline, color = Brand.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (icon != null && value != null) Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.size(18.dp))
                Text(value ?: "Not added", style = Type.title3.copy(fontWeight = if (value == null) FontWeight.Normal else FontWeight.Medium),
                    color = if (value == null) Brand.textSecondary else Brand.textPrimary)
            }
        }
        trailing()
    }
}

@Composable
private fun EmptyRow(text: String, icon: String, onClick: () -> Unit) {
    Row(Modifier.pressable(onClick = onClick).card().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.size(22.dp))
        Text(text, style = Type.body, color = Brand.textSecondary, modifier = Modifier.weight(1f))
        Icon(sf("plus.circle.fill"), null, tint = Brand.blueInk, modifier = Modifier.size(24.dp))
    }
}

/** Vehicle with a scenic thumbnail, "Primary · Sedan" and a chevron. Touch and hold for more options. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun VehicleCard(vehicle: Vehicle, onClick: () -> Unit, onMakePrimary: (() -> Unit)?, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(Radius.card))
            .combinedClickable(onClick = onClick, onLongClick = { menu = true }, onLongClickLabel = "More options")
            .card(Space.sm + 2.dp)
            .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            VehicleThumbnail()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(vehicle.displayName, style = Type.headline, color = Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (vehicle.isPrimary) {
                        Text("Primary", style = Type.subheadline.semibold(), color = Brand.amberInk)
                        Text("·", style = Type.subheadline, color = Brand.textSecondary)
                    }
                    Text(vehicle.type.label, style = Type.subheadline, color = Brand.textSecondary)
                }
            }
            Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(16.dp))
        }
        ChoiceMenu(menu, { menu = false }, listOfNotNull(
            onMakePrimary?.let { MenuItem("Make primary", "star", run = it) },
            MenuItem("Remove", "trash", run = onRemove)))
    }
}

/** Contact with avatar, relationship, number, and message / call buttons. Touch and hold to remove. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FamilyContactCard(contact: FamilyContact, onRemove: () -> Unit) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(Radius.card))
            .combinedClickable(onClick = {}, onLongClick = { menu = true }, onLongClickLabel = "More options")
            .card(),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Initials(contact.name, 56.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(contact.name, style = Type.headline, color = Brand.textPrimary)
                if (contact.relationship.isNotEmpty()) Text(contact.relationship, style = Type.subheadline, color = Brand.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(sf("phone.fill"), null, tint = Brand.blueInk, modifier = Modifier.size(14.dp))
                    Text(PhoneFormat.display(contact.phone), style = Type.subheadline, color = Brand.textPrimary)
                }
            }
            if (PhoneFormat.dialable(contact.phone).isNotEmpty()) {
                Box(Modifier.size(44.dp).clip(CircleShape).pressable { Actions.message(context, contact.phone) }
                    .semantics { contentDescription = "Message ${contact.name}" }, contentAlignment = Alignment.Center) {
                    Icon(sf("message"), null, tint = Brand.blueInk)
                }
                Box(Modifier.size(44.dp).clip(CircleShape).pressable { Actions.call(context, contact.phone) }
                    .semantics { contentDescription = "Call ${contact.name}" }, contentAlignment = Alignment.Center) {
                    Icon(sf("phone.fill"), null, tint = Brand.blueInk)
                }
            }
        }
        ChoiceMenu(menu, { menu = false }, listOf(MenuItem("Remove contact", "trash", run = onRemove)))
    }
}

// Editors

private val bloodTypes = listOf("A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−")

@Composable
private fun MedicalEditorSheet(profile: Profile, update: ((Profile) -> Profile) -> Unit, onDismiss: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    FullScreenSheet(onDismiss = onDismiss, title = "Medical information", trailing = BarAction("Done", bold = true, run = onDismiss)) {
        ReadableColumn(spacing = Space.lg, modifier = Modifier.padding(vertical = Space.lg)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Allergies, conditions, medications", style = Type.subheadline.medium(), color = Brand.textSecondary)
                Box(Modifier.fillMaxWidth().heightIn(min = 96.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(Radius.field))
                    .background(Brand.fieldFill).padding(14.dp)) {
                    if (profile.medicalNotes.isEmpty()) {
                        Text("e.g. Penicillin allergy, asthma, inhaler in glovebox", style = Type.body, color = Brand.textSecondary.copy(alpha = 0.7f))
                    }
                    BasicTextField(profile.medicalNotes, { text -> update { it.copy(medicalNotes = text) } }, minLines = 3, maxLines = 8,
                        textStyle = Type.body.copy(color = Brand.textPrimary), cursorBrush = SolidColor(Brand.blueInk),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Default),
                        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Allergies, conditions, medications" })
                }
                Text("Separate items with commas. Shown to responders on your crash screen.", style = Type.footnote, color = Brand.textSecondary)
            }
            Box {
                Row(Modifier.pressable { menu = true }.card().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Blood type", style = Type.body, color = Brand.textPrimary, modifier = Modifier.weight(1f))
                    Text(profile.bloodType.ifEmpty { "Not set" }, style = Type.body, color = Brand.blueInk)
                    Icon(sf("chevron.up.chevron.down"), null, tint = Brand.blueInk, modifier = Modifier.padding(start = 4.dp).size(14.dp))
                }
                ChoiceMenu(menu, { menu = false }, (listOf("") + bloodTypes).map { type ->
                    MenuItem(type.ifEmpty { "Not set" }) { update { it.copy(bloodType = type) } }
                })
            }
            Spacer(Modifier.heightIn(min = 1.dp))
        }
    }
}

@Composable
private fun InsuranceEditorSheet(profile: Profile, update: ((Profile) -> Profile) -> Unit, onDismiss: () -> Unit) {
    val close = {
        update { it.copy(insurerPhone = PhoneFormat.display(it.insurerPhone)) }
        onDismiss()
    }
    FullScreenSheet(onDismiss = close, title = "Insurance", trailing = BarAction("Done", bold = true, run = close)) {
        ReadableColumn(modifier = Modifier.padding(vertical = Space.lg), horizontalPadding = Space.lg) {
            InsurerPicker(profile) { changed -> update { changed } }
        }
    }
}
