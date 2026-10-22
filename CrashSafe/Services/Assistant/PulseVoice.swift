import AVFoundation
import Foundation

/// Pulse's speaking voice: the most natural free voice on the device.
///
/// iOS ships "Premium" and "Enhanced" neural voices for free, but each one has to be downloaded once in
/// Settings → Accessibility → Read & Speak (Spoken Content) → Voices → English. Apps can use any
/// installed voice; they can't download one themselves. Without a download, iOS's compact default is used.
enum PulseVoice {
    static let defaultsKey = "pulse.voiceIdentifier"

    /// English voices, best first (premium, enhanced, then default; US English before other accents).
    static func available() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { rank($0) > rank($1) }
    }

    /// The voice Pulse speaks with: the one picked in Profile → Testing, else the best installed.
    static func preferred(defaults: UserDefaults = .standard) -> AVSpeechSynthesisVoice? {
        if let id = defaults.string(forKey: defaultsKey), let chosen = AVSpeechSynthesisVoice(identifier: id) {
            return chosen
        }
        return available().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func choose(_ voice: AVSpeechSynthesisVoice?, defaults: UserDefaults = .standard) {
        if let voice { defaults.set(voice.identifier, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// True when a Premium or Enhanced voice is installed (worth telling the user about if not).
    static var hasNaturalVoice: Bool {
        available().contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }

    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        let quality = switch voice.quality {
        case .premium: 300
        case .enhanced: 200
        default: 100
        }
        let accent = voice.language == "en-US" ? 20 : voice.language.hasPrefix("en-") ? 10 : 0
        // Siri-style voices sound most natural among the defaults.
        let siri = voice.identifier.lowercased().contains("siri") ? 5 : 0
        return quality + accent + siri
    }
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
