package org.cac.crashsafe.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.pulse.AssistantService
import org.cac.crashsafe.core.pulse.MockAssistantService
import org.cac.crashsafe.core.pulse.PulseKnowledgeIndex
import org.cac.crashsafe.core.pulse.PulseTeamAgent
import org.cac.crashsafe.core.roads.RoadDefaults
import org.cac.crashsafe.data.AppStore
import org.cac.crashsafe.features.assistant.PulseCallViewModel
import org.cac.crashsafe.features.assistant.makeAssistantContext
import org.cac.crashsafe.features.checkin.CrashResponseCenter
import org.cac.crashsafe.features.sensorlab.SensorLabModel
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.model.CheckInRecord
import org.cac.crashsafe.model.CrashSnapshot
import org.cac.crashsafe.services.alerts.AlertRecipient
import org.cac.crashsafe.services.alerts.BackendEmergencyAlertService
import org.cac.crashsafe.services.alerts.CrashAlarm
import org.cac.crashsafe.services.alerts.CrashNotifying
import org.cac.crashsafe.services.alerts.EmergencyAlertService
import org.cac.crashsafe.services.alerts.EmergencyDialer
import org.cac.crashsafe.services.alerts.LocalCrashNotifier
import org.cac.crashsafe.services.alerts.MockEmergencyAlertService
import org.cac.crashsafe.services.alerts.NoCrashNotifier
import org.cac.crashsafe.services.alerts.NoEmergencyDialer
import org.cac.crashsafe.services.alerts.SilentCrashAlarm
import org.cac.crashsafe.services.alerts.SpeakerCrashAlarm
import org.cac.crashsafe.services.alerts.SystemEmergencyDialer
import org.cac.crashsafe.services.assistant.DirectPulseService
import org.cac.crashsafe.services.assistant.MockVoiceInputService
import org.cac.crashsafe.services.assistant.PulseSpeaker
import org.cac.crashsafe.services.assistant.PulseVoice
import org.cac.crashsafe.services.assistant.SpeechVoiceInput
import org.cac.crashsafe.services.assistant.VoiceInputService
import org.cac.crashsafe.services.auth.AuthService
import org.cac.crashsafe.services.auth.MockAuthService
import org.cac.crashsafe.services.connectivity.ConnectivityMonitor
import org.cac.crashsafe.services.crash.CrashDetector
import org.cac.crashsafe.services.crash.LiveCrashDetector
import org.cac.crashsafe.services.crash.MockCrashDetector
import org.cac.crashsafe.services.driving.BackgroundDriveWatcher
import org.cac.crashsafe.services.driving.DriveAutoDetector
import org.cac.crashsafe.services.driving.DriveCoach
import org.cac.crashsafe.services.driving.DriveMonitorService
import org.cac.crashsafe.services.driving.DrivingMonitor
import org.cac.crashsafe.services.driving.RoadAreaStore
import org.cac.crashsafe.services.driving.SpeedLimitService
import org.cac.crashsafe.services.intelligence.MotionIntelligence
import org.cac.crashsafe.services.location.LocationService
import org.cac.crashsafe.services.sensors.AndroidMotionSource
import org.cac.crashsafe.services.sensors.BackgroundSensorLog
import org.cac.crashsafe.services.sensors.MotionSource
import org.cac.crashsafe.services.sensors.ReplayMotionSource
import org.cac.crashsafe.services.sensors.SensorHub
import org.cac.crashsafe.services.trips.MockTripPackService
import org.cac.crashsafe.services.trips.OsmTripPackService
import org.cac.crashsafe.services.trips.TripPackService
import org.cac.crashsafe.services.weather.ConditionsStore
import org.cac.crashsafe.services.weather.MockWeatherService
import org.cac.crashsafe.services.weather.OpenMeteoWeatherService
import org.cac.crashsafe.services.weather.WeatherService
import java.io.File

/** Holds every service the app uses. Swap mocks for real implementations here (`live()`). */
class AppEnvironment(
    val context: Context,
    auth: AuthService,
    crashDetector: CrashDetector?,
    assistant: (PulseTeamAgent, () -> PulseKnowledgeIndex) -> AssistantService,
    voiceInput: (PermissionCenter) -> VoiceInputService,
    val tripPacks: TripPackService,
    alerts: (AppEnvironment) -> EmergencyAlertService,
    weather: WeatherService,
    notifier: (Context) -> CrashNotifying,
    alarm: (Context, PulseVoice, CoroutineScope) -> CrashAlarm,
    dialer: (Context) -> EmergencyDialer,
    useSpeedLimits: Boolean,
    motion: MotionSource? = null,
    persist: Boolean = true,
) {
    /** The app's main-thread scope: services and screens run here, as on iOS's main actor. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val prefs = context.getSharedPreferences("crashsafe", Context.MODE_PRIVATE)
    val store = AppStore(if (persist) File(context.filesDir, "store.json") else null, scope)
    val session = SessionStore(auth)
    val router = AppRouter()
    val permissions = PermissionCenter(context, prefs)
    val connectivity = ConnectivityMonitor(context)
    val location = LocationService(context, permissions, scope)
    val conditions = ConditionsStore(weather)
    val voice = PulseVoice(context, prefs)
    /** Real sensors, with clips replayable in their place (the emulator has no real motion). */
    val replay: ReplayMotionSource? = if (motion == null) ReplayMotionSource(AndroidMotionSource(context), scope) else null
    val sensors = SensorHub(motion ?: replay!!, location, scope,
        logStore = if (persist) BackgroundSensorLog.Store(File(context.filesDir, "background-sensor-log.json")) else null)
    val roadAreas = if (persist) RoadAreaStore(File(context.cacheDir, "road-areas")) else null
    val speedLimits: SpeedLimitService? = if (useSpeedLimits) SpeedLimitService(scope, store = roadAreas,
        defaults = runCatching { RoadDefaults.fromJson(context.assets.open("roads/default_speeds.json").bufferedReader().readText()) }.getOrNull())
    else null
    val sensorLab = SensorLabModel(context, sensors, replay, speedLimits)
    val driving = DrivingMonitor(sensors, scope, speedLimits)
    /** Pulse's voice: Corey (Cartesia) when online, the best installed voice offline. */
    val speaker = PulseSpeaker(context, voice, scope, isOnline = { connectivity.isOnline })
    val coach = DriveCoach(driving, conditions, speaker, scope)
    /** Rolling sensor history → transport mode, harsh events, impact reports (for Pulse and the crash flow). */
    val intelligence = MotionIntelligence(sensors)
    val crashDetector: CrashDetector = crashDetector ?: LiveCrashDetector(sensors, scope, ignoreReadings = { sensorLab.suppressesCrashDetection })
    /** The team's Pulse agent prompt and knowledge, from `assets/pulse/`. */
    val pulseAgent = PulseTeamAgent(asset("pulse/pulse_core.txt") ?: "", asset("pulse/pulse_core_mini.txt") ?: "", asset("pulse/pulse_turn.json"))
    private val knowledge by lazy { PulseKnowledgeIndex(asset("pulse/pulse_knowledge.json")) }
    val assistant: AssistantService = assistant(pulseAgent) { knowledge }
    val voiceInput: VoiceInputService = voiceInput(permissions)
    val alerts: EmergencyAlertService = alerts(this)
    val autoDetector = DriveAutoDetector(context)
    /** Persistent Pulse voice call state shared across Home and the Pulse Voice tab. */
    val pulseCall = PulseCallViewModel(this.assistant, this.voiceInput, speaker, scope) {
        val user = session.user ?: AuthUser("driver", "Driver", "driver@example.com")
        makeAssistantContext(user, store.profile(user.id), null, connectivity.isOnline, activity = intelligence.assistantActivity)
    }
    /** Runs the crash check-in whether or not a screen is showing. */
    val crashCenter = CrashResponseCenter(this.alerts, notifier(context), { connectivity.isOnline }, scope,
        alarm(context, voice, scope), dialer(context))
    /** "Watch every drive": starts coaching + crash detection when a drive is noticed, even after a restart. */
    val driveWatcher = BackgroundDriveWatcher(driving, this.crashDetector, location, autoDetector, prefs)

    init {
        location.backgroundUpdates = { on -> DriveMonitorService.setRunning(context, on) }
        replay?.onFinish = { sensors.motionSourceChanged() }
        speedLimits?.regionCode = { location.regionCode }
        intelligence.start()
        router.onCrashClosed = { crashCenter.dismiss() }
        scope.launch { roadAreas?.preload() }

        // The crash check-in reads contacts and saves its outcome straight from the store, not from a screen.
        crashCenter.recipientsProvider = { ownerID ->
            store.profile(ownerID)?.sortedContacts?.map { AlertRecipient(it.name, it.phone) } ?: emptyList()
        }
        crashCenter.recordOutcome = { ownerID, event, outcome -> recordOutcome(ownerID, event, outcome) }
        crashCenter.keepAlive = { _ ->
            // A drive already holds the foreground service; otherwise hold one for the countdown and alert.
            val started = !sensors.isRunning
            if (started) DriveMonitorService.setRunning(context, true)
            val release: () -> Unit = { if (started && !sensors.isRunning) DriveMonitorService.setRunning(context, false) }
            release
        }

        // One listener for the app's lifetime. Starts the check-in at once and shows it when the app is on screen.
        scope.launch { this@AppEnvironment.crashDetector.events.collect { handleCrash(it) } }
        driveWatcher.resumeIfArmed()
    }

    fun handleCrash(incoming: CrashEvent) {
        val ownerID = session.user?.id ?: driveWatcher.configuration?.ownerID ?: return
        if (crashCenter.isCounting) return
        val event = if (incoming.impact == null) incoming.copy(impact = intelligence.impactReport(incoming)) else incoming
        crashCenter.begin(event, ownerID)
        router.showCrash(event)
        router.assistantIncident = router.assistantIncident?.copy(behaviorEvents = intelligence.behaviorEvents(event.date))
    }

    /** Where and in what conditions, for the impact report (kept on this phone only). */
    private fun recordOutcome(ownerID: String, event: CrashEvent, outcome: CheckInOutcome) {
        val here = location.location
        val weather = conditions.weather?.let { w ->
            listOfNotNull(w.condition.label, "${Math.round(w.temperatureF)}°F",
                w.visibilityMiles?.let { "visibility ${Math.round(it)} mi" }, if (w.isDay) "daylight" else "dark").joinToString(", ")
        }
        val snapshot = CrashSnapshot(date = event.date, peakG = event.peakG, speedDropMPH = event.speedDropMPH, impact = event.impact,
            latitude = here?.latitude, longitude = here?.longitude, accuracyMeters = here?.horizontalAccuracy?.takeIf { it >= 0 },
            street = location.streetName, place = location.placeName, weather = weather, isSimulated = event.isSimulated)
        store.insertCheckIn(CheckInRecord(ownerID = ownerID, outcome = outcome, wasSimulated = event.isSimulated,
            date = event.date, snapshot = snapshot))
    }

    private fun asset(path: String): String? = runCatching { context.assets.open(path).bufferedReader().readText() }.getOrNull()

    companion object {
        /** The configuration the app ships with. */
        fun live(context: Context): AppEnvironment {
            val prefs = context.getSharedPreferences("crashsafe", Context.MODE_PRIVATE)
            return AppEnvironment(
                context = context,
                auth = MockAuthService(prefs),                                   // Offline accounts (swap for Firebase)
                crashDetector = null,                                             // Live shared sensors + experimental evidence rules
                assistant = { agent, knowledge -> DirectPulseService.configured(agent, knowledge) }, // OpenRouter from the phone; backend / guides fallback
                voiceInput = { permissions -> SpeechVoiceInput(context, permissions) }, // Android speech recognition, on-device when possible
                tripPacks = OsmTripPackService(),                                 // OpenStreetMap search (mock fallback without coordinates)
                alerts = { env ->                                                 // Texts + automated calls via /v1/alerts
                    BackendEmergencyAlertService.configured(
                        driverName = { env.session.user?.name ?: "" },
                        location = { env.location.location?.let { it.latitude to it.longitude } })
                },
                weather = OpenMeteoWeatherService(),                              // Open-Meteo (Apple Weather has no Android API)
                notifier = { LocalCrashNotifier(it) },
                alarm = { ctx, voice, scope -> SpeakerCrashAlarm(ctx, voice, scope) }, // "Are you okay?" prompts + siren
                dialer = { SystemEmergencyDialer(it) },                          // Dialer with 911 filled in
                useSpeedLimits = true,                                            // TomTom / OpenStreetMap limits
            )
        }

        /** Mock services for previews and screenshot tests (no network, sensors or audio). */
        fun preview(context: Context): AppEnvironment = AppEnvironment(
            context = context,
            auth = MockAuthService(context.getSharedPreferences("preview", Context.MODE_PRIVATE), latencyMillis = 300),
            crashDetector = MockCrashDetector(),
            assistant = { _, _ -> MockAssistantService(latencyMillis = 300) },
            voiceInput = { MockVoiceInputService() },
            tripPacks = MockTripPackService(),
            alerts = { MockEmergencyAlertService() },
            weather = MockWeatherService(),
            notifier = { NoCrashNotifier() },
            alarm = { _, _, _ -> SilentCrashAlarm() },
            dialer = { NoEmergencyDialer() },
            useSpeedLimits = false,
            persist = false,
        )
    }
}
