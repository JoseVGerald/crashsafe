import AVFoundation
import SwiftUI

/// Profile → Testing: pick the voice Pulse speaks with, hear it, and get a better one for free.
///
/// The free upgrade is Apple's own neural voices: "Premium" and "Enhanced" English voices download at
/// no cost in Settings (apps can use them once installed, but can't download them themselves). They
/// work offline, with the phone locked, and on silent, unlike cloud voices.
struct PulseVoiceCard: View {
    /// From the list read at launch; never read from iOS while drawing (slow on a phone).
    @State private var voices: [PulseVoice.Option] = PulseVoice.cachedOptions
    @State private var selected: String? = UserDefaults.standard.string(forKey: PulseVoice.defaultsKey)
    @State private var synthesizer = AVSpeechSynthesizer()
    @State private var showingHowTo = false
    @State private var clipPlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pulse's voice").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                if let voice = current {
                    StatusChip(text: voice.qualityLabel,
                               systemImage: voice.isNatural ? "sparkles" : "waveform",
                               tint: voice.isNatural ? Brand.greenInk : Brand.amberInk)
                }
            }
            Picker("Voice", selection: Binding(get: { current?.id ?? "" }, set: choose)) {
                ForEach(voices) { voice in
                    Text("\(voice.name) · \(voice.qualityLabel) · \(voice.language)").tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Brand.blueInk)
            HStack(spacing: Space.md) {
                Button("Hear it", systemImage: "play.circle") { preview() }
                Button("Get a better voice", systemImage: "arrow.down.circle") { showingHowTo = true }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.blueInk)
            .frame(minHeight: 44)
            Divider().overlay(Brand.stroke)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crash check-in voice").font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary)
                    Text("Pulse speaks as Corey (Cartesia) when online. \u{201C}Are you okay?\u{201D} is pre-recorded in Corey's voice, so the check-in sounds the same offline and locked.")
                        .font(.caption).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Hear", systemImage: "play.circle") { playCheckIn() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
            }
            if !voices.isEmpty && !voices.contains(where: \.isNatural) {
                Text("Only the basic voice is installed. A free Premium voice sounds far more natural, works offline and while locked.")
                    .font(.footnote).foregroundStyle(Brand.amberInk).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: Space.md)
        .task { await reload() }
        // Coming back from Settings with a new voice downloaded.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingHowTo) { howTo }
    }

    private var current: PulseVoice.Option? {
        voices.first { $0.id == selected } ?? voices.first
    }

    private func reload() async {
        await PulseVoice.reload()
        voices = PulseVoice.cachedOptions
        selected = UserDefaults.standard.string(forKey: PulseVoice.defaultsKey)
    }

    private func choose(_ identifier: String) {
        PulseVoice.choose(identifier)
        selected = identifier
        preview()
    }

    private func playCheckIn() {
        synthesizer.stopSpeaking(at: .immediate)
        guard let url = PulseVoiceClips.url(for: CrashResponseCenter.promptText(remaining: 30)) else { return }
        clipPlayer = try? AVAudioPlayer(contentsOf: url)
        clipPlayer?.play()
    }

    private func preview() {
        clipPlayer?.stop()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hi, I'm Pulse. You're doing 42 in a 30. Imagine a child running out 110 feet ahead.")
        utterance.voice = current.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    private var howTo: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Apple's best voices are free; iOS just doesn't install them until you ask. Pulse uses the best one you have, automatically.")
                        .foregroundStyle(Brand.textSecondary)
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(Brand.blueInk).frame(width: 20)
                            Text(step).foregroundStyle(Brand.textPrimary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Good picks: Zoe, Ava, Evan or Nathan (Premium). Each is a ~100–400 MB download over Wi-Fi.")
                        .font(.footnote).foregroundStyle(Brand.textSecondary)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Text("Open Settings").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.blue)
                }
                .padding(Space.md)
            }
            .background(BrandBackground())
            .navigationTitle("A better free voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHowTo = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private let steps = [
        "Open Settings → Accessibility → Read & Speak (called Spoken Content on older iOS).",
        "Tap Voices → English, then a voice marked Premium (or Enhanced).",
        "Tap the download button next to it and wait for it to finish.",
        "Come back here: the voice shows up in the list, and Pulse switches to it.",
    ]
}
