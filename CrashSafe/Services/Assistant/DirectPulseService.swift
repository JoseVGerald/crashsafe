import Foundation
import os

/// Pulse's keys for calling OpenRouter and Cartesia straight from the phone. They come from build settings in
/// the git-ignored `Config/Pulse.xcconfig.local` (see `Config/Pulse.xcconfig`), so they are in builds made on
/// this Mac and never in git. Anyone holding a build could read them, so builds shared beyond your own phones
/// should leave them out and use a server (`Backend/Dockerfile`) instead.
nonisolated enum PulseKeys {
    static func openRouter(bundle: Bundle = .main) -> String? { value("PulseOpenRouterKey", bundle) }
    static func cartesia(bundle: Bundle = .main) -> String? { value("PulseCartesiaKey", bundle) }
    /// Used when the main Cartesia key is refused (out of credits, revoked, rate-limited).
    static func cartesiaBackup(bundle: Bundle = .main) -> String? { value("PulseCartesiaBackupKey", bundle) }

    private static func value(_ key: String, _ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              value.count >= 20, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

/// The team's deterministic sentence filter (`Backend/rag/pulse_core/sentence_filter.py`), in Swift: every
/// sentence a model writes passes it before it is shown or spoken. Never calls a model.
nonisolated enum PulseSentenceFilter {
    enum Decision: Equatable {
        case pass(String)
        case rewrite(String, reason: String)
        case drop(reason: String)

        var text: String? {
            switch self {
            case .pass(let text), .rewrite(let text, _): text
            case .drop: nil
            }
        }
    }

    static let doseFallback = "I can't give a medication dose."
    private static let number = #"(?:\d+(?:[.,]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|half|quarter)"#
    private static let dose = regex(#"\b\#(number)\s*(?:mg|mcg|μg|ug|g|kg|ml|milligrams?|micrograms?|grams?|millilit(?:er|re)s?|pills?|tablets?|capsules?|teaspoons?|tablespoons?|doses?)\b"#)
    private static let medicationQuantity = regex(#"\b(?:take|give|swallow|use)\b.{0,30}"# + number)
    private static let banned = regex(#"\b(?:calm(?:ing)? down|let'?s calm down|relax|don't panic|do not panic|everything will be fine|you(?:'re| are) fine|you(?:'ll| will) be (?:okay|ok)|it's nothing|it(?:'s| is) (?:not )?your fault|(?:you are|you're) uninjured)\b"#)
    private static let scoring = regex(#"C-SSRS|SAFE-T|Columbia.{0,20}(?:score|scale)|(?:low|moderate|high)[ -](?:acute[ -])?risk|lethality.{0,15}(?:score|scale)|hospitalization disposition"#)
    private static let action = regex(#"\b(?:done(?=[.!]?$)|sent(?=[.!]?$)|i(?:'ve| have)? (?:called|sent|notified|alerted|contacted|shared|booked)|help (?:is|are) (?:coming|on the way)|help knows where you are|they(?:'re| are) on the way)\b"#)
    private static let listMarker = regex(#"^(?:[-*•]\s+|\d+[.)]\s+)"#)
    private static let notSpeech = regex(#"https?://|[\[\]{}*_#<>]|\b(?:tool_call|function_name)\b"#)
    private static let required: [(NSRegularExpression, String)] = [
        (regex("called|help|on the way"), "emergency_call_prompt"), (regex("sent|notified|alerted|contacted"), "alert_contacts"),
        (regex("shared"), "share_location"), (regex("booked"), "book_tow_or_submit_claim")]
    private static let callClaim = regex(#"called|help (?:is|are)|on the way"#)
    private static let sentenceEnd = regex(#"(?<!\d)[.!?](?=\s|$)|(?<=\d)[!?](?=\s|$)"#)

    static func filter(_ text: String, successfulActions: Set<String> = [], medicationQuestion: Bool = false) -> Decision {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        normalized = listMarker.stringByReplacingMatches(in: normalized, range: whole(normalized), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return .drop(reason: "empty") }
        if matches(dose, normalized) { return .rewrite(doseFallback, reason: "dose_pattern") }
        if medicationQuestion && matches(medicationQuantity, normalized) { return .rewrite(doseFallback, reason: "medication_quantity") }
        if matches(banned, normalized) { return .drop(reason: "banned_phrase") }
        if matches(scoring, normalized) { return .drop(reason: "clinical_scoring") }
        let claimsAction = matches(action, normalized)
        if claimsAction && successfulActions.isEmpty {
            return .rewrite("I don't have confirmation that worked.", reason: "unconfirmed_action")
        }
        for (pattern, name) in required where claimsAction && matches(pattern, normalized) && !successfulActions.contains(name) {
            return .rewrite("I don't have confirmation that worked.", reason: "unmatched_action")
        }
        if claimsAction && matches(callClaim, normalized) { return .drop(reason: "call_prompt_not_dispatch_confirmation") }
        if matches(notSpeech, normalized) { return .drop(reason: "not_speech") }
        return .pass(normalized)
    }

    /// Whole sentences, as the team's `SentenceStream` splits them (a decimal dose like 2.5 mg stays whole).
    static func sentences(_ text: String) -> [String] {
        var rest = text, result: [String] = []
        while let match = sentenceEnd.firstMatch(in: rest, range: whole(rest)), let end = Range(match.range, in: rest) {
            result.append(String(rest[..<end.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static func whole(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: whole(text)) != nil
    }
}

/// Pulse straight from the phone, with no server: each request is built exactly as the team's Pulse agent builds
/// it (`PulseTeamAgent`: their Core, their per-turn context and weighting, their knowledge notes, the
/// conversation), sent to a free OpenRouter model with their model settings, and every sentence passes their
/// filter. The model may ask for two tools (the Call 911 button, a tow search), which the app only offers.
/// Emergencies are answered on the phone first with no model. When OpenRouter can't answer (its free plan
/// allows 50 requests a day, or no signal), the phone's own model does (`OnDevicePulse`, the team's design
/// for that), and after that `fallback` (the backend when configured, otherwise the on-device guides).
final class DirectPulseService: AssistantService {
    /// Both screened by the team (pulse_agent/config/model_profiles.json). OpenRouter's free-plan limit is shared.
    static let freeModels = ["nvidia/nemotron-3.5-lightning:free", "google/gemma-4-26b-a4b-it:free"]
    private static let log = Logger(subsystem: "org.cac.crashsafe", category: "assistant")
    /// The team's tool descriptions (pulse_agent/tools/dispatch.py) for the two tools the app can offer.
    private static let tools: [[String: Any]] = [
        ["type": "function", "function": ["name": "emergency_call_prompt",
            "description": "Ask the app to display its emergency calling prompt. Does not place or connect a call.",
            "parameters": ["type": "object", "properties": [String: Any]()]]],
        ["type": "function", "function": ["name": "find_tow",
            "description": "Request a read-only tow lookup after safety. Never books or pays.",
            "parameters": ["type": "object", "properties": [String: Any]()]]],
    ]

    private let key: String
    private let fallback: any AssistantService
    private let session: URLSession
    private let local = LocalEvidenceAssistant()
    private let knowledge: () -> PulseKnowledgeIndex
    private(set) var requestedActions: [String] = []
    /// Which model answered last (nil when the fallback did); for tests and diagnostics.
    private(set) var lastModel: String?
    /// Set when OpenRouter's daily free limit is used up: until then Pulse goes straight to the phone's model.
    private(set) var cloudPausedUntil: Date?
    /// The phone's model, given the conversation and this turn's [PULSE_TURN] block.
    private let onDevice: ([ChatMessage], String) async -> String?

    private struct DailyLimitReached: Error { let resetsAt: Date }

    init(key: String, fallback: any AssistantService, session: URLSession? = nil,
         knowledge: @escaping () -> PulseKnowledgeIndex = { .shared },
         onDevice: @escaping ([ChatMessage], String) async -> String? = OnDevicePulse.reply) {
        self.key = key
        self.fallback = fallback
        self.knowledge = knowledge
        self.onDevice = onDevice
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Direct when this build has an OpenRouter key, otherwise the backend/on-device assistant as before.
    static func configured() -> any AssistantService {
        let backend = RAGAssistantService.configured()
        guard let key = PulseKeys.openRouter() else { return backend }
        return DirectPulseService(key: key, fallback: backend)
    }

    func greeting(for context: AssistantContext) -> String { local.greeting(for: context) }

    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        let query = history.last(where: { $0.role == .user })?.text ?? ""
        requestedActions = []
        lastModel = nil
        if let urgent = LocalEvidenceAssistant.emergencyReply(query) {
            requestedActions = ["emergency_call_prompt"]
            return urgent
        }
        if let measured = LocalEvidenceAssistant.motionReply(query, context: context) { return measured }
        let flags = PulseTeamAgent.signals(query)
        // As the team's agent: possible self-harm offers the call prompt (it does not place a call).
        let offers = flags.selfHarm ? ["emergency_call_prompt"] : []
        let mode = PulseTeamAgent.mode(stage: context.assistanceStage, incident: context.incident)
        let connectivity = context.isOnline ? "online" : "offline"
        let turn = PulseTeamAgent.turn(text: query, mode: mode, connectivity: connectivity,
                                       crash: PulseTeamAgent.crash(from: context.incident))
        if context.isOnline, (cloudPausedUntil ?? .distantPast) < .now,
           let answer = try await converse(history, turn: turn, knowledge: knowledge().search(query, mode: mode, connectivity: connectivity).text,
                                           medication: flags.medication) {
            requestedActions = Array(Set(offers + requestedActions)).sorted()
            return answer
        }
        // The phone's own model: free, unlimited, and works with no signal.
        if let raw = await onDevice(history, turn) {
            lastModel = OnDevicePulse.modelName
            requestedActions = offers
            return Self.spoken(raw, medicationQuestion: flags.medication) ?? PulseTeamAgent.localFallback(medication: flags.medication)
        }
        let answer = try await fallback.reply(to: history, context: context)
        requestedActions = Array(Set(offers + fallback.requestedActions)).sorted()
        return answer
    }

    private func converse(_ history: [ChatMessage], turn: String, knowledge: String, medication: Bool) async throws -> String? {
        let messages = PulseTeamAgent.messages(history: history, turn: turn, knowledge: knowledge)
        for model in Self.freeModels {
            do {
                guard let (text, actions) = try await complete(model: model, messages: messages) else { continue }
                requestedActions = actions
                lastModel = model
                // When the filter removes every sentence, the team's agent says its short local line instead.
                return Self.spoken(text, medicationQuestion: medication) ?? PulseTeamAgent.localFallback(medication: medication)
            } catch is CancellationError {
                throw CancellationError()
            } catch let limit as DailyLimitReached {
                // Shared by every free model on the account: stop asking until it resets.
                cloudPausedUntil = limit.resetsAt
                Self.log.info("OpenRouter daily free limit reached; using the phone's model until it resets")
                return nil
            } catch {
                Self.log.info("model \(model, privacy: .public) unavailable")
            }
        }
        return nil
    }

    /// One turn with the team's two-step tool loop: if the model asks for a tool, the app records the request
    /// (nothing is performed) and asks the model to finish its reply.
    private func complete(model: String, messages: [[String: Any]]) async throws -> (String, [String])? {
        let first = try await chat(model: model, messages: messages, toolChoice: "auto")
        let calls = (first["tool_calls"] as? [[String: Any]]) ?? []
        let names = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let actions = Array(Set(names.filter { ["emergency_call_prompt", "find_tow"].contains($0) })).sorted()
        if let content = first["content"] as? String, !content.trimmingCharacters(in: .whitespaces).isEmpty {
            return (content, actions)
        }
        guard !calls.isEmpty else { return nil }
        var followUp = messages
        followUp.append(["role": "assistant", "content": NSNull(), "tool_calls": calls])
        for call in calls {
            followUp.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "",
                             "content": #"{"success": false, "pending": true, "app_action_requested": true, "performed": false}"#])
        }
        let second = try await chat(model: model, messages: followUp, toolChoice: "none")
        guard let content = second["content"] as? String, !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (content, actions)
    }

    private func chat(model: String, messages: [[String: Any]], toolChoice: String) async throws -> [String: Any] {
        // The team's settings: 384 output tokens (runtime/settings.py), no reasoning and temperature 0 (model profiles).
        let body: [String: Any] = ["model": model, "messages": messages, "max_tokens": 384, "temperature": 0,
                                   "reasoning": ["enabled": false, "exclude": true],
                                   "tools": Self.tools, "tool_choice": toolChoice]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("CrashSafe Pulse", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429,
           String(decoding: data.prefix(2000), as: UTF8.self).contains("free-models-per-day") {
            let reset = (http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? Self.resetHeader(in: data)).flatMap(Double.init)
            throw DailyLimitReached(resetsAt: reset.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now.addingTimeInterval(3600))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 200_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        else { throw URLError(.badServerResponse) }
        return message
    }

    /// The reply as it may be spoken: every sentence through the team's filter (their agent has no sentence cap),
    /// no ellipses (their Core forbids them), and short enough for one Corey clip. Nil when nothing survives.
    static func spoken(_ text: String, medicationQuestion: Bool) -> String? {
        let cleaned = text.replacingOccurrences(of: #"\s*(?:\.\.\.|…)\s*"#, with: ", ", options: .regularExpression)
        var kept: [String] = []
        for sentence in PulseSentenceFilter.sentences(cleaned) {
            guard let text = PulseSentenceFilter.filter(sentence, medicationQuestion: medicationQuestion).text,
                  !kept.contains(text), (kept + [text]).joined(separator: " ").count <= 1100 else { continue }
            kept.append(text)
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// OpenRouter puts the reset time (ms since 1970) in the error body's metadata.headers.
    private static func resetHeader(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let headers = ((json?["error"] as? [String: Any])?["metadata"] as? [String: Any])?["headers"] as? [String: Any]
        return headers?["X-RateLimit-Reset"] as? String
    }
}
