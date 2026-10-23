import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pulse on the phone's own model (Apple Intelligence, iOS 26+): free, no daily limit, and it works offline.
/// This is the team's design for the phone (pulse_agent's `on_device_request`): their short Core written for a
/// small model (`core_mini`) with the same [PULSE_TURN] block, so the same mode and weighting apply. The reply
/// goes through the same sentence filter as the cloud model's. Used when OpenRouter can't answer.
enum OnDevicePulse {
    static let modelName = "apple-on-device"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// The model's raw reply, or nil when it isn't available or declines.
    static func reply(to history: [ChatMessage], turn: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable,
              let query = history.last(where: { $0.role == .user })?.text else { return nil }
        let session = LanguageModelSession(instructions: PulseTeamAgent.coreMini + "\n\n" + turn)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 384)
        do {
            return try await session.respond(to: prompt(history: history, query: query), options: options).content
        } catch {
            return nil  // Context too long, guardrail, or model busy: the on-device guides answer instead.
        }
        #else
        return nil
        #endif
    }

    /// The conversation so far, newest last, kept small for the on-device context window.
    static func prompt(history: [ChatMessage], query: String) -> String {
        let earlier = history.dropLast().suffix(8).map { message in
            let said = message.role == .user ? message.text : PulseSpeaker.spokenPart(of: message.text)
            return (message.role == .user ? "Person: " : "Pulse: ") + String(said.prefix(400))
        }
        let now = "Person: " + String(query.prefix(1000))
        return earlier.isEmpty ? now : "Conversation so far:\n" + earlier.joined(separator: "\n") + "\n\nReply to the latest:\n" + now
    }
}
