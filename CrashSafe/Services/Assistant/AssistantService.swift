import Foundation

/// Why the assistant was opened — changes how it greets the driver.
enum AssistantScenario: Equatable, Sendable {
    case general
    /// Driver answered the check-in ("I'm OK") — the conscious path.
    case afterCrash(CheckInOutcome)
}

/// Everything the assistant may use to tailor answers. Built from the on-device profile.
struct AssistantContext: Sendable {
    var userName: String
    var isOnline: Bool
    var scenario: AssistantScenario
    var carDescription: String
    var insurer: String
    var medicalNotes: String
    var familyContactNames: [String]
    var currentTrip: String?
}

/// The conscious-path assistant.
///
/// AI TEAM: implement `CloudAssistantService` (online, calls *our* server — never put
/// API keys in the app) and `OnDeviceAssistantService` (Apple Foundation Models + trip pack),
/// then pick between them in `AppEnvironment` based on `ConnectivityMonitor.isOnline`.
protocol AssistantService: AnyObject {
    /// First message shown when the chat opens.
    func greeting(for context: AssistantContext) -> String
    /// Reply to the latest user message given the full history.
    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String
}

/// Returns canned, safety-first replies based on simple keywords.
final class MockAssistantService: AssistantService {
    private let latency: Duration

    init(latency: Duration = .milliseconds(900)) {
        self.latency = latency
    }

    func greeting(for context: AssistantContext) -> String {
        let name = context.userName.split(separator: " ").first.map(String.init) ?? "there"
        switch context.scenario {
        case .general:
            return "Hi \(name). I'm here if anything happens on the road. Ask me about towing, insurance, or what to do after a crash."
        case .afterCrash(.ok):
            return "I'm glad you're responding, \(name). Take a slow breath. First things first: are you somewhere safe, away from traffic? If anyone is hurt, call 911 now."
        case .afterCrash(.needsHelp):
            return "Help comes first. If you haven't already, call 911 — the button is at the top of this screen. I've let your family contacts know. Tell me what's happening and I'll stay with you."
        case .afterCrash(.noResponse):
            return "You didn't respond, so I alerted your family contacts. If you're awake now: are you hurt? If yes, call 911 first."
        }
    }

    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        try await Task.sleep(for: latency)
        let last = history.last(where: { $0.role == .user })?.text.lowercased() ?? ""
        let suffix = context.isOnline ? "" : "\n\n(Offline — using your saved trip pack.)"

        if last.containsAny("hurt", "pain", "bleed", "injur", "dizzy") {
            return "If you or anyone else is hurt, call 911 now — that comes before anything else. Don't move someone with neck or back pain unless there's fire or traffic danger." + suffix
        }
        if last.containsAny("tow", "stuck", "won't start", "wont start") {
            return "I found tow companies near you in your trip pack. I'd suggest calling the closest one yourself and asking for the total price before they hook up your car. Want me to show the list?" + suffix
        }
        if last.containsAny("insur", "claim") {
            let insurer = context.insurer.isEmpty ? "your insurer" : context.insurer
            return "Report it to \(insurer) promptly — most policies require it. Stick to facts: time, place, weather, what you saw. Don't guess or admit fault at the scene. (Not legal advice.)" + suffix
        }
        if last.containsAny("photo", "picture", "document", "record") {
            return "Once you're safe: photograph all vehicles from each corner, license plates, the road, signs, and anything like rain or darkness. Swap names, phone numbers, and insurance with the other driver." + suffix
        }
        if last.containsAny("scared", "panic", "shaking", "anxious", "nervous") {
            return "That's a normal reaction. Let's slow down together: breathe in for 4, hold for 4, out for 6. You don't need to decide anything right this second." + suffix
        }
        return "Got it. Here's the order I'd go in: 1) make sure everyone is safe, 2) call 911 if anyone's hurt, 3) document the scene, 4) arrange a tow, 5) notify your insurer. Which one should we start with?" + suffix
    }
}

private extension String {
    func containsAny(_ needles: String...) -> Bool {
        needles.contains { contains($0) }
    }
}
