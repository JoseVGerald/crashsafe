package org.cac.crashsafe.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import org.cac.crashsafe.app.AppRouter
import org.cac.crashsafe.features.assistant.AssistantScreen
import org.cac.crashsafe.features.assistant.AssistantViewModel
import org.cac.crashsafe.features.assistant.PulseVoiceScreen
import org.cac.crashsafe.features.assistant.makeAssistantContext
import org.cac.crashsafe.features.carplay.DriveModeScreen
import org.cac.crashsafe.features.checkin.CheckInContainer
import org.cac.crashsafe.features.home.HomeScreen
import org.cac.crashsafe.features.home.HomeViewModel
import org.cac.crashsafe.features.onboarding.OnboardingFlow
import org.cac.crashsafe.features.profile.ProfileScreen
import org.cac.crashsafe.features.trips.TripPlannerScreen
import org.cac.crashsafe.features.trips.TripPlannerViewModel
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.services.driving.BackgroundDriveWatcher
import org.cac.crashsafe.services.driving.DriveCoach
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.sf

/** Shows onboarding until the user's profile is complete, then the main app. */
@Composable
fun SignedInRoot(user: AuthUser) {
    val env = LocalEnvironment.current
    val profile = env.store.profile(user.id)
    LaunchedEffect(user.id) { env.store.ensureProfile(user.id) }
    Crossfade(targetState = profile?.onboardingCompleted, label = "signedIn") { completed ->
        when (completed) {
            null -> Box(Modifier.fillMaxSize().background(Brand.background))
            false -> profile?.let { OnboardingFlow(user, it) }
            true -> MainTabs(user)
        }
    }
}

private data class TabItem(val tab: AppRouter.Tab, val title: String, val icon: String)

private val tabs = listOf(
    TabItem(AppRouter.Tab.home, "Home", "house.fill"),
    TabItem(AppRouter.Tab.trips, "Trips", "map.fill"),
    TabItem(AppRouter.Tab.pulseVoice, "Pulse Voice", "waveform.circle.fill"),
    TabItem(AppRouter.Tab.assistant, "Assistant", "bubble.left.and.bubble.right.fill"),
    TabItem(AppRouter.Tab.profile, "Profile", "person.crop.circle.fill"),
)

/** The signed-in app. */
@Composable
fun MainTabs(user: AuthUser) {
    val env = LocalEnvironment.current
    val router = env.router
    val profile = env.store.profile(user.id)
    // Each tab keeps its state while another is showing, as a tab bar does.
    val saveable = rememberSaveableStateHolder()
    val home = remember { HomeViewModel(env.store, env.crashDetector, env.driving, env.conditions, user.id) }
    val planner = remember { TripPlannerViewModel(user.id, env.scope) }
    val assistant = remember {
        AssistantViewModel(env.assistant, env.voiceInput, env.scope) {
            makeAssistantContext(user, env.store.profile(user.id), null, true)
        }
    }

    BackHandler(enabled = router.selectedTab != AppRouter.Tab.home && router.activeCrash == null && !router.showingCarPlay) {
        router.selectedTab = AppRouter.Tab.home
    }

    Box(Modifier.fillMaxSize().background(Brand.background)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                saveable.SaveableStateProvider(router.selectedTab.name) {
                    when (router.selectedTab) {
                        AppRouter.Tab.home -> HomeScreen(user, home)
                        AppRouter.Tab.trips -> TripPlannerScreen(user.id, planner)
                        AppRouter.Tab.pulseVoice -> PulseVoiceScreen(user, env.pulseCall)
                        AppRouter.Tab.assistant -> AssistantScreen(user, assistant)
                        AppRouter.Tab.profile -> ProfileScreen(user)
                    }
                }
            }
            NavigationBar(containerColor = Brand.surface, tonalElevation = androidx.compose.ui.unit.Dp.Hairline) {
                tabs.forEach { item ->
                    NavigationBarItem(
                        selected = router.selectedTab == item.tab,
                        onClick = { router.selectedTab = item.tab },
                        icon = { Icon(sf(item.icon), contentDescription = null) },
                        label = { Text(item.title, style = Type.caption2, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Brand.blueInk, selectedTextColor = Brand.blueInk,
                            unselectedIconColor = Brand.textSecondary, unselectedTextColor = Brand.textSecondary,
                            indicatorColor = Brand.blueInk.copy(alpha = 0.14f)),
                    )
                }
            }
        }

        AnimatedVisibility(router.showingCarPlay, enter = fadeIn(), exit = fadeOut()) {
            DriveModeScreen(user) { router.showingCarPlay = false }
        }
        AnimatedVisibility(router.activeCrash != null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            router.activeCrash?.let { event -> CheckInContainer(event, user) }
        }
    }

    // Always-on: coach every drive, and start live monitoring + crash detection when a drive is noticed.
    LaunchedEffect(profile?.autoDetectDrives, profile?.carType) {
        env.coach.profileProvider = {
            val current = env.store.profile(user.id)
            val first = current?.sortedContacts?.firstOrNull()
            val lovedOne = first?.let { if (it.relationship.isEmpty()) it.name else "your ${it.relationship.lowercase()}" }
            DriveCoach.ProfileInputs(current?.coachingStyle ?: CoachingStyle.logical, current?.experience ?: DrivingExperience.newDriver, lovedOne)
        }
        env.coach.start()
        // Watch every drive: coaching + crash detection start when activity recognition notices a drive, and the
        // armed state is saved so a background start (no screen) resumes it.
        if (profile?.autoDetectDrives ?: true) {
            env.driveWatcher.arm(BackgroundDriveWatcher.Configuration(user.id, profile?.carType ?: CarType.sedan))
        } else {
            env.driveWatcher.disarm()
        }
    }
    LaunchedEffect(user.id) {
        env.pulseCall.contextProvider = {
            makeAssistantContext(user, env.store.profile(user.id), null, env.connectivity.isOnline, activity = env.intelligence.assistantActivity)
        }
    }
}
