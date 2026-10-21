import Foundation
import Observation

/// Holds every service the app uses. Swap mocks for real implementations here.
@Observable
final class AppEnvironment {
    let session: SessionStore
    let router: AppRouter
    let connectivity: ConnectivityMonitor
    let location: LocationService
    let conditions: ConditionsStore
    let driving: DrivingMonitor
    let coach: DriveCoach
    let autoDetector = DriveAutoDetector()
    @ObservationIgnored let crashDetector: any CrashDetector
    @ObservationIgnored let assistant: any AssistantService
    @ObservationIgnored let voiceInput: any VoiceInputService
    @ObservationIgnored let tripPacks: any TripPackService
    @ObservationIgnored let alerts: any EmergencyAlertService

    init(auth: any AuthService,
         crashDetector: any CrashDetector,
         assistant: any AssistantService,
         voiceInput: any VoiceInputService,
         tripPacks: any TripPackService,
         alerts: any EmergencyAlertService,
         weather: any WeatherService,
         connectivity: ConnectivityMonitor,
         location: LocationService = LocationService()) {
        self.session = SessionStore(auth: auth)
        self.router = AppRouter()
        self.connectivity = connectivity
        self.location = location
        let conditions = ConditionsStore(service: weather)
        let driving = DrivingMonitor(location: location)
        self.conditions = conditions
        self.driving = driving
        self.coach = DriveCoach(driving: driving, conditions: conditions)
        self.crashDetector = crashDetector
        self.assistant = assistant
        self.voiceInput = voiceInput
        self.tripPacks = tripPacks
        self.alerts = alerts
    }

    /// The configuration the app ships with.
    static func live() -> AppEnvironment {
        AppEnvironment(
            auth: makeAuthService(),
            crashDetector: MockCrashDetector(),       // DETECTION TEAM: CoreMotionCrashDetector()
            assistant: MockAssistantService(),        // AI TEAM: Cloud / on-device assistant
            voiceInput: MockVoiceInputService(),      // AI TEAM: speech recognizer
            tripPacks: MapKitTripPackService(),       // Apple Maps search (mock fallback without coordinates)
            alerts: MockEmergencyAlertService(),      // Backend push/SMS
            weather: OpenMeteoWeatherService(),       // Live weather, no key needed
            connectivity: ConnectivityMonitor()
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
    var activeCrash: CrashEvent?
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
