import Foundation
import Testing
@testable import CrashSafe

@MainActor
struct ValidationTests {
    @Test func emailRules() {
        #expect(Validation.email("") == "Enter your email.")
        #expect(Validation.email("jose@") != nil)
        #expect(Validation.email(" jose@example.com ") == nil)
    }

    @Test func passwordRules() {
        #expect(Validation.newPassword("short") == "Use at least 8 characters.")
        #expect(Validation.newPassword("longenough") == nil)
        #expect(Validation.confirmation("a", matches: "b") == "Passwords don't match.")
        #expect(Validation.confirmation("same", matches: "same") == nil)
    }

    @Test func phoneRules() {
        #expect(Validation.phone("") != nil)
        #expect(Validation.phone("555") != nil)
        #expect(Validation.phone("(206) 555-0100") == nil)
    }

    @Test func signUpErrorsOnlyShowAfterTouchOrSubmit() async {
        let session = SessionStore(auth: makeAuth())
        let viewModel = SignUpViewModel(session: session)
        #expect(viewModel.error(for: .email) == nil)
        viewModel.touched.insert(.email)
        #expect(viewModel.error(for: .email) == "Enter your email.")
        await viewModel.submit()
        #expect(viewModel.error(for: .name) == "Enter your name.")
        #expect(session.user == nil)
    }
}

@MainActor
struct MockAuthTests {
    @Test func signUpThenSignIn() async throws {
        let auth = makeAuth()
        let created = try await auth.signUp(name: "Jose", email: "Jose@Example.com", password: "password1")
        #expect(created.email == "jose@example.com")
        try auth.signOut()
        #expect(await auth.restoreSession() == nil)

        let signedIn = try await auth.signIn(email: "jose@example.com", password: "password1")
        #expect(signedIn.id == created.id)
        #expect(await auth.restoreSession() == created)
    }

    @Test func rejectsDuplicateEmailAndWrongPassword() async throws {
        let auth = makeAuth()
        _ = try await auth.signUp(name: "Jose", email: "jose@example.com", password: "password1")
        await #expect(throws: AuthError.emailInUse) {
            try await auth.signUp(name: "Other", email: "jose@example.com", password: "password2")
        }
        await #expect(throws: AuthError.wrongPassword) {
            try await auth.signIn(email: "jose@example.com", password: "nope-nope")
        }
        await #expect(throws: AuthError.userNotFound) {
            try await auth.signIn(email: "nobody@example.com", password: "password1")
        }
    }
}

@MainActor
struct CheckInTests {
    private func makeViewModel(recipients: [AlertRecipient] = [], online: Bool = true) -> CheckInViewModel {
        CheckInViewModel(
            event: CrashEvent(date: .now, peakG: 5, speedDropMPH: 30, isSimulated: true),
            recipients: recipients,
            alerts: MockEmergencyAlertService(),
            isOnline: { online },
            duration: 3,
            tick: .milliseconds(10)
        )
    }

    @Test func countdownRunsOutToNoResponse() async throws {
        let viewModel = makeViewModel()
        var recorded: CheckInOutcome?
        viewModel.onResolve = { recorded = $0 }
        viewModel.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.secondsRemaining == 0)
        #expect(viewModel.phase == .resolved(.noResponse))
        #expect(recorded == .noResponse)
    }

    @Test func answeringStopsTheCountdown() async throws {
        let viewModel = makeViewModel()
        viewModel.start()
        viewModel.respond(.ok)
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.phase == .resolved(.ok))
        #expect(viewModel.secondsRemaining == 3)
        // A second answer is ignored.
        viewModel.respond(.needsHelp)
        #expect(viewModel.phase == .resolved(.ok))
    }

    @Test func offlineAlertsAreQueued() async throws {
        let viewModel = makeViewModel(recipients: [AlertRecipient(name: "Maria", phone: "555-0100")], online: false)
        viewModel.respond(.needsHelp)
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(viewModel.alertDelivery == .queued)
    }
}

@MainActor
struct AssistantTests {
    @Test func crashScenarioStartsSafetyFirst() async throws {
        let viewModel = AssistantViewModel(
            service: MockAssistantService(latency: .zero),
            voice: MockVoiceInputService(),
            contextProvider: {
                AssistantContext(userName: "Jose Gerald", isOnline: true, scenario: .general, carDescription: "",
                                 insurer: "State Farm", medicalNotes: "", familyContactNames: [])
            }
        )
        viewModel.begin(.afterCrash(.ok))
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages[0].text.contains("911"))

        await viewModel.send("What do I tell insurance?")
        #expect(viewModel.messages.count == 3)
        #expect(viewModel.messages[2].text.contains("State Farm"))
    }
}

@MainActor
private func makeAuth() -> MockAuthService {
    let suite = "tests-\(UUID().uuidString)"
    return MockAuthService(defaults: UserDefaults(suiteName: suite)!, latency: .zero)
}

@MainActor
struct DrivingIntelligenceTests {
    private func snapshot(speed: Double, limit: Double?, environment: RoadEnvironment = .forest) -> DrivingSnapshot {
        var s = DrivingSnapshot()
        s.speedMPH = speed
        s.speedLimitMPH = limit
        s.environment = environment
        return s
    }

    @Test func adviceSlowsDownForRainAtNight() {
        let rain = WeatherSnapshot(temperatureF: 45, condition: .rain, windMph: 5, visibilityMiles: 5, isDay: false)
        let advice = DrivingAdvice.make(weather: rain, isNight: true)
        #expect(advice.speedReductionPercent == 20)
        #expect(advice.followingSeconds == 6)
        #expect(advice.tips.contains { $0.text == "Headlights on" })
    }

    @Test func comparisonHasToleranceBuffers() {
        let advice = DrivingAdvice.make(weather: nil, isNight: false) // clear day, factor 1.0
        #expect(DrivingComparison.make(snapshot: snapshot(speed: 31, limit: 30), advice: advice, isDriving: true).status == .onTrack)
        #expect(DrivingComparison.make(snapshot: snapshot(speed: 34, limit: 30), advice: advice, isDriving: true).status == .caution)
        #expect(DrivingComparison.make(snapshot: snapshot(speed: 40, limit: 30), advice: advice, isDriving: true).status == .tooFast)
        #expect(DrivingComparison.make(snapshot: snapshot(speed: 0, limit: 30), advice: advice, isDriving: false).status == .noData)
    }

    @Test func coachingMatchesDriverStyle() {
        let drizzle = WeatherSnapshot(temperatureF: 41, condition: .drizzle, windMph: 6, visibilityMiles: 3, isDay: false)
        let advice = DrivingAdvice.make(weather: drizzle, isNight: true)
        var input = CoachingEngine.Input(snapshot: snapshot(speed: 58, limit: 50), advice: advice, weather: drizzle,
                                         isNight: true, style: .logical, experience: .newDriver, lovedOne: "your mom")
        let logical = CoachingEngine.message(for: input)
        #expect(logical.severity == .warning)
        #expect(logical.body.contains("ft to stop"))
        #expect(logical.body.contains("wooded"))

        input.style = .emotional
        let emotional = CoachingEngine.message(for: input)
        #expect(emotional.body.hasPrefix("Your mom"))
        #expect(emotional.body.contains("deer"))
    }

    @Test func stoppingDistanceGrowsOnWetRoads() {
        #expect(CoachingEngine.stoppingDistanceFeet(mph: 60, friction: 0.45) > CoachingEngine.stoppingDistanceFeet(mph: 60, friction: 0.7))
        #expect(CoachingEngine.stoppingDistanceFeet(mph: 58, friction: 0.55) == 330)
        #expect(CoachingEngine.stoppingDistanceFeet(mph: 45, friction: 0.55) == 220)
    }

    @Test func phoneNumbersFormatForDisplay() {
        #expect(PhoneFormat.display("2065550100") == "(206) 555-0100")
        #expect(PhoneFormat.display("+1 206 555 0100") == "(206) 555-0100")
        #expect(PhoneFormat.display("555") == "555")
    }

    @Test func weatherCodesMapToConditions() {
        #expect(WeatherCondition(wmoCode: 0) == .clear)
        #expect(WeatherCondition(wmoCode: 63) == .rain)
        #expect(WeatherCondition(wmoCode: 75) == .snow)
        #expect(WeatherCondition(wmoCode: 95) == .thunderstorm)
    }
}
