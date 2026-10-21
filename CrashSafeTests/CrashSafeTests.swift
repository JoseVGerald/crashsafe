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
