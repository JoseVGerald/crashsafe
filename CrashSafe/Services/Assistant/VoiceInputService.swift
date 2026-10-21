import Foundation

/// Speech-to-text for the assistant's mic button.
///
/// AI TEAM: back this with `SpeechAnalyzer` / `SFSpeechRecognizer` (on-device works offline).
/// Remember to add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
protocol VoiceInputService: AnyObject {
    /// Listens until the speaker pauses and returns the transcript.
    func listen() async throws -> String
}

/// Pretends to listen, then returns a canned phrase.
final class MockVoiceInputService: VoiceInputService {
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
