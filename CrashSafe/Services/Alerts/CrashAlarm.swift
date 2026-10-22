import AVFoundation
import Foundation
import UIKit

/// The voice and siren side of the crash check-in.
@MainActor
protocol CrashAlarm: AnyObject {
    /// Speaks to the driver (works with the phone locked and the ringer switch on silent).
    func say(_ text: String)
    /// A loud two-tone siren on a loop, to get the attention of anyone nearby.
    func startSiren()
    func stopSiren()
    var isSirenOn: Bool { get }
    /// Stops speech and siren.
    func stopAll()
}

/// `AVSpeechSynthesizer` for the "Are you okay?" prompts and an `AVAudioEngine` tone for the siren,
/// on a `.playback` audio session (plays on silent; the app's `audio` background mode keeps it going locked).
@MainActor
final class SpeakerCrashAlarm: CrashAlarm {
    private let synthesizer = AVSpeechSynthesizer()
    /// Plays the pre-recorded check-in lines (`PulseVoiceClips`).
    private var clipPlayer: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isSirenOn = false

    func say(_ text: String) {
        activateSession()
        synthesizer.stopSpeaking(at: .immediate)
        clipPlayer?.stop()
        if let url = PulseVoiceClips.url(for: text), let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 1
            player.play()
            clipPlayer = player
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = PulseVoice.preferred()
            utterance.rate = 0.48
            utterance.volume = 1
            utterance.prefersAssistiveTechnologySettings = false
            synthesizer.speak(utterance)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func startSiren() {
        guard !isSirenOn else { return }
        activateSession()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = Self.sirenBuffer(format: format) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
        isSirenOn = true
    }

    func stopSiren() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isSirenOn = false
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        clipPlayer?.stop()
        stopSiren()
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// One 1.6 s cycle sweeping 650 → 1,300 Hz and back (a "wail"), slightly clipped for loudness.
    static func sirenBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 1.6)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let sweep = 0.5 - 0.5 * cos(2 * .pi * t / 1.6) // 0 → 1 → 0
            let frequency = 650 + 650 * sweep
            phase += 2 * .pi * frequency / rate
            let tone = sin(phase) + 0.3 * sin(2 * phase)
            samples[i] = Float(max(-0.95, min(0.95, tone * 0.9)))
        }
        return buffer
    }
}

/// Starts the 911 call. iOS always asks the person to confirm a call an app starts (and doesn't let
/// apps call silently), so this brings up the system "Call 911" prompt for the driver or a bystander.
@MainActor
protocol EmergencyDialer: AnyObject {
    func call911()
}

@MainActor
final class SystemEmergencyDialer: EmergencyDialer {
    func call911() {
        guard let url = URL(string: "tel://911") else { return }
        UIApplication.shared.open(url)
    }
}
