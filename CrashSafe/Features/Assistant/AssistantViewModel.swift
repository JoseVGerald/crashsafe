import Foundation
import Observation

@Observable
final class AssistantViewModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var scenario: AssistantScenario = .general
    var draft = ""
    private(set) var isThinking = false
    private(set) var isListening = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any AssistantService
    @ObservationIgnored private let voice: any VoiceInputService
    /// Rebuilt on every request so replies use the latest profile and connectivity.
    @ObservationIgnored var contextProvider: () -> AssistantContext

    init(service: any AssistantService,
         voice: any VoiceInputService,
         contextProvider: @escaping () -> AssistantContext) {
        self.service = service
        self.voice = voice
        self.contextProvider = contextProvider
    }

    var isAfterCrash: Bool {
        if case .afterCrash = scenario { true } else { false }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    /// Starts a fresh conversation for a new scenario; a `.general` request keeps any chat in progress.
    func begin(_ scenario: AssistantScenario) {
        guard scenario != .general || messages.isEmpty else { return }
        self.scenario = scenario
        var context = contextProvider()
        context.scenario = scenario
        messages = [ChatMessage(role: .assistant, text: service.greeting(for: context))]
        errorMessage = nil
    }

    func send(_ text: String? = nil) async {
        let body = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isThinking else { return }
        if text == nil { draft = "" }
        messages.append(ChatMessage(role: .user, text: body))
        isThinking = true
        errorMessage = nil
        defer { isThinking = false }
        do {
            var context = contextProvider()
            context.scenario = scenario
            let reply = try await service.reply(to: messages, context: context)
            messages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            errorMessage = "The assistant couldn't answer. Your saved guides still work offline."
        }
    }

    func listen() async {
        guard !isListening, !isThinking else { return }
        isListening = true
        do {
            let transcript = try await voice.listen()
            isListening = false
            await send(transcript)
        } catch {
            isListening = false
            errorMessage = "Couldn't hear that. Try again or type your question."
        }
    }
}
