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
    /// Muted: the mic stays off and Pulse hears nothing until you unmute.
    private(set) var isMuted = false
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

    /// Fetches the greeting's audio ahead of time, so a call starts talking at once.
    func prepare() {
        speaker?.prefetch(Self.greeting)
    }

    func startCall() {
        guard !inCall else { return }
        history = []
        lastReply = ""
        isMuted = false
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
        isMuted = false
        phase = .idle
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { voice.cancel() }  // Close the mic now, mid-sentence if need be.
    }

    /// Cuts Pulse off mid-sentence; the call goes straight back to listening.
    func interrupt() {
        if case .speaking = phase { speaker?.stop() }
    }

    private func run() async {
        await say(Self.greeting, heard: "")
        while !Task.isCancelled {
            phase = .listening
            if isMuted {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let heard: String
            do {
                heard = try await voice.listen()  // Ends when you pause.
            } catch is CancellationError {
                return
            } catch SpeechVoiceInput.Failure.heardNothing {
                continue  // Silence (or muted): keep the line open, like a call.
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
                return
            }
            guard !Task.isCancelled, !isMuted else { continue }
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
        isMuted = false
        phase = .failed(message)
    }
}

/// The card on Home: tap to call Pulse. The call itself opens full screen (`PulseCallScreen`).
struct PulseCallCard: View {
    @State var viewModel: PulseCallViewModel
    var onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            Button(action: viewModel.startCall) {
                ZStack {
                    Circle()
                        .fill(Brand.surface)
                        .frame(width: 124, height: 124)
                        .overlay(Circle().strokeBorder(Brand.stroke))
                    PulseVoiceFace(mood: .idle, diameter: 96, badge: "phone.fill")
                }
                .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.inCall)
            .accessibilityLabel("Call Pulse")
            .accessibilityHint("Starts a hands-free call. Pulse answers out loud.")
            .padding(.top, Space.sm)

            VStack(spacing: 4) {
                Text("Call Pulse")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
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
        .onAppear { viewModel.prepare() }
        .fullScreenCover(isPresented: Binding(get: { viewModel.inCall }, set: { if !$0 { viewModel.endCall() } })) {
            PulseCallScreen(viewModel: viewModel)
        }
    }

    private var subtitle: String {
        if case .failed(let message) = viewModel.phase { return message }
        return "Tap to talk hands-free. Pulse answers out loud."
    }
}

/// The call, laid out like the iPhone's own call screen: who you're talking to and the call time at the top,
/// Pulse in the middle with live captions, and round Mute and End buttons at the bottom.
struct PulseCallScreen: View {
    let viewModel: PulseCallViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Pulse")
                    .font(.largeTitle.weight(.regular))
                    .foregroundStyle(.white)
                status
            }
            .padding(.top, 56)

            Spacer(minLength: 24)

            Button(action: viewModel.interrupt) {
                ZStack {
                    PulseRings(color: mood.ringTint, count: 3, active: mood == .listening || mood == .speaking)
                        .frame(width: 150, height: 150)
                    PulseVoiceFace(mood: mood, diameter: 150, showsMicBadge: false)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mood == .speaking ? "Interrupt Pulse" : "Pulse")

            caption
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .frame(maxHeight: 220, alignment: .top)

            Spacer(minLength: 16)

            offers
                .padding(.horizontal, 28)
                .padding(.bottom, 24)

            HStack(spacing: 72) {
                CallButton(title: viewModel.isMuted ? "unmute" : "mute", systemImage: "mic.slash.fill",
                           isOn: viewModel.isMuted, tint: nil, action: viewModel.toggleMute)
                CallButton(title: "end", systemImage: "phone.down.fill", isOn: false, tint: .red,
                           action: viewModel.endCall)
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: viewModel.phase)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isMuted)
    }

    @ViewBuilder private var status: some View {
        if let startedAt = viewModel.startedAt, viewModel.phase != .connecting {
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                Text(Duration.seconds(timeline.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Call time")
        } else {
            Text("calling…")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder private var caption: some View {
        VStack(spacing: 14) {
            Text(stateLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(viewModel.isMuted ? Color.orange : .white.opacity(0.6))
                .textCase(.uppercase)
            if let text = captionText, !text.isEmpty {
                Text(text)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
        }
    }

    /// What Pulse asked the app to offer (the agent's tools): shown, never done for the person.
    @ViewBuilder private var offers: some View {
        VStack(spacing: 10) {
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
                .tint(.white)
            }
        }
    }

    private var mood: PulseOrbMood {
        switch viewModel.phase {
        case .idle, .failed: .idle
        case .listening: viewModel.isMuted ? .idle : .listening
        case .connecting, .thinking: .thinking
        case .speaking: .speaking
        }
    }

    private var stateLine: String {
        if viewModel.isMuted { return "Muted" }
        switch viewModel.phase {
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Pulse · tap to interrupt"
        case .idle, .failed: return ""
        }
    }

    private var captionText: String? {
        switch viewModel.phase {
        case .listening:
            let partial = viewModel.voice.partial
            return viewModel.isMuted || partial.isEmpty ? viewModel.lastReply : "“\(partial)”"
        case .thinking(let heard): return "“\(heard)”"
        case .speaking(_, let reply): return reply
        default: return nil
        }
    }
}

/// A round button like the iPhone call screen's: icon in a circle, label underneath.
private struct CallButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isOn ? Color.black : .white)
                    .frame(width: 76, height: 76)
                    .background(tint ?? (isOn ? Color.white : Color.white.opacity(0.18)), in: Circle())
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .accessibilityLabel(title.capitalized)
    }
}
