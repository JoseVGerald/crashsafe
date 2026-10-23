import Foundation
import Testing
@testable import CrashSafe

/// Answers the app's requests to the Pulse backend from a script (no network).
nonisolated final class StubBackend: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data, type: String)] = [:]
    nonisolated(unsafe) static var seen: [String] = []
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    /// Replies used once each, in order, before `routes` (for multi-step exchanges).
    nonisolated(unsafe) static var queued: [String: [(status: Int, body: Data, type: String)]] = [:]
    nonisolated(unsafe) static var log: [(path: String, body: [String: Any]?, headers: [String: String])] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.seen.append(path)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { data.append(buffer, count: n) }
            stream.close()
            Self.bodies[path] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        Self.log.append((path, Self.bodies[path], request.allHTTPHeaderFields ?? [:]))
        let route: (status: Int, body: Data, type: String)
        if var next = Self.queued[path], !next.isEmpty {
            route = next.removeFirst()
            Self.queued[path] = next
        } else {
            route = Self.routes[path] ?? (404, Data(), "application/json")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil,
                                       headerFields: ["Content-Type": route.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() {
        seen = []; bodies = [:]; queued = [:]; log = []; routes = [:]
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubBackend.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
@Suite(.serialized)
struct PulseConversationTests {
    private func context() -> AssistantContext {
        var value = AssistantContext(userName: "Test", isOnline: true, scenario: .general,
            carDescription: "", insurer: "", medicalNotes: "", familyContactNames: [])
        value.assistanceStage = "active"
        return value
    }

    @Test func conversationalPulseAnswersFirst() async throws {
        StubBackend.seen = []
        StubBackend.routes = ["/v1/converse": (200, Data(#"{"status":"answered","answer":"I'm here with you. Are you somewhere safe?","citations":[]}"#.utf8), "application/json")]
        let service = RAGAssistantService(endpoint: URL(string: "https://pulse.test")!, session: StubBackend.session())
        let reply = try await service.reply(to: [ChatMessage(role: .user, text: "someone hit my car at a light")], context: context())
        #expect(reply == "I'm here with you. Are you somewhere safe?")
        #expect(StubBackend.seen == ["/v1/converse"])
    }

    /// The team's Pulse agent keeps the conversation by id and can ask the app to offer a call or a tow search.
    @Test func conversationIdGoesAlongAndPulsesOffersComeBack() async throws {
        StubBackend.seen = []
        StubBackend.routes = ["/v1/converse": (200, Data(#"{"status":"answered","answer":"I'm right here with you.","citations":[],"actions":[{"action":"emergency_call_prompt","status":"offered"},{"action":"find_tow","status":"app_action_requested"},{"action":"alert_contacts","status":"permission_denied"}]}"#.utf8), "application/json")]
        let service = RAGAssistantService(endpoint: URL(string: "https://pulse.test")!, session: StubBackend.session())
        var context = context()
        context.conversationID = "conv-1234"
        _ = try await service.reply(to: [ChatMessage(role: .user, text: "I can't stop shaking")], context: context)
        #expect(StubBackend.bodies["/v1/converse"]?["conversation_id"] as? String == "conv-1234")
        #expect(service.requestedActions == ["emergency_call_prompt", "find_tow"])   // denied tools aren't offered
        StubBackend.routes["/v1/converse"] = (200, Data(#"{"status":"answered","answer":"Okay.","citations":[]}"#.utf8), "application/json")
        _ = try await service.reply(to: [ChatMessage(role: .user, text: "thanks")], context: context)
        #expect(service.requestedActions.isEmpty)
    }

    @Test func verifiedAnswerWhenConversationIsUnavailable() async throws {
        StubBackend.seen = []
        StubBackend.routes = [
            "/v1/converse": (503, Data(), "application/json"),
            "/v1/assist": (200, Data(#"{"status":"answered","answer":"Exchange insurance details.","citations":[{"title":"WSDOT","url":"https://wsdot.wa.gov"}]}"#.utf8), "application/json"),
        ]
        let service = RAGAssistantService(endpoint: URL(string: "https://pulse.test")!, session: StubBackend.session())
        let reply = try await service.reply(to: [ChatMessage(role: .user, text: "what do I exchange with the other driver")], context: context())
        #expect(reply.hasPrefix("Exchange insurance details."))
        #expect(StubBackend.seen == ["/v1/converse", "/v1/assist"])
    }

    @Test func emergenciesNeverWaitForTheServer() async throws {
        StubBackend.seen = []
        let service = RAGAssistantService(endpoint: URL(string: "https://pulse.test")!, session: StubBackend.session())
        let reply = try await service.reply(to: [ChatMessage(role: .user, text: "the car is on fire")], context: context())
        #expect(reply.hasPrefix("Call 911"))
        #expect(StubBackend.seen.isEmpty)
        #expect(service.requestedActions == ["emergency_call_prompt"])
    }

    @Test func spokenRepliesLeaveOutSourcesAndCardIDs() {
        #expect(PulseSpeaker.spokenPart(of: "Turn on your hazards. [HAZARDS]\n\nSources:\nWSDOT: https://x") == "Turn on your hazards.")
    }
}

/// Says a scripted sentence each time it "listens".
final class ScriptedVoice: VoiceInputService {
    var lines: [String]
    private(set) var partial = ""
    init(_ lines: [String]) { self.lines = lines }
    func start() async throws { partial = "" }
    func finish() async throws -> String { lines.removeFirst() }
    func listen() async throws -> String { lines.removeFirst() }
    func cancel() {}
}

/// Answers with what it was asked, so the test can see the history Pulse received.
final class EchoAssistant: AssistantService {
    private(set) var lastHistory: [ChatMessage] = []
    private(set) var conversationIDs: [String?] = []
    var requestedActions: [String] = []
    func greeting(for context: AssistantContext) -> String { "" }
    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        lastHistory = history
        conversationIDs.append(context.conversationID)
        return "Pulse heard: \(history.last?.text ?? "")"
    }
}

/// A caller who says each scripted line after a beat, says nothing once (silence), then stays on the line.
final class CallScriptVoice: VoiceInputService {
    var lines: [String?]
    private(set) var partial = ""
    init(_ lines: [String?]) { self.lines = lines }
    func start() async throws {}
    func finish() async throws -> String { throw SpeechVoiceInput.Failure.heardNothing }
    func cancel() {}
    func listen() async throws -> String {
        try await Task.sleep(for: .milliseconds(10))
        guard !lines.isEmpty else {
            try await Task.sleep(for: .seconds(60))  // Quiet line until the call ends.
            throw SpeechVoiceInput.Failure.heardNothing
        }
        guard let line = lines.removeFirst() else { throw SpeechVoiceInput.Failure.heardNothing }
        return line
    }
}

@MainActor
struct PulseCallTests {
    private func call(_ voice: CallScriptVoice, _ assistant: EchoAssistant) -> PulseCallViewModel {
        PulseCallViewModel(assistant: assistant, voice: voice) {
            AssistantContext(userName: "Test", isOnline: true, scenario: .general, carDescription: "", insurer: "",
                             medicalNotes: "", familyContactNames: [])
        }
    }

    /// One tap, then back and forth with no more taps: Pulse greets, answers each turn, and keeps listening.
    @Test func turnsFlowBackAndForthUntilHangUp() async throws {
        let voice = CallScriptVoice(["Someone hit my bumper", nil, "Do I call the police?"])  // a silence in between
        let assistant = EchoAssistant()
        let pulse = call(voice, assistant)
        pulse.startCall()
        #expect(pulse.inCall)
        for _ in 0..<100 where assistant.lastHistory.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(assistant.lastHistory.map(\.text) == [PulseCallViewModel.greeting, "Someone hit my bumper",
                                                     "Pulse heard: Someone hit my bumper", "Do I call the police?"])
        #expect(assistant.conversationIDs.count == 2 && assistant.conversationIDs[0] == assistant.conversationIDs[1])
        for _ in 0..<100 where pulse.phase != .listening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pulse.lastReply == "Pulse heard: Do I call the police?")   // still on the line, listening again
        pulse.endCall()
        #expect(pulse.phase == .idle && !pulse.inCall && pulse.startedAt == nil)
    }

    /// Muted: Pulse hears nothing (no turn is sent) until you unmute; then the call carries on.
    @Test func muteKeepsTheMicClosedUntilUnmuted() async throws {
        let assistant = EchoAssistant()
        let pulse = call(CallScriptVoice(["Can you hear me?"]), assistant)
        pulse.startCall()
        pulse.toggleMute()
        try await Task.sleep(for: .milliseconds(300))
        #expect(pulse.isMuted && assistant.lastHistory.isEmpty && pulse.phase == .listening)
        pulse.toggleMute()
        for _ in 0..<100 where assistant.lastHistory.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(assistant.lastHistory.last?.text == "Can you hear me?")
        pulse.endCall()
        #expect(!pulse.isMuted)
    }

    @Test func pulsesCallPromptShowsDuringTheCall() async throws {
        let assistant = EchoAssistant()
        assistant.requestedActions = ["emergency_call_prompt"]
        let pulse = call(CallScriptVoice(["my friend hit her head and is confused"]), assistant)
        pulse.startCall()
        for _ in 0..<100 where !pulse.offersEmergencyCall { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pulse.offersEmergencyCall && !pulse.offersTowSearch)
        pulse.endCall()
        pulse.startCall()                                  // a new call starts clean
        #expect(!pulse.offersEmergencyCall && pulse.history.count <= 1)
        pulse.endCall()
    }
}


/// Pulse straight from the phone: OpenRouter for the reply, Cartesia for Corey. No server involved.
@MainActor
@Suite(.serialized)
struct DirectPulseTests {
    private let completions = "/api/v1/chat/completions"
    private func context() -> AssistantContext {
        AssistantContext(userName: "Test", isOnline: true, scenario: .general, carDescription: "", insurer: "",
                         medicalNotes: "", familyContactNames: [])
    }
    private func chat(_ message: String) -> (status: Int, body: Data, type: String) {
        (200, Data(#"{"choices":[{"message":\#(message)}]}"#.utf8), "application/json")
    }

    @Test func pulseAnswersFromOpenRouterWithTheTeamsCoreAndFilter() async throws {
        StubBackend.reset()
        StubBackend.routes[completions] = chat(#"{"content":"I'm right here with you. Calm down. Take 400 mg of ibuprofen. Help is on the way. Turn on your hazard lights if you can... Exchange insurance details."}"#)
        let service = DirectPulseService(key: "sk-test-0123456789abcdef", fallback: LocalEvidenceAssistant(), session: StubBackend.session(), onDevice: { _, _ in nil })
        let history = [ChatMessage(role: .user, text: "I got rear-ended"), ChatMessage(role: .assistant, text: "Are you somewhere safe?"),
                       ChatMessage(role: .user, text: "yes. what do I tell my insurance?")]
        let reply = try await service.reply(to: history, context: context())
        let spoken = PulseSpeaker.spokenPart(of: reply)
        #expect(spoken == "I'm right here with you. I can't give a medication dose. I don't have confirmation that worked. Turn on your hazard lights if you can, Exchange insurance details.")
        #expect(service.lastModel == "nvidia/nemotron-3.5-lightning:free")
        #expect(!reply.contains("Sources:"))
        let request = try #require(StubBackend.log.first)
        #expect(request.headers["Authorization"] == "Bearer sk-test-0123456789abcdef")
        let body = try #require(request.body)
        #expect(body["model"] as? String == "nvidia/nemotron-3.5-lightning:free")
        #expect(body["max_tokens"] as? Int == 384 && body["temperature"] as? Int == 0)
        #expect((body["reasoning"] as? [String: Any])?["enabled"] as? Bool == false)
        // The team's request: Core, then [PULSE_TURN], then their knowledge notes, then the conversation.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }
        #expect(system.first == PulseTeamAgent.core && system.first?.hasPrefix("[PULSE_CORE]") == true)
        #expect(system.dropFirst().first?.hasPrefix("[PULSE_TURN]\n{") == true)
        #expect(system.dropFirst().first?.contains(#""mode":"standby""#) == true)
        #expect(system.count == 2 || system.last?.hasPrefix("[PULSE_KNOWLEDGE]") == true)
        #expect(messages.dropFirst(system.count).compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
    }

    @Test func toolRequestsBecomeButtonsAndTheModelFinishesItsReply() async throws {
        StubBackend.reset()
        StubBackend.queued[completions] = [
            chat(#"{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"emergency_call_prompt","arguments":"{}"}}]}"#),
            chat(#"{"content":"Tap Call 911 now. I'm staying right here with you."}"#)]
        let service = DirectPulseService(key: "sk-test-0123456789abcdef", fallback: LocalEvidenceAssistant(), session: StubBackend.session(), onDevice: { _, _ in nil })
        let reply = try await service.reply(to: [ChatMessage(role: .user, text: "my friend hit her head and seems confused")], context: context())
        #expect(PulseSpeaker.spokenPart(of: reply) == "Tap Call 911 now. I'm staying right here with you.")
        #expect(service.requestedActions == ["emergency_call_prompt"])
        let second = try #require(StubBackend.log.last?.body)
        #expect(second["tool_choice"] as? String == "none")
        let tool = try #require((second["messages"] as? [[String: Any]])?.last)
        #expect(tool["role"] as? String == "tool" && (tool["content"] as? String)?.contains(#""performed": false"#) == true)
    }

    @Test func emergenciesAndOutagesNeverWaitOnTheModel() async throws {
        StubBackend.reset()
        StubBackend.routes[completions] = (503, Data(), "application/json")
        let service = DirectPulseService(key: "sk-test-0123456789abcdef", fallback: LocalEvidenceAssistant(), session: StubBackend.session(), onDevice: { _, _ in nil })
        let urgent = try await service.reply(to: [ChatMessage(role: .user, text: "the car is on fire")], context: context())
        #expect(urgent.hasPrefix("Call 911") && StubBackend.log.isEmpty && service.requestedActions == ["emergency_call_prompt"])
        let answer = try await service.reply(to: [ChatMessage(role: .user, text: "what photographs should I take for documentation")], context: context())
        #expect(StubBackend.log.count == 2)              // both free models tried
        #expect(answer.contains("Photograph the scene"))  // then the verified on-device guide
        #expect(service.lastModel == nil)
    }

    /// OpenRouter's free plan allows 50 requests a day: once it says so, Pulse answers with the phone's own model
    /// (filtered the same way) and stops asking OpenRouter until the limit resets.
    @Test func dailyFreeLimitHandsOverToThePhonesModel() async throws {
        StubBackend.reset()
        StubBackend.routes[completions] = (429, Data(#"{"error":{"message":"Rate limit exceeded: free-models-per-day","code":429,"metadata":{"headers":{"X-RateLimit-Limit":"50","X-RateLimit-Remaining":"0","X-RateLimit-Reset":"1792800000000"}}}}"#.utf8), "application/json")
        var asked: [[ChatMessage]] = []
        let service = DirectPulseService(key: "sk-test-0123456789abcdef", fallback: LocalEvidenceAssistant(), session: StubBackend.session(),
                                         onDevice: { history, _ in asked.append(history); return "I'm here with you. Calm down. Are you somewhere safe?" })
        let first = [ChatMessage(role: .user, text: "someone rear-ended me")]
        let reply = try await service.reply(to: first, context: context())
        #expect(reply == "I'm here with you. Are you somewhere safe?")   // the team's filter still applies
        #expect(service.lastModel == OnDevicePulse.modelName)
        #expect(service.cloudPausedUntil == Date(timeIntervalSince1970: 1_792_800_000))
        #expect(StubBackend.log.count == 1)                                // the limit is shared: no second model tried
        _ = try await service.reply(to: first + [ChatMessage(role: .assistant, text: reply), ChatMessage(role: .user, text: "yes")], context: context())
        #expect(StubBackend.log.count == 1)                                // paused: straight to the phone
        #expect(asked.last?.map(\.text) == ["someone rear-ended me", reply, "yes"])   // with the conversation so far
    }

    @Test func onDevicePromptKeepsTheConversationSmall() {
        let history = (0..<12).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "turn \($0)") }
            + [ChatMessage(role: .user, text: "what color was the truck?")]
        let prompt = OnDevicePulse.prompt(history: history, query: "what color was the truck?")
        #expect(prompt.hasSuffix("Reply to the latest:\nPerson: what color was the truck?"))
        #expect(prompt.contains("Pulse: turn 11") && !prompt.contains("turn 3\n"))   // the last eight turns
        #expect(PulseTeamAgent.coreMini.hasPrefix("[PULSE_MINI]"))
    }

    /// As the team's agent: possible self-harm offers the Call 911 prompt alongside the model's reply.
    @Test func possibleSelfHarmOffersTheCallPrompt() async throws {
        StubBackend.reset()
        StubBackend.routes[completions] = chat(#"{"content":"I'm really glad you told me. I'm right here with you."}"#)
        let service = DirectPulseService(key: "sk-test-0123456789abcdef", fallback: LocalEvidenceAssistant(), session: StubBackend.session(), onDevice: { _, _ in nil })
        _ = try await service.reply(to: [ChatMessage(role: .user, text: "honestly I want to die")], context: context())
        #expect(service.requestedActions == ["emergency_call_prompt"])
        let turn = (StubBackend.log.first?.body?["messages"] as? [[String: Any]])?[1]["content"] as? String
        #expect(turn?.contains(#""possible_self_harm":true"#) == true)
    }

    #if targetEnvironment(simulator)
    /// The port reproduces the team's own code exactly: the [PULSE_TURN] text byte for byte, and the same
    /// knowledge notes chosen (golden outputs from Tools/Pulse/export_team_pulse.py, run on their pulse_agent).
    @Test func turnAndKnowledgeMatchTheTeamsAgentExactly() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/pulse_golden.json")
        let cases = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        #expect(cases.count == 7)
        for item in cases {
            let text = try #require(item["text"] as? String), mode = try #require(item["mode"] as? String)
            let connectivity = try #require(item["connectivity"] as? String)
            let crash = try #require(item["crash"] as? [String: Any])
            #expect(PulseTeamAgent.turn(text: text, mode: mode, connectivity: connectivity, crash: crash) == item["turn"] as? String, "\(text)")
            #expect(PulseKnowledgeIndex.shared.search(text, mode: mode, connectivity: connectivity).ids == item["knowledge_ids"] as? [String], "\(text)")
        }
    }
    #endif

    /// The same cases as the team's Python filter tests (Backend/rag/tests/test_pulse_voice.py).
    @Test func theTeamsSentenceFilterHoldsInSwift() {
        typealias F = PulseSentenceFilter
        #expect(F.filter("Calm down.") == .drop(reason: "banned_phrase"))
        #expect(F.filter("You're fine.") == .drop(reason: "banned_phrase"))
        #expect(F.filter("Take 2.5 mg now.") == .rewrite(F.doseFallback, reason: "dose_pattern"))
        #expect(F.filter("Take two of them.", medicationQuestion: true) == .rewrite(F.doseFallback, reason: "medication_quantity"))
        #expect(F.filter("Help is on the way.") == .rewrite("I don't have confirmation that worked.", reason: "unconfirmed_action"))
        #expect(F.filter("I've notified your sister.", successfulActions: ["emergency_call_prompt"]).text == "I don't have confirmation that worked.")
        #expect(F.filter("- Move to the shoulder if it's safe.") == .pass("Move to the shoulder if it's safe."))
        #expect(F.filter("See https://example.com.") == .drop(reason: "not_speech"))
        #expect(F.sentences("Take 2.5 mg. Are you okay? Breathe") == ["Take 2.5 mg.", "Are you okay?", "Breathe"])
    }

    @Test func coreyComesStraightFromCartesia() async throws {
        StubBackend.reset()
        StubBackend.routes["/tts/bytes"] = (200, Data(repeating: 7, count: 4000), "audio/mpeg")
        let speaker = PulseSpeaker(endpoint: nil, cartesiaKey: "sk_car_test_0123456789", session: StubBackend.session())
        let audio = await speaker.corey("I'm right here with you.")
        #expect(audio?.count == 4000)
        let request = try #require(StubBackend.log.first)
        #expect(request.headers["X-API-Key"] == "sk_car_test_0123456789")
        #expect((request.body?["voice"] as? [String: Any])?["id"] as? String == PulseSpeaker.corey)
        #expect(request.body?["transcript"] as? String == "I'm right here with you.")
    }

    /// When the main Cartesia key is refused (e.g. out of credits), the backup key speaks, and is tried first after.
    @Test func backupCartesiaKeyTakesOver() async throws {
        StubBackend.reset()
        StubBackend.queued["/tts/bytes"] = [(402, Data(#"{"error":"credits"}"#.utf8), "application/json"),
                                            (200, Data(repeating: 7, count: 4000), "audio/mpeg"),
                                            (200, Data(repeating: 8, count: 4000), "audio/mpeg")]
        let speaker = PulseSpeaker(endpoint: nil, cartesiaKey: "sk_car_main_0123456789", backupKey: "sk_car_backup_0123456789",
                                   session: StubBackend.session())
        #expect(await speaker.corey("First line.")?.count == 4000)
        #expect(StubBackend.log.map { $0.headers["X-API-Key"] } == ["sk_car_main_0123456789", "sk_car_backup_0123456789"])
        #expect(await speaker.corey("Second line.")?.first == 8)
        #expect(StubBackend.log.last?.headers["X-API-Key"] == "sk_car_backup_0123456789")
    }

    #if targetEnvironment(simulator)
    /// The app's copy of the team's prompt is the same as the backend's (both unchanged from the team's repo).
    @Test func bundledCoreMatchesTheTeamsFiles() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (bundled, original) in [("pulse_core", "core.md"), ("pulse_core_mini", "core_mini.md")] {
            let app = try String(contentsOf: try #require(Bundle.main.url(forResource: bundled, withExtension: "txt")), encoding: .utf8)
            #expect(app == (try String(contentsOf: repo.appending(path: "Backend/rag/pulse_core/\(original)"), encoding: .utf8)))
        }
    }
    #endif
}
