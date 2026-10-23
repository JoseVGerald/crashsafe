import Foundation
import Testing
@testable import CrashSafe

/// Answers the app's requests to the Pulse backend from a script (no network).
nonisolated final class StubBackend: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data, type: String)] = [:]
    nonisolated(unsafe) static var seen: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.seen.append(path)
        let route = Self.routes[path] ?? (404, Data(), "application/json")
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil,
                                       headerFields: ["Content-Type": route.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

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
    func greeting(for context: AssistantContext) -> String { "" }
    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        lastHistory = history
        return "Pulse heard: \(history.last?.text ?? "")"
    }
}

@MainActor
struct TapToTalkTests {
    @Test func whatYouSayGoesToPulseAndFollowUpsKeepTheConversation() async throws {
        let voice = ScriptedVoice(["Someone hit my bumper", "Do I call the police?"])
        let assistant = EchoAssistant()
        let talk = PressToTalkViewModel(assistant: assistant, voice: voice) {
            AssistantContext(userName: "Test", isOnline: true, scenario: .general, carDescription: "", insurer: "",
                             medicalNotes: "", familyContactNames: [])
        }
        talk.pressBegan()
        talk.pressEnded()
        for _ in 0..<50 where !(talk.phase.isAnswered) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(talk.phase == .answered(transcript: "Someone hit my bumper", reply: "Pulse heard: Someone hit my bumper"))
        talk.pressBegan()
        talk.pressEnded()
        for _ in 0..<50 where assistant.lastHistory.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(assistant.lastHistory.map(\.text) == ["Someone hit my bumper", "Pulse heard: Someone hit my bumper", "Do I call the police?"])
    }
}

extension PressToTalkViewModel.Phase {
    var isAnswered: Bool { if case .answered = self { true } else { false } }
}
