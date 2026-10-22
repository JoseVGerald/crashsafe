import CoreMotion
import Foundation
import Observation
import UIKit
import UserNotifications

/// Holds every service the app uses. Swap mocks for real implementations here.
@Observable
final class AppEnvironment {
    let session: SessionStore
    let router: AppRouter
    let connectivity: ConnectivityMonitor
    let location: LocationService
    let sensors: SensorHub
    let conditions: ConditionsStore
    let driving: DrivingMonitor
    let coach: DriveCoach
    /// Rolling sensor history → transport mode, harsh events, impact reports (for Pulse and the crash flow).
    let intelligence: MotionIntelligence
    /// Profile → Testing → Sensor lab (live readings, recordings, replays).
    let sensorLab: SensorLabModel
    let autoDetector = DriveAutoDetector()
    let permissions = PermissionCenter()
    @ObservationIgnored let crashDetector: any CrashDetector
    @ObservationIgnored let assistant: any AssistantService
    @ObservationIgnored let voiceInput: any VoiceInputService
    @ObservationIgnored let tripPacks: any TripPackService
    @ObservationIgnored let alerts: any EmergencyAlertService
    /// Runs the crash check-in whether or not a screen is showing.
    let crashCenter: CrashResponseCenter
    /// "Watch every drive": starts coaching + crash detection when a drive is noticed, even after a relaunch.
    let driveWatcher: BackgroundDriveWatcher
    @ObservationIgnored let notificationDelegate: CrashNotificationDelegate
    @ObservationIgnored private var crashListener: Task<Void, Never>?

    init(auth: any AuthService,
         crashDetector: (any CrashDetector)?,
         assistant: any AssistantService,
         voiceInput: any VoiceInputService,
         tripPacks: any TripPackService,
         alerts: any EmergencyAlertService,
         weather: any WeatherService,
         connectivity: ConnectivityMonitor,
         location: LocationService = LocationService(),
         notifier: any CrashNotifying = LocalCrashNotifier(),
         speedLimits: SpeedLimitService? = nil,
         motion: (any MotionSource)? = nil,
         alarm: any CrashAlarm = SilentCrashAlarm(),
         dialer: any EmergencyDialer = NoEmergencyDialer(),
         defaults: UserDefaults = .standard) {
        self.session = SessionStore(auth: auth)
        self.router = AppRouter()
        self.connectivity = connectivity
        self.location = location
        let conditions = ConditionsStore(service: weather)
        // Real Core Motion, with clips replayable in its place (the simulator has no motion sensor).
        let replay = motion == nil ? ReplayMotionSource() : nil
        let sensors = SensorHub(motion: motion ?? replay!, location: location, persistsBackgroundLog: true)
        self.sensors = sensors
        replay?.onFinish = { [weak sensors] in sensors?.motionSourceChanged() }
        self.sensorLab = SensorLabModel(sensors: sensors, replay: replay, speedLimits: speedLimits)
        let driving = DrivingMonitor(sensors: sensors, speedLimits: speedLimits)
        self.conditions = conditions
        self.driving = driving
        self.coach = DriveCoach(driving: driving, conditions: conditions)
        let intelligence = MotionIntelligence(sensors: sensors)
        self.intelligence = intelligence
        intelligence.start()
        let lab = sensorLab
        let detector = crashDetector ?? CoreMotionCrashDetector(sensors: sensors,
                                                                ignoreReadings: { [weak lab] in lab?.suppressesCrashDetection ?? false })
        self.crashDetector = detector
        self.assistant = assistant
        self.voiceInput = voiceInput
        self.tripPacks = tripPacks
        self.alerts = alerts
        let crashCenter = CrashResponseCenter(alerts: alerts, notifier: notifier, isOnline: { connectivity.isOnline },
                                              alarm: alarm, dialer: dialer)
        self.crashCenter = crashCenter
        self.driveWatcher = BackgroundDriveWatcher(driving: driving, crashDetector: detector, wakeups: location,
                                                   autoDetector: autoDetector, defaults: defaults)
        self.notificationDelegate = CrashNotificationDelegate(
            onResponse: { outcome in
                // Lock-screen answer goes straight to the running countdown; a plain tap just opens the app.
                if let outcome { crashCenter.respond(outcome) }
            },
            // iOS's live state, not our tracker: while the screen is locking with the app in front, the
            // background notification hasn't arrived yet, but the state is already `.inactive`.
            isAppActive: { UIApplication.shared.applicationState == .active }
        )
        crashListener = Task { [weak self] in
            let events = detector.events
            for await event in events { self?.handleCrash(event) }
        }
    }

    /// One listener for the app's lifetime (an AsyncStream ends when its consumer is cancelled, so it
    /// must not live in a view). Starts the check-in at once and shows it when the app is on screen.
    func handleCrash(_ incoming: CrashEvent) {
        guard let ownerID = session.user?.id ?? driveWatcher.configuration?.ownerID,
              !crashCenter.isCounting else { return }
        var event = incoming
        event.impact = event.impact ?? intelligence.impactReport(for: event)
        crashCenter.begin(event, ownerID: ownerID)
        router.activeCrash = event
        router.assistantIncident?.behaviorEvents = intelligence.behaviorEvents(before: event.date)
    }

    /// The configuration the app ships with.
    static func live() -> AppEnvironment {
        AppEnvironment(
            auth: makeAuthService(),
            crashDetector: nil,                       // Live shared sensors + experimental evidence rules
            assistant: RAGAssistantService.configured(),        // AI TEAM: Cloud / on-device assistant
            voiceInput: MockVoiceInputService(),      // AI TEAM: speech recognizer
            tripPacks: MapKitTripPackService(),       // Apple Maps search (mock fallback without coordinates)
            alerts: BackendEmergencyAlertService.configured(  // Texts + automated calls via /v1/alerts
                driverName: { SharedEnvironment.current?.session.user?.name ?? "" },
                location: { SharedEnvironment.current?.location.location.map { ($0.coordinate.latitude, $0.coordinate.longitude) } }),
            weather: AppleWeatherService(),           // Apple Weather (WeatherKit), Open-Meteo fallback
            connectivity: ConnectivityMonitor(),
            speedLimits: SpeedLimitService(),         // Posted limits from OpenStreetMap (free)
            alarm: SpeakerCrashAlarm(),               // "Are you okay?" prompts + siren
            dialer: SystemEmergencyDialer()           // tel://911 (iOS asks to confirm)
        )
    }

    /// Uses Firebase when the SDK is linked *and* GoogleService-Info.plist is bundled;
    /// otherwise falls back to the offline mock so the app always runs.
    private static func makeAuthService() -> any AuthService {
        #if canImport(FirebaseAuth) && canImport(FirebaseCore)
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            return FirebaseAuthService()
        }
        #endif
        return MockAuthService()
    }
}

/// Motion & Fitness and notification permission state, re-read whenever the app becomes active,
/// so a change made in Settings shows up (and takes effect) as soon as the user comes back.
/// Location permission lives on `LocationService`, which Core Location keeps current.
@Observable
final class PermissionCenter {
    private(set) var motion: CMAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    private(set) var notifications: UNAuthorizationStatus = .notDetermined

    var motionGranted: Bool { motion == .authorized }
    var motionDenied: Bool { motion == .denied || motion == .restricted }
    var notificationsGranted: Bool { notifications == .authorized || notifications == .provisional }
    var notificationsDenied: Bool { notifications == .denied }

    func refresh() async {
        motion = CMMotionActivityManager.authorizationStatus()
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Querying recent activity is what triggers the Motion & Fitness prompt.
    func requestMotion() async {
        if motionDenied {
            Self.openSettings()
            return
        }
        let manager = CMMotionActivityManager()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            manager.queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { _, _ in
                done.resume()
            }
        }
        await refresh()
    }

    func requestNotifications() async {
        if notificationsDenied {
            Self.openSettings()
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .criticalAlert])
        await refresh()
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Auth state for the whole app.
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case launching
        case signedOut
        case signedIn(AuthUser)
    }

    private(set) var phase: Phase = .launching
    @ObservationIgnored let auth: any AuthService

    init(auth: any AuthService) {
        self.auth = auth
    }

    var user: AuthUser? {
        if case .signedIn(let user) = phase { user } else { nil }
    }

    /// Restores any saved session, keeping the splash up for at least `minimumSplash`.
    func restore(minimumSplash: Duration = .seconds(1.4)) async {
        let deadline = ContinuousClock.now + minimumSplash
        let user = await auth.restoreSession()
        try? await Task.sleep(until: deadline)
        phase = user.map(Phase.signedIn) ?? .signedOut
    }

    func didAuthenticate(_ user: AuthUser) {
        phase = .signedIn(user)
    }

    func signOut() {
        try? auth.signOut()
        phase = .signedOut
    }

    func deleteAccount() async throws {
        try await auth.deleteAccount()
        phase = .signedOut
    }

    /// For previews/tests.
    func forceSignIn(_ user: AuthUser) {
        phase = .signedIn(user)
    }
}

/// Cross-screen navigation: selected tab, crash check-in, and how the assistant was opened.
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case home, trips, assistant, profile
    }

    var selectedTab: Tab = .home
    /// Non-nil while the full-screen "Are you OK?" check-in is showing.
    var activeCrash: CrashEvent? {
        didSet {
            if let event = activeCrash { assistantIncident = AssistantIncident.make(event: event) }
        }
    }
    var assistantIncident: AssistantIncident?
    /// Set when the check-in hands off to the assistant; consumed by the assistant screen.
    var pendingAssistantScenario: AssistantScenario?
    /// Full-screen CarPlay-style driving mode.
    var showingCarPlay = false

    func openAssistant(after outcome: CheckInOutcome) {
        pendingAssistantScenario = .afterCrash(outcome)
        activeCrash = nil
        selectedTab = .assistant
    }
}
