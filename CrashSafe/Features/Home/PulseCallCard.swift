import Observation
import SwiftUI

/// A phone call with Pulse: tap once and just talk. Pulse listens until you pause, answers out loud as Corey,
/// then listens again on its own, back and forth until you hang up. No button presses between turns.
/// (Pulse doesn't listen while it is talking; tap the orb to cut it off and speak.) Corey plays in the normal
/// full-quality playback mode, and the mic opens only for your turn, as with the chat's voice questions.
@Observable
final class PulseCallViewModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case thinking(heard: String)
        case speaking(heard: String, reply: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What Pulse said last, kept on screen while it listens for the next turn.
    private(set) var lastReply = ""
    private(set) var startedAt: Date?
    /// Buttons Pulse asked for with its reply; they act only when tapped.
    private(set) var offersEmergencyCall = false
    private(set) var offersTowSearch = false

    static let greeting = "I'm here. What's going on?"

    @ObservationIgnored private let assistant: any AssistantService
    @ObservationIgnored let voice: any VoiceInputService
    @ObservationIgnored private let speaker: PulseSpeaker?
    @ObservationIgnored private let contextProvider: () -> AssistantContext
    @ObservationIgnored private var call: Task<Void, Never>?
    /// This call's turns, so "what about the other driver?" makes sense to Pulse.
    @ObservationIgnored private(set) var history: [ChatMessage] = []
    @ObservationIgnored private var conversationID = UUID().uuidString

    init(assistant: any AssistantService, voice: any VoiceInputService, speaker: PulseSpeaker? = nil,
         contextProvider: @escaping () -> AssistantContext) {
        self.assistant = assistant
        self.voice = voice
        self.speaker = speaker
        self.contextProvider = contextProvider
    }

    var inCall: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    func startCall() {
        guard !inCall else { return }
        history = []
        lastReply = ""
        offersEmergencyCall = false
        offersTowSearch = false
        conversationID = UUID().uuidString
        startedAt = .now
        phase = .connecting
        call = Task { await run() }
    }

    func endCall() {
        call?.cancel()
        call = nil
        voice.cancel()
        speaker?.stop()
        startedAt = nil
        phase = .idle
    }

    /// Cuts Pulse off mid-sentence; the call goes straight back to listening.
    func interrupt() {
        if case .speaking = phase { speaker?.stop() }
    }

    private func run() async {
        await say(Self.greeting, heard: "")
        while !Task.isCancelled {
            phase = .listening
            let heard: String
            do {
                heard = try await voice.listen()  // Ends when you pause.
            } catch is CancellationError {
                return
            } catch SpeechVoiceInput.Failure.heardNothing {
                continue  // Silence: keep the line open, like a call.
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
                return
            }
            guard !Task.isCancelled else { return }
            history.append(ChatMessage(role: .user, text: heard))
            phase = .thinking(heard: heard)
            var context = contextProvider()
            context.conversationID = conversationID
            let reply = (try? await assistant.reply(to: Array(history.suffix(40)), context: context))
                ?? "Sorry, I didn't get an answer just then. Could you say that again?"
            guard !Task.isCancelled else { return }
            offersEmergencyCall = offersEmergencyCall || assistant.requestedActions.contains("emergency_call_prompt")
            offersTowSearch = offersTowSearch || assistant.requestedActions.contains("find_tow")
            await say(reply, heard: heard)
        }
    }

    private func say(_ reply: String, heard: String) async {
        history.append(ChatMessage(role: .assistant, text: reply))
        lastReply = PulseSpeaker.spokenPart(of: reply)
        phase = .speaking(heard: heard, reply: lastReply)
        await speaker?.say(lastReply)
    }

    private func fail(_ message: String) {
        voice.cancel()
        speaker?.stop()
        startedAt = nil
        phase = .failed(message)
    }
}

/// The call card on Home: one tap starts a hands-free call with Pulse; End call hangs up.
struct PulseCallCard: View {
    @State var viewModel: PulseCallViewModel
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
                    .lineLimit(3)
                    .contentTransition(.opacity)
                if let startedAt = viewModel.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                        Text(Duration.seconds(timeline.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .accessibilityLabel("Call time")
                }
            }

            if viewModel.inCall, !viewModel.lastReply.isEmpty {
                Text(viewModel.lastReply)
                    .font(.callout)
                    .foregroundStyle(Brand.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Brand.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            offers

            if viewModel.inCall {
                Button(role: .destructive) {
                    viewModel.endCall()
                } label: {
                    Label("End call", systemImage: "phone.down.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.redInk)
            } else {
                Button(action: onOpenChat) {
                    Label("Open chat", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.blueInk)
                        .frame(minHeight: 44)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)
        .onDisappear { viewModel.endCall() }
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
        Button(action: tapOrb) {
            ZStack {
                PulseRings(color: mood.ringTint, count: 3, active: viewModel.inCall && mood != .thinking)
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Brand.surface)
                    .frame(width: 124, height: 124)
                    .overlay(Circle().strokeBorder(Brand.stroke))
                PulseVoiceFace(mood: mood, diameter: 96, badge: "phone.fill")
            }
            .scaleEffect(mood == .listening ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: mood)
            .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.inCall)
        .accessibilityLabel(orbLabel)
        .accessibilityHint(viewModel.inCall ? "" : "Starts a hands-free call. Pulse answers out loud.")
    }

    private var mood: PulseOrbMood {
        switch viewModel.phase {
        case .idle, .failed: .idle
        case .listening: .listening
        case .connecting, .thinking: .thinking
        case .speaking: .speaking
        }
    }

    private func tapOrb() {
        switch viewModel.phase {
        case .idle, .failed: viewModel.startCall()
        case .speaking: viewModel.interrupt()
        default: break
        }
    }

    private var orbLabel: String {
        switch viewModel.phase {
        case .idle, .failed: "Call Pulse"
        case .speaking: "Interrupt Pulse"
        default: "Pulse call in progress"
        }
    }

    private var title: String {
        switch viewModel.phase {
        case .idle: "Call Pulse"
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Pulse"
        case .failed: "Call Pulse"
        }
    }

    private var subtitle: String {
        switch viewModel.phase {
        case .idle: "Tap to talk hands-free. Pulse answers out loud."
        case .connecting: "Starting the call"
        case .listening: viewModel.voice.partial.isEmpty ? "Go ahead, I'm listening." : "“\(viewModel.voice.partial)”"
        case .thinking(let heard): "“\(heard)”"
        case .speaking(let heard, _): heard.isEmpty ? "Tap me to interrupt" : "“\(heard)” · tap me to interrupt"
        case .failed(let message): message
        }
    }
}
