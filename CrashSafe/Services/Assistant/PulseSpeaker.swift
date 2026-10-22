import AVFoundation
import Foundation
import os

/// Where the Pulse backend is: an HTTPS `RAGEndpoint` in Info.plist, or the Mac running a Debug simulator.
/// API keys live only on that server (Backend/rag/.env), never in the app.
enum PulseBackend {
    static func endpoint() -> URL? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "RAGEndpoint") as? String,
           let url = URL(string: configured), url.scheme == "https" {
            return url
        }
        #if DEBUG && targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8787")
        #else
        return nil
        #endif
    }
}

/// Speaks for Pulse in its voice, Cartesia's "Corey", via the backend (`POST /v1/tts`). When the backend
/// can't be reached in time (offline, or no server configured on this phone), the best installed Apple
/// voice says it instead, so nothing Pulse needs to say is ever lost.
@MainActor
final class PulseSpeaker {
    private static let log = Logger(subsystem: "org.cac.crashsafe", category: "voice")
    private let endpoint: URL?
    private let session: URLSession
    private let isOnline: () -> Bool
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    /// Recent lines, so repeated coaching is instant and free.
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []

    init(endpoint: URL? = PulseBackend.endpoint(), isOnline: @escaping () -> Bool = { true }, timeout: TimeInterval = 3) {
        self.endpoint = endpoint
        self.isOnline = isOnline
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    var isSpeaking: Bool { (player?.isPlaying ?? false) || synthesizer.isSpeaking }

    /// Says `text`, interrupting anything Pulse was saying.
    func speak(_ text: String, rate: Float = 0.5) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        activateSession()
        task = Task { [weak self] in
            guard let self else { return }
            if let audio = await self.corey(text), !Task.isCancelled, let player = try? AVAudioPlayer(data: audio) {
                player.volume = 1
                player.play()
                self.player = player
                Self.log.info("Pulse spoke as Corey (\(audio.count, privacy: .public) bytes)")
                return
            }
            guard !Task.isCancelled else { return }
            Self.log.info("Pulse spoke with the Apple voice (Corey unavailable)")
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = PulseVoice.preferred()
            utterance.rate = rate
            self.synthesizer.speak(utterance)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func corey(_ text: String) async -> Data? {
        if let cached = cache[text] { return cached }
        guard let endpoint, isOnline(), text.count <= 1200 else { return nil }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["text": text])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("audio/") == true,
              data.count > 1000 else { return nil }
        cache[text] = data
        cacheOrder.append(text)
        if cacheOrder.count > 32 { cache[cacheOrder.removeFirst()] = nil }
        return data
    }

    private func activateSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
    }

    /// What to say from an assistant reply: the answer without its source list.
    nonisolated static func spokenPart(of reply: String) -> String {
        reply.components(separatedBy: "\n\nSources:").first?
            .replacingOccurrences(of: #"\s*\[[A-Z0-9_]+\]"#, with: "", options: .regularExpression) ?? reply
    }
}
