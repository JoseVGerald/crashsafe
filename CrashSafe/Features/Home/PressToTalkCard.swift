import Observation
import SwiftUI

/// Tap-to-talk with Pulse: the microphone (on-device speech recognition) → Pulse on the backend (the
/// team's Pulse agent) → spoken back as Corey. Follow-up questions keep the conversation.
@Observable
final class PressToTalkViewModel {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking(transcript: String)
        case answered(transcript: String, reply: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Buttons Pulse asked for with its reply; they act only when tapped.
    private(set) var offersEmergencyCall = false
    private(set) var offersTowSearch = false
    @ObservationIgnored private let assistant: any AssistantService
    @ObservationIgnored private let voice: any VoiceInputService
    @ObservationIgnored private let speaker: PulseSpeaker?
    @ObservationIgnored private let contextProvider: () -> AssistantContext
    @ObservationIgnored private var task: Task<Void, Never>?
    /// This conversation's turns, so "what about the other driver?" makes sense to Pulse.
    @ObservationIgnored private var history: [ChatMessage] = []
    @ObservationIgnored private var conversationID = UUID().uuidString

    init(assistant: any AssistantService, voice: any VoiceInputService, speaker: PulseSpeaker? = nil,
         contextProvider: @escaping () -> AssistantContext) {
        self.assistant = assistant
        self.voice = voice
        self.speaker = speaker
        self.contextProvider = contextProvider
    }

    var isListening: Bool { phase == .listening }

    func pressBegan() {
        task?.cancel()
        speaker?.stop()
        phase = .listening
        task = Task {
            do {
                try await voice.start()
            } catch {
                voice.cancel()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func pressEnded() {
        guard phase == .listening else { return }
        phase = .thinking(transcript: voice.partial)
        let starting = task
        task = Task {
            await starting?.value
            do {
                let transcript = try await voice.finish()
                phase = .thinking(transcript: transcript)
                history.append(ChatMessage(role: .user, text: transcript))
                var context = contextProvider()
                context.conversationID = conversationID
                let reply = (try? await assistant.reply(to: Array(history.suffix(12)), context: context))
                    ?? "I couldn't answer that right now."
                guard !Task.isCancelled else { return }
                history.append(ChatMessage(role: .assistant, text: reply))
                offersEmergencyCall = assistant.requestedActions.contains("emergency_call_prompt")
                offersTowSearch = assistant.requestedActions.contains("find_tow")
                phase = .answered(transcript: transcript, reply: reply)
                speaker?.speak(PulseSpeaker.spokenPart(of: reply))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        task?.cancel()
        voice.cancel()
        speaker?.stop()
        history = []
        conversationID = UUID().uuidString
        offersEmergencyCall = false
        offersTowSearch = false
        phase = .idle
    }
}

/// Tap the mic, speak, tap again. Centered like a big, easy target for a stressed driver.
struct PressToTalkCard: View {
    @State var viewModel: PressToTalkViewModel
    var onOpenChat: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Space.md) {
            orb
                .padding(.top, Space.sm)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }

            if case .answered(_, let reply) = viewModel.phase {
                Text(reply)
                    .font(.callout)
                    .foregroundStyle(Brand.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { viewModel.reset() }
                offers
            }

            Button(action: onOpenChat) {
                Label("Open chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)
    }

    /// What Pulse asked the app to offer (the agent's tools): shown, never done for the person.
    @ViewBuilder private var offers: some View {
        if viewModel.offersEmergencyCall {
            Button {
                if let url = URL(string: "tel://911") { openURL(url) }
            } label: {
                Label("Call 911", systemImage: "phone.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        if viewModel.offersTowSearch {
            Button {
                if let url = URL(string: "maps://?q=tow%20truck") { openURL(url) }
            } label: {
                Label("Find a tow nearby", systemImage: "truck.box.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private var orb: some View {
        Button(action: toggle) {
            ZStack {
                PulseRings(color: Brand.blueInk, count: 3, active: viewModel.isListening)
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Brand.surface)
                    .frame(width: 124, height: 124)
                    .overlay(Circle().strokeBorder(Brand.stroke))
                PulseVoiceFace(mood: mood, diameter: 96)
            }
            .scaleEffect(viewModel.isListening ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.isListening)
            .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.isListening)
        .accessibilityLabel(viewModel.isListening ? "Stop and send" : "Talk to Pulse")
        .accessibilityHint(viewModel.isListening ? "Sends what you said." : "Starts listening.")
    }

    private var mood: PulseOrbMood {
        switch viewModel.phase {
        case .idle, .answered, .failed: .idle
        case .listening: .listening
        case .thinking: .thinking
        }
    }

    private func toggle() {
        if viewModel.isListening {
            viewModel.pressEnded()
        } else {
            viewModel.pressBegan()
        }
    }

    private var title: String {
        switch viewModel.phase {
        case .idle: "Tap to talk"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .answered: "Pulse"
        case .failed: "Tap to talk"
        }
    }

    private var subtitle: String {
        switch viewModel.phase {
        case .idle: "Ask for help or get road support"
        case .listening: "Tap again when you're done."
        case .thinking(let transcript), .answered(let transcript, _): transcript.isEmpty ? "…" : "“\(transcript)”"
        case .failed(let message): message
        }
    }
}
