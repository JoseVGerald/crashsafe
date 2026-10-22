import AVFoundation
import Foundation

/// Pulse's speaking voice: the most natural free voice on the device.
///
/// iOS ships "Premium" and "Enhanced" neural voices for free, but each one has to be downloaded once in
/// Settings → Accessibility → Read & Speak (Spoken Content) → Voices → English. Apps can use any
/// installed voice; they can't download one themselves. Without a download, iOS's compact default is used.
enum PulseVoice {
    static let defaultsKey = "pulse.voiceIdentifier"

    /// One installed voice, as plain values (safe to hand between threads).
    nonisolated struct Option: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var language: String
        /// 300 Premium, 200 Enhanced, 100 standard.
        var qualityRank: Int
        /// Quality, then US English, then other English accents, then Siri-style voices.
        var rank: Int

        var qualityLabel: String { qualityRank >= 300 ? "Premium" : qualityRank >= 200 ? "Enhanced" : "Standard" }
        var isNatural: Bool { qualityRank >= 200 }
    }

    /// Listing the installed voices is slow on a phone (iOS asks its speech service about every voice,
    /// a visible pause), so the list is read once, off the main thread at launch, and reused.
    private static var cache: [Option]?

    /// English voices, best first. Reads the list now only if launch hasn't already.
    static var options: [Option] {
        if let cache { return cache }
        let scanned = scan()
        cache = scanned
        return scanned
    }

    /// What's cached so far, without reading anything (for a screen's first frame).
    static var cachedOptions: [Option] { cache ?? [] }

    /// Re-reads the list off the main thread: at launch, and back from Settings (where voices download).
    static func reload() async {
        cache = await scanInBackground()
    }

    @concurrent nonisolated private static func scanInBackground() async -> [Option] { scan() }

    nonisolated static func scan() -> [Option] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: 300
                case .enhanced: 200
                default: 100
                }
                let accent = voice.language == "en-US" ? 20 : voice.language.hasPrefix("en-") ? 10 : 0
                // Siri-style voices sound most natural among the defaults.
                let siri = voice.identifier.lowercased().contains("siri") ? 5 : 0
                return Option(id: voice.identifier, name: voice.name, language: voice.language,
                              qualityRank: quality, rank: quality + accent + siri)
            }
            .sorted { $0.rank > $1.rank }
    }

    /// The voice Pulse speaks with: the one picked in Profile → Testing, else the best installed.
    static func preferred(defaults: UserDefaults = .standard) -> AVSpeechSynthesisVoice? {
        if let id = defaults.string(forKey: defaultsKey), let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        return options.first.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func choose(_ id: String?, defaults: UserDefaults = .standard) {
        if let id { defaults.set(id, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// True when a Premium or Enhanced voice is installed (worth telling the user about if not).
    static var hasNaturalVoice: Bool { options.contains(where: \.isNatural) }
}

/// The crash check-in's fixed lines, pre-recorded in a natural neural voice (Kokoro-82M, Apache 2.0,
/// rendered by Tools/Voice/render_prompts.py). They play offline, locked and on silent, and sound human
/// even when no Premium voice has been downloaded; anything else Pulse says uses `PulseVoice`.
enum PulseVoiceClips {
    static let lines: [String: String] = [
        CrashResponseCenter.promptText(remaining: 30): "checkin-tap-ok",
        CrashResponseCenter.promptText(remaining: 10): "checkin-10s",
        CrashResponseCenter.promptText(remaining: 5): "checkin-5s",
        CrashResponseCenter.okLine: "checkin-glad",
        CrashResponseCenter.helpLine: "checkin-help",
    ]

    static func url(for text: String, bundle: Bundle = .main) -> URL? {
        lines[text].flatMap { bundle.url(forResource: $0, withExtension: "m4a") }
    }
}
