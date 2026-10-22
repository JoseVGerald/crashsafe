import Observation
import SwiftUI

/// Tap-to-talk with Pulse. Proof of concept: the voice and AI services are the mocks for now.
@Observable
final class PressToTalkViewModel {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking(transcript: String)
        case answered(transcript: String, reply: String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let assistant: any AssistantService
    @ObservationIgnored private let contextProvider: () -> AssistantContext
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var promptIndex = 0

    private let prompts = [
        "Is it safe to drive right now?",
        "What do I do if I get a flat tire?",
        "What should I tell my insurance after a crash?",
        "I'm feeling nervous about this drive.",
    ]

    init(assistant: any AssistantService, contextProvider: @escaping () -> AssistantContext) {
        self.assistant = assistant
        self.contextProvider = contextProvider
    }

    var isListening: Bool { phase == .listening }

    func pressBegan() {
        task?.cancel()
        phase = .listening
    }

    func pressEnded() {
        guard phase == .listening else { return }
        let transcript = prompts[promptIndex % prompts.count]
        promptIndex += 1
        phase = .thinking(transcript: transcript)
        task = Task {
            let history = [ChatMessage(role: .user, text: transcript)]
            let reply = (try? await assistant.reply(to: history, context: contextProvider()))
                ?? "I couldn't answer that right now."
            guard !Task.isCancelled else { return }
            phase = .answered(transcript: transcript, reply: reply)
        }
    }

    func reset() {
        task?.cancel()
        phase = .idle
    }
}

/// Tap the mic, speak, tap again. Centered like a big, easy target for a stressed driver.
struct PressToTalkCard: View {
    @State var viewModel: PressToTalkViewModel
    var onOpenChat: () -> Void

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

    private var orb: some View {
        Button(action: toggle) {
            ZStack {
                PulseRings(color: Brand.blueInk, count: 3, active: viewModel.isListening)
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Brand.surface)
                    .frame(width: 124, height: 124)
                    .overlay(Circle().strokeBorder(Brand.stroke))
                Circle()
                    .fill(Brand.blue)
                    .frame(width: 96, height: 96)
                if viewModel.isListening {
                    WaveformBars()
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 30)
                } else if case .thinking = viewModel.phase {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
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
        }
    }

    private var subtitle: String {
        switch viewModel.phase {
        case .idle: "Ask for help or get road support"
        case .listening: "Tap again when you're done."
        case .thinking(let transcript), .answered(let transcript, _): "“\(transcript)”"
        }
    }
}

/// Animated voice bars.
struct WaveformBars: View {
    var count = 5

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: 0.3 + 0.7 * abs(sin(t * 6 + Double(index) * 0.9)), anchor: .center)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
