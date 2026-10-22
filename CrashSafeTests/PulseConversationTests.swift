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
