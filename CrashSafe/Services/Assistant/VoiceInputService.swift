import Foundation

/// Speech-to-text for Pulse's mic buttons (`SpeechVoiceInput` in the app).
protocol VoiceInputService: AnyObject {
    /// Listens until the speaker pauses and returns the transcript.
    func listen() async throws -> String
    /// Tap-to-talk: start listening…
    func start() async throws
    /// …and stop, returning what was said.
    func finish() async throws -> String
    func cancel()
    /// Words heard so far (live, while listening).
    var partial: String { get }
}

/// Tests and previews only: pretends to listen, then returns a canned phrase.
final class MockVoiceInputService: VoiceInputService {
    private(set) var partial = ""
    func start() async throws {}
    func finish() async throws -> String { try await listen() }
    func cancel() {}

    private let phrases = [
        "I think I'm okay but my car won't start.",
        "What should I tell my insurance?",
        "I'm kind of shaking right now.",
        "What photos should I take?",
    ]
    private var index = 0

    func listen() async throws -> String {
        try await Task.sleep(for: .seconds(1.5))
        defer { index = (index + 1) % phrases.count }
        return phrases[index]
    }
}
