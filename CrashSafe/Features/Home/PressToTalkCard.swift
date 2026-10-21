import Observation
import SwiftUI

/// Hold-to-talk with Pulse. Proof of concept: the voice and AI services are the mocks for now.
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

struct PressToTalkCard: View {
    @State var viewModel: PressToTalkViewModel
    var onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            AdaptiveStack(spacing: Space.sm) {
                Label("Pulse", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button("Open chat", action: onOpenChat)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minHeight: 44)
            }

            AdaptiveStack(spacing: Space.md) {
                orb
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }

            if case .answered(_, let reply) = viewModel.phase {
                Text(reply)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { viewModel.reset() }
            }
        }
        .padding(Space.md + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.blue, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)
    }

    private var orb: some View {
        ZStack {
            PulseRings(color: .white, count: 3, active: viewModel.isListening)
                .frame(width: 78, height: 78)
            Circle()
                .fill(.white)
                .frame(width: 78, height: 78)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            if viewModel.isListening {
                WaveformBars()
                    .foregroundStyle(Brand.blue)
                    .frame(width: 34, height: 26)
            } else if case .thinking = viewModel.phase {
                ProgressView().tint(Brand.blue)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Brand.blue)
            }
        }
        .scaleEffect(viewModel.isListening ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.isListening)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 80, perform: {}, onPressingChanged: { pressing in
            pressing ? viewModel.pressBegan() : viewModel.pressEnded()
        })
        .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.isListening)
        .accessibilityElement()
        .accessibilityLabel("Talk to Pulse")
        .accessibilityHint("Press and hold, then speak.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.pressBegan()
            viewModel.pressEnded()
        }
    }

    private var title: String {
        switch viewModel.phase {
        case .idle: "Hold to talk"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .answered: "Pulse"
        }
    }

    private var subtitle: String {
        switch viewModel.phase {
        case .idle: "Ask about the road, your trip, or what to do after a crash."
        case .listening: "Let go when you're done."
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
