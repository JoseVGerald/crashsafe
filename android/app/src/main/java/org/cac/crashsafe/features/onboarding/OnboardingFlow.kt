package org.cac.crashsafe.features.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.cac.crashsafe.model.AboutYouOption
import org.cac.crashsafe.model.AgeBand
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.model.DrivingFeeling
import org.cac.crashsafe.model.DrivingPurpose
import org.cac.crashsafe.model.PastCrash
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.UsualPassengers
import org.cac.crashsafe.features.profile.ContactEditorSheet
import org.cac.crashsafe.features.profile.ContactRow
import org.cac.crashsafe.features.profile.InsurerPicker
import org.cac.crashsafe.features.profile.VehicleEditorSheet
import org.cac.crashsafe.features.profile.VehicleRow
import org.cac.crashsafe.ui.ActivityResults
import org.cac.crashsafe.ui.LocalActivityResults
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BrandPhoto
import org.cac.crashsafe.ui.components.BrandPhotoView
import org.cac.crashsafe.ui.components.ChoiceTile
import org.cac.crashsafe.ui.components.CircleIconButton
import org.cac.crashsafe.ui.components.EmptyStateCard
import org.cac.crashsafe.ui.components.FormField
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseRings
import org.cac.crashsafe.ui.components.PulseWordmark
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.SafetyNotice
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

private enum class Step {
    welcome, driver, vehicles, health, insurance, family, permissions, done;

    val isOptional: Boolean get() = this in listOf(vehicles, health, insurance, family)
}

/**
 * First-run setup after sign up: about you (which picks the coaching style), vehicles, health, insurance, family,
 * permissions. Pulse watches every drive by default (Profile → Driving changes that).
 */
@Composable
fun OnboardingFlow(user: AuthUser, profile: Profile) {
    val env = LocalEnvironment.current
    var step by remember { mutableStateOf(Step.welcome) }
    var forward by remember { mutableStateOf(true) }
    fun go(delta: Int) {
        val next = Step.entries.getOrNull(step.ordinal + delta) ?: return
        forward = delta > 0
        step = next
    }
    fun update(transform: (Profile) -> Profile) = env.store.updateProfile(user.id, transform)
    BackHandler(enabled = step != Step.welcome) { go(-1) }

    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().imePadding()) {
        if (step != Step.welcome && step != Step.done) Header(step, onBack = { go(-1) }, onSkip = { go(1) })
        Box(Modifier.weight(1f).fillMaxWidth()) {
            AnimatedContent(step, transitionSpec = {
                (slideInHorizontally { if (forward) it else -it } + fadeIn()) togetherWith (slideOutHorizontally { if (forward) -it else it } + fadeOut())
            }, label = "onboarding") { current ->
                when (current) {
                    Step.welcome -> WelcomeStep(user.firstName)
                    Step.driver -> DriverStep(profile, ::update)
                    Step.vehicles -> VehiclesStep(user.id, profile, ::update)
                    Step.health -> HealthStep(profile, ::update)
                    Step.insurance -> StepScaffold("Insurance", "So Pulse can help you report a claim with just the facts — no searching through your glovebox.") {
                        InsurerPicker(profile) { changed -> update { changed } }
                    }
                    Step.family -> FamilyStep(user.id, profile, ::update)
                    Step.permissions -> PermissionsStep(profile)
                    Step.done -> DoneStep(user.firstName, profile)
                }
            }
        }
        // Keeps Continue visible above the keyboard.
        PillButton(when (step) {
            Step.welcome -> "Let's go"
            Step.done -> "Go to Home"
            else -> "Continue"
        }, {
            if (step == Step.done) update { it.copy(onboardingCompleted = true) } else go(1)
        }, modifier = Modifier.padding(horizontal = Space.lg, vertical = Space.sm).navigationBarsPadding())
    }
}

@Composable
private fun Header(step: Step, onBack: () -> Unit, onSkip: () -> Unit) {
    val total = Step.entries.size - 2
    val progress by animateFloatAsState(step.ordinal.toFloat() / total, label = "progress")
    Column(Modifier.padding(horizontal = Space.lg).padding(top = Space.sm), verticalArrangement = Arrangement.spacedBy(Space.md)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircleIconButton("chevron.left", "Back", onBack, background = Brand.fieldFill, border = null)
            Text("Step ${step.ordinal} of $total", style = Type.footnote.semibold(), color = Brand.textSecondary,
                textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            Box(Modifier.size(44.dp, 44.dp), contentAlignment = Alignment.Center) {
                if (step.isOptional) LinkButton("Skip", onSkip, color = Brand.textPrimary)
            }
        }
        Box(Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(Brand.fieldFill)) {
            Box(Modifier.fillMaxWidth(progress).height(6.dp).clip(CircleShape).background(Brand.blue))
        }
    }
}

/** Shared layout for a step: big title, subtitle, scrollable content. */
@Composable
private fun StepScaffold(title: String, subtitle: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg, modifier = Modifier.padding(vertical = Space.lg)) {
            Column(Modifier.fadeUp(), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                Text(title, style = Type.largeTitle.bold(), color = Brand.textPrimary)
                Text(subtitle, style = Type.body, color = Brand.textSecondary)
            }
            Column(Modifier.fadeUp(0.08), verticalArrangement = Arrangement.spacedBy(Space.lg), content = content)
        }
    }
}

@Composable
private fun WelcomeStep(name: String) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg) {
            PulseWordmark(Modifier.padding(top = Space.md).fadeUp())
            BrandPhotoView(BrandPhoto.roadHero, Modifier.fillMaxWidth().height(230.dp).clip(RoundedCornerShape(Radius.card))
                .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card)).fadeUp(0.05))
            Column(Modifier.fadeUp(0.1), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                Text(if (name.isEmpty()) "Welcome" else "Welcome, $name", style = Type.largeTitle, color = Brand.textPrimary)
                Text("A few quick questions to set up your safety profile. It takes about two minutes, and everything stays on this phone.",
                    style = Type.body, color = Brand.textSecondary)
            }
        }
    }
}

/**
 * About you: a few questions Pulse actually uses (who may be in the car after a crash, how to steady you,
 * what to explain first). Together they pick the coaching style quietly (Profile shows and changes it).
 */
@Composable
private fun DriverStep(profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    /** Re-picks the style whenever an answer changes. */
    fun answer(transform: (Profile) -> Profile) = update { p -> transform(p).let { it.copy(coachingStyle = it.recommendedCoaching.first) } }
    LaunchedEffect(Unit) { answer { it } }
    StepScaffold("A bit about you", "Pulse uses these to coach you the way that works for you, and to know who might need help after a crash.") {
        Question("How long have you been driving?") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DrivingExperience.entries.forEach { option ->
                    ChoiceTile(option.label, experienceIcon(option), profile.experience == option, Modifier.weight(1f)) { answer { it.copy(experience = option) } }
                }
            }
        }
        Question("How old are you?") {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                AgeBand.entries.forEach { option ->
                    ChoiceTile(option.label, "person.fill", profile.ageBand == option, Modifier.weight(1f)) { answer { it.copy(ageBand = option) } }
                }
            }
        }
        Question("What do you drive for most?") {
            DrivingPurpose.entries.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { option ->
                        ChoiceTile(option.label, option.systemImage, profile.drivingPurpose == option, Modifier.weight(1f)) { answer { it.copy(drivingPurpose = option) } }
                    }
                }
            }
        }
        Question("Who usually rides with you?") {
            Choices(UsualPassengers.entries, profile.passengers) { option -> answer { it.copy(passengers = option) } }
        }
        Question("How do you feel about driving?") {
            Choices(DrivingFeeling.entries, profile.drivingFeeling) { option -> answer { it.copy(drivingFeeling = option) } }
        }
        Question("Have you been in a crash before?") {
            Choices(PastCrash.entries, profile.pastCrash) { option -> answer { it.copy(pastCrash = option) } }
        }
    }
}

@Composable
private fun Question(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = Type.headline, color = Brand.textPrimary)
        content()
    }
}

@Composable
private fun <T : AboutYouOption> Choices(options: List<T>, selected: T?, set: (T) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { option -> ChoiceTile(option.label, option.systemImage, selected == option, Modifier.weight(1f)) { set(option) } }
    }
}

private fun experienceIcon(experience: DrivingExperience) = when (experience) {
    DrivingExperience.learner -> "graduationcap.fill"
    DrivingExperience.newDriver -> "leaf.fill"
    DrivingExperience.experienced -> "car.fill"
    DrivingExperience.veteran -> "star.fill"
}

@Composable
private fun VehiclesStep(ownerID: String, profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    StepScaffold("Your vehicles", "Add every car you drive. The type tunes crash detection, and tow drivers need the details.") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (profile.vehicles.isEmpty()) {
                EmptyStateCard("car.side.fill", "No vehicles yet", "Add your car, and any others you drive — like a parent's SUV.")
            }
            profile.sortedVehicles.forEach { vehicle ->
                Box(Modifier.card()) {
                    VehicleRow(vehicle, onMakePrimary = { update { it.makingPrimary(vehicle.id) } }, onDelete = { update { it.removingVehicle(vehicle.id) } })
                }
            }
            PillButton(if (profile.vehicles.isEmpty()) "Add a vehicle" else "Add another vehicle", { editing = true }, kind = PillKind.secondary, icon = "plus")
        }
    }
    if (editing) VehicleEditorSheet(ownerID) { editing = false }
}

private val bloodTypes = listOf("A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−")

@Composable
private fun HealthStep(profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    StepScaffold("Medical info", "Shown to responders on your crash screen. Apps can't read your phone's emergency information, so add anything important here.") {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Allergies, conditions, medications", style = Type.subheadline.medium(), color = Brand.textSecondary)
            FormField("", profile.medicalNotes, { notes -> update { it.copy(medicalNotes = notes) } },
                placeholder = "e.g. Allergic to penicillin. Asthma — inhaler in glovebox.", singleLine = false, minLines = 4)
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Blood type", style = Type.subheadline.medium(), color = Brand.textSecondary)
            bloodTypes.chunked(4).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { type ->
                        val selected = profile.bloodType == type
                        Box(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(Radius.small))
                            .background(if (selected) Brand.red else Brand.fieldFill)
                            .pressable { update { it.copy(bloodType = if (selected) "" else type) } },
                            contentAlignment = Alignment.Center) {
                            Text(type, style = Type.headline, color = if (selected) Color.White else Brand.textPrimary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FamilyStep(ownerID: String, profile: Profile, update: ((Profile) -> Profile) -> Unit) {
    val results = LocalActivityResults.current
    val scope = rememberCoroutineScope()
    var adding by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<ActivityResults.PickedContact?>(null) }
    StepScaffold("Who should we alert?", "If you don't respond after a crash, these people get your location right away.") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (profile.familyContacts.isEmpty()) {
                EmptyStateCard("person.2.fill", "No one added yet", "Parents, a partner, a close friend — whoever should know first.", tint = Brand.teal)
            }
            profile.sortedContacts.forEach { contact ->
                Box(Modifier.card()) {
                    ContactRow(contact) { update { p -> p.copy(familyContacts = p.familyContacts.filter { it.id != contact.id }) } }
                }
            }
            // Opens the phone's contacts; the pick lands in the editor so a relationship can be added.
            PillButton(if (profile.familyContacts.isEmpty()) "Add a contact" else "Add another contact", {
                if (results == null) adding = true else scope.launch { results.pickContact()?.let { picked = it } }
            }, icon = "person.crop.circle.badge.plus")
            LinkButton("Type it in instead", { adding = true }, modifier = Modifier.align(Alignment.CenterHorizontally))
        }
    }
    if (adding) ContactEditorSheet(ownerID) { adding = false }
    picked?.let { contact -> ContactEditorSheet(ownerID, prefill = contact) { picked = null } }
}

@Composable
private fun PermissionsStep(profile: Profile) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val permissions = env.permissions
    @Suppress("UNUSED_VARIABLE") val version = permissions.version
    StepScaffold("Allow a few things", "Android asks you directly. These let CrashSafe notice a crash and send help to the right place.") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PermissionRow("location.fill", Brand.blue, "Location", "Find help near you and share where you are.",
                env.location.isAuthorized, if (env.location.isDenied) "Settings" else "Allow") {
                if (env.location.isDenied) permissions.openSettings() else env.location.requestPermission()
            }
            AnimatedVisibility(profile.autoDetectDrives) {
                PermissionRow("location.circle.fill", Brand.teal, "Allow all the time",
                    "So Pulse can notice drives that start while CrashSafe is closed. Android asks for this separately.",
                    env.location.hasAlwaysAccess, if (env.location.canPromptForAlways) "Allow" else "Settings") {
                    if (!env.location.requestAlwaysPermission() && !env.location.hasAlwaysAccess) permissions.openSettings()
                }
            }
            PermissionRow("figure.walk.motion", Brand.green, "Physical activity", "Notice when a drive starts, and detect hard stops.",
                permissions.motionGranted, if (permissions.motionDenied) "Settings" else "Allow") {
                scope.launch { permissions.requestMotion() }
            }
            PermissionRow("bell.badge.fill", Brand.red, "Notifications", "Check on you if a crash is detected.",
                permissions.notificationsGranted, if (permissions.notificationsDenied) "Settings" else "Allow") {
                scope.launch { permissions.requestNotifications() }
            }
            Text("Changed your mind? You can update these anytime in Profile → Driving or in Settings.", style = Type.footnote, color = Brand.textSecondary)
            SafetyNotice(Modifier.padding(top = Space.sm))
        }
    }
}

@Composable
private fun PermissionRow(icon: String, tint: Color, title: String, detail: String, granted: Boolean, actionTitle: String, request: () -> Unit) {
    Row(Modifier.card(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        IconBadge(icon, tint, 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.headline, color = Brand.textPrimary)
            Text(detail, style = Type.subheadline, color = Brand.textSecondary)
        }
        if (granted) {
            Icon(sf("checkmark.circle.fill"), "Allowed", tint = Brand.greenInk, modifier = Modifier.size(28.dp))
        } else {
            Box(Modifier.heightIn(min = 36.dp).clip(CircleShape).background(Brand.blue).pressable(onClick = request).padding(horizontal = 16.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center) {
                Text(actionTitle, style = Type.subheadline.semibold(), color = Color.White)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DoneStep(name: String, profile: Profile) {
    val pop = remember { Animatable(0.4f) }
    LaunchedEffect(Unit) { pop.animateTo(1f, spring(dampingRatio = 0.55f, stiffness = 200f)) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Space.lg),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.lg, Alignment.CenterVertically)) {
        Spacer(Modifier.height(Space.xl))
        Box(Modifier.size(220.dp), contentAlignment = Alignment.Center) {
            PulseRings(Brand.green, modifier = Modifier.size(130.dp))
            Box(Modifier.size(124.dp).graphicsLayer { scaleX = pop.value; scaleY = pop.value }.clip(CircleShape).background(Brand.green),
                contentAlignment = Alignment.Center) {
                Icon(sf("checkmark"), null, tint = Color.White, modifier = Modifier.size(56.dp))
            }
        }
        Column(Modifier.fadeUp(0.15), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.sm)) {
            Text("You're all set, $name", style = Type.largeTitle.bold(), color = Brand.textPrimary, textAlign = TextAlign.Center)
            Text("Pulse will watch out for you on every drive.", style = Type.body, color = Brand.textSecondary, textAlign = TextAlign.Center)
        }
        FlowRow(Modifier.fadeUp(0.25), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusChip("${profile.vehicles.size} vehicle${if (profile.vehicles.size == 1) "" else "s"}", "car.fill")
            StatusChip("${profile.familyContacts.size} contact${if (profile.familyContacts.size == 1) "" else "s"}", "person.2.fill", Brand.greenInk)
            StatusChip(if (profile.autoDetectDrives) "Every drive" else "Manual start", if (profile.autoDetectDrives) "steeringwheel" else "hand.tap.fill", Brand.amberInk)
            StatusChip(if (profile.coachingStyle == CoachingStyle.logical) "Facts" else "Heart", profile.coachingStyle.systemImage,
                if (profile.coachingStyle == CoachingStyle.logical) Brand.blueInk else Brand.redInk)
        }
        Spacer(Modifier.height(Space.xl))
    }
}
