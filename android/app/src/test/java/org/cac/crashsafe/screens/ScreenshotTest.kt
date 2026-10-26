package org.cac.crashsafe.screens

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onRoot
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import org.cac.crashsafe.app.AppEnvironment
import org.cac.crashsafe.app.AppRouter
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.ImpactAnalyzer
import org.cac.crashsafe.core.crash.SensorScenario
import org.cac.crashsafe.core.driving.DriveScenario
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.features.assistant.PulseCallScreen
import org.cac.crashsafe.features.carplay.DriveModeScreen
import org.cac.crashsafe.features.checkin.CheckInContainer
import org.cac.crashsafe.features.launch.SplashScreen
import org.cac.crashsafe.features.onboarding.OnboardingFlow
import org.cac.crashsafe.features.recovery.ImpactReportSheet
import org.cac.crashsafe.features.recovery.RecoveryScreen
import org.cac.crashsafe.features.auth.AuthFlow
import org.cac.crashsafe.features.sensorlab.SensorLabModel
import org.cac.crashsafe.features.sensorlab.SensorLabScreen
import org.cac.crashsafe.model.AppData
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.CheckInRecord
import org.cac.crashsafe.model.CrashSnapshot
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.model.FamilyContact
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Trip
import org.cac.crashsafe.model.TripPackStatus
import org.cac.crashsafe.model.Vehicle
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.MainTabs
import org.cac.crashsafe.ui.theme.CrashSafeTheme
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper

/** A bare application, so tests don't start the live sensors, location and network services. */
class ScreenshotApp : Application()

/**
 * Renders every screen on the JVM (Robolectric's native graphics) and saves PNGs to
 * `app/build/outputs/roborazzi/` — how the UI was checked without an emulator.
 * Uses the preview environment: mock auth, assistant, weather, alerts; no network.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], application = ScreenshotApp::class, qualifiers = "w411dp-h891dp-xhdpi")
class ScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var env: AppEnvironment
    private val user = AuthUser("driver-1", "Jordan Lee", "jordan.lee@example.com")

    @Before
    fun setUp() {
        env = AppEnvironment.preview(ApplicationProvider.getApplicationContext())
        val now = nowSeconds()
        val profile = Profile(
            ownerID = user.id,
            medicalNotes = "Penicillin allergy. Asthma, inhaler in glovebox",
            bloodType = "O+",
            insurer = "State Farm",
            policyNumber = "SF-2231-8840",
            insurerPhone = "8007325246",
            experience = DrivingExperience.newDriver,
            onboardingCompleted = true,
            autoDetectDrives = false,
            vehicles = listOf(
                Vehicle(make = "Subaru", model = "Outback", year = 2021, type = CarType.suv, colorName = "Blue", isPrimary = true, createdAt = now - 100),
                Vehicle(make = "Honda", model = "Civic", year = 2016, type = CarType.sedan, createdAt = now - 50)),
            familyContacts = listOf(
                FamilyContact(name = "Maria Lee", phone = "(503) 555-0142", relationship = "Mom", createdAt = now - 90),
                FamilyContact(name = "Sam Ortiz", phone = "(971) 555-0177", relationship = "Partner", createdAt = now - 80)),
        )
        val trip = Trip(ownerID = user.id, origin = "Portland, OR", destination = "Bend, OR", startDate = now + 86_400 * 3,
            endDate = now + 86_400 * 5, tripPackStatus = TripPackStatus.ready, tripPackUpdatedAt = now - 3600,
            tripPackSummary = "3 hospitals, 2 police stations, 4 tow services along the route")
        env.store.update { AppData(profiles = listOf(profile), trips = listOf(trip)) }
        env.session.forceSignIn(user)
    }

    private fun shot(name: String, settleMillis: Long = 2500, dialog: Boolean = false, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            CompositionLocalProvider(LocalEnvironment provides env) {
                CrashSafeTheme { content() }
            }
        }
        // Let entrance animations and main-thread work (timers, mock services) finish.
        repeat((settleMillis / 100).toInt()) {
            compose.mainClock.advanceTimeBy(100)
            ShadowLooper.idleMainLooper(100, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
        // A full-screen sheet is its own window: capture that one.
        val root = if (dialog) compose.onAllNodes(isRoot()).onLast() else compose.onRoot()
        root.captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    @Test fun splash() = shot("01_splash") { SplashScreen() }

    @Test fun signIn() {
        env.session.signOut()
        shot("02_auth") { AuthFlow() }
    }

    @Test fun onboarding() {
        val fresh = Profile(ownerID = user.id)
        env.store.update { AppData(profiles = listOf(fresh)) }
        shot("03_onboarding") { OnboardingFlow(user, fresh) }
    }

    @Test fun home() = shot("04_home") { MainTabs(user) }

    @Config(qualifiers = "w411dp-h1800dp-xhdpi")
    @Test fun homeFull() = shot("04b_home_full") { MainTabs(user) }

    @Test fun trips() {
        env.router.selectedTab = AppRouter.Tab.trips
        shot("05_trips") { MainTabs(user) }
    }

    @Test fun pulseVoice() {
        env.router.selectedTab = AppRouter.Tab.pulseVoice
        shot("06_pulse_voice") { MainTabs(user) }
    }

    @Test fun pulseCall() {
        env.pulseCall.startCall()
        shot("07_pulse_call") { PulseCallScreen(env.pulseCall) }
    }

    @Test fun assistant() {
        env.router.selectedTab = AppRouter.Tab.assistant
        shot("08_assistant") { MainTabs(user) }
    }

    @Config(qualifiers = "w411dp-h3600dp-xhdpi")
    @Test fun profile() {
        env.router.selectedTab = AppRouter.Tab.profile
        shot("09_profile_full") { MainTabs(user) }
    }

    @Test fun driveMode() {
        env.driving.startDemo(DriveScenario.highwayRain)
        env.conditions.override(DriveScenario.highwayRain.weather)
        shot("10_drive_mode", settleMillis = 6000) { DriveModeScreen(user) {} }
        env.driving.stop()
    }

    @Config(qualifiers = "w891dp-h411dp-xhdpi")
    @Test fun driveModeLandscape() {
        env.driving.startDemo(DriveScenario.forestNight)
        env.conditions.override(DriveScenario.forestNight.weather)
        shot("10b_drive_mode_landscape", settleMillis = 6000) { DriveModeScreen(user) {} }
        env.driving.stop()
    }

    @Test fun checkIn() {
        val event = CrashEvent(date = nowSeconds(), peakG = 7.4, speedDropMPH = 31.0, isSimulated = true,
            impact = ImpactAnalyzer.simulatedReport())
        env.handleCrash(event)
        shot("11_check_in") { CheckInContainer(event, user) }
    }

    @Test fun recovery() = shot("12_recovery") { RecoveryScreen(user, CheckInOutcome.ok) {} }

    @Config(qualifiers = "w411dp-h2000dp-xhdpi")
    @Test fun impactReport() {
        val record = CheckInRecord(ownerID = user.id, outcome = CheckInOutcome.ok, wasSimulated = true, date = nowSeconds() - 600,
            snapshot = CrashSnapshot(date = nowSeconds() - 600, peakG = 7.4, speedDropMPH = 31.0, impact = ImpactAnalyzer.simulatedReport(),
                latitude = 45.5152, longitude = -122.6784, accuracyMeters = 6.0, street = "SW Broadway", place = "Portland, OR",
                weather = "Light rain, 52°F, daylight", isSimulated = true))
        env.store.insertCheckIn(record)
        shot("13_impact_report", dialog = true) { ImpactReportSheet(record.id, user) {} }
    }

    @Config(qualifiers = "w411dp-h3200dp-xhdpi")
    @Test fun sensorLab() {
        env.sensorLab.play(SensorLabModel.Source.Generated(SensorScenario.Kind.frontalCrash))
        shot("14_sensor_lab_full", settleMillis = 14000) { SensorLabScreen {} }
        env.sensorLab.stop()
    }
}
