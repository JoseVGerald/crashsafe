import AVFoundation
import Foundation
import os

/// Where the Pulse backend is: an HTTPS `RAGEndpoint` in Info.plist; in Debug, the Mac itself (simulator)
/// or, on a phone, the Mac over Wi-Fi (`PULSE_LAN_HOST` + `PULSE_LAN_TOKEN` build settings, from
/// `Backend/rag/.env`; the backend runs with `serve --lan`). API keys live only on the server, never here.
nonisolated enum PulseBackend {
    static func endpoint(bundle: Bundle = .main) -> URL? {
        if let configured = bundle.object(forInfoDictionaryKey: "RAGEndpoint") as? String,
           let url = URL(string: configured), url.scheme == "https" {
            return url
        }
        #if DEBUG
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8787")
        #else
        guard let host = info("PulseLANHost", bundle), token(bundle: bundle) != nil else { return nil }
        return URL(string: "http://\(host):8787")
        #endif
        #else
        return nil
        #endif
    }

    /// Lets this phone past the backend's Wi-Fi check (the Mac itself needs none).
    static func token(bundle: Bundle = .main) -> String? { info("PulseLANToken", bundle) }

    static func authorize(_ request: inout URLRequest) {
        if let token = token() { request.setValue(token, forHTTPHeaderField: "X-Pulse-Token") }
    }

    private static func info(_ key: String, _ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

/// Speaks for Pulse in its voice, Cartesia's "Corey": straight from Cartesia when this build has a Cartesia key
/// (`PulseKeys`; the backup key takes over if the main one is refused), otherwise through the backend
/// (`POST /v1/tts`). When neither answers in time (offline, or nothing configured), the best installed Apple
/// voice says it instead, so nothing Pulse needs to say is lost. To start sooner, the first sentence is
/// voiced on its own and plays while the rest is still being fetched.
@MainActor
final class PulseSpeaker {
    private static let log = Logger(subsystem: "org.cac.crashsafe", category: "voice")
    static let corey = "630ed21c-2c5c-41cf-9d82-10a7fd668370"  // Cartesia "Corey - Supportive Buddy"
    private let endpoint: URL?
    private let cartesiaKeys: [String]
    /// The key that answered last, tried first next time.
    private var workingKey = 0
    private let session: URLSession
    private let isOnline: () -> Bool
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    /// Recent lines, so repeated coaching is instant and free.
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []

    init(endpoint: URL? = PulseBackend.endpoint(), cartesiaKey: String? = PulseKeys.cartesia(),
         backupKey: String? = PulseKeys.cartesiaBackup(),
         isOnline: @escaping () -> Bool = { true }, timeout: TimeInterval = 4, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.cartesiaKeys = [cartesiaKey, backupKey].compactMap { $0 }
        self.isOnline = isOnline
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    var isSpeaking: Bool { (player?.isPlaying ?? false) || synthesizer.isSpeaking }

    /// Says `text`, interrupting anything Pulse was saying.
    func speak(_ text: String, rate: Float = 0.5) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        activateSession()
        task = Task { [weak self] in await self?.play(text, rate: rate) }
    }

    /// Says `text` and returns once Pulse has finished saying it (or was stopped): turn-taking in a call.
    func say(_ text: String, rate: Float = 0.5) async {
        speak(text, rate: rate)
        await task?.value
    }

    /// Fetches a line ahead of time (e.g. the call greeting), so saying it later is instant.
    func prefetch(_ text: String) {
        Task { _ = await corey(text) }
    }

    private func play(_ text: String, rate: Float) async {
        // The first sentence alone comes back sooner; the rest is fetched while it plays.
        let sentences = PulseSentenceFilter.sentences(text)
        let first = sentences.count > 1 ? sentences[0] : text
        let rest = sentences.count > 1 ? sentences.dropFirst().joined(separator: " ") : ""
        let later = rest.isEmpty ? nil : Task { await corey(rest) }
        if let audio = await corey(first), !Task.isCancelled {
            await playClip(audio)
            if let later, let audio = await later.value, !Task.isCancelled {
                await playClip(audio)
                return
            }
            guard !rest.isEmpty, !Task.isCancelled else { return }
            return await sayWithAppleVoice(rest, rate: rate)
        }
        later?.cancel()
        guard !Task.isCancelled else { return }
        await sayWithAppleVoice(text, rate: rate)
    }

    private func playClip(_ audio: Data) async {
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        player.volume = 1
        player.play()
        self.player = player
        Self.log.info("Pulse spoke as Corey (\(audio.count, privacy: .public) bytes)")
        while player.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func sayWithAppleVoice(_ text: String, rate: Float) async {
        Self.log.info("Pulse spoke with the Apple voice (Corey unavailable)")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = PulseVoice.preferred()
        utterance.rate = rate
        synthesizer.speak(utterance)
        try? await Task.sleep(for: .milliseconds(200))
        while synthesizer.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func corey(_ text: String) async -> Data? {
        if let cached = cache[text] { return cached }
        guard isOnline(), text.count <= 1200 else { return nil }
        // Cartesia keys in order, starting with the one that worked last; then the backend.
        let keys = cartesiaKeys.indices.map { (workingKey + $0) % cartesiaKeys.count }
        for index in keys.isEmpty ? [-1] : keys {
            guard let request = coreyRequest(text, key: index >= 0 ? cartesiaKeys[index] : nil),
                  let (data, response) = try? await session.data(for: request) else { continue }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("audio/") == true,
                  data.count > 1000 else {
                Self.log.info("Corey request refused (\((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)); trying the next key")
                continue
            }
            if index >= 0 { workingKey = index }
            cache[text] = data
            cacheOrder.append(text)
            if cacheOrder.count > 32 { cache[cacheOrder.removeFirst()] = nil }
            return data
        }
        return nil
    }

    /// Cartesia itself when this build has a key, else the backend.
    private func coreyRequest(_ text: String, key: String?) -> URLRequest? {
        var request: URLRequest
        if let cartesiaKey = key {
            request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
            request.setValue(cartesiaKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("2025-04-16", forHTTPHeaderField: "Cartesia-Version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model_id": "sonic-3", "transcript": text, "language": "en",
                "voice": ["mode": "id", "id": Self.corey],
                "output_format": ["container": "mp3", "sample_rate": 44100, "bit_rate": 128000]])
        } else if let endpoint {
            request = URLRequest(url: endpoint.appendingPathComponent("v1/tts"))
            PulseBackend.authorize(&request)
            request.httpBody = try? JSONEncoder().encode(["text": text])
        } else {
            return nil
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
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

