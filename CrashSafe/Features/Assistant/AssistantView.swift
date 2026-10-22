import SwiftData
import SwiftUI

struct AssistantView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var viewModel: AssistantViewModel
    @FocusState private var inputFocused: Bool

    @Query private var profiles: [Profile]
    @Query private var trips: [Trip]

    @State private var jurisdiction = "UNKNOWN"
    @State private var assistanceStage = "active"

    private let suggestions = [
        ("car.side.fill", "I need a tow"),
        ("doc.text.fill", "What do I tell insurance?"),
        ("camera.fill", "What photos should I take?"),
        ("heart.fill", "I'm shaking"),
    ]

    init(user: AuthUser, viewModel: AssistantViewModel) {
        self.user = user
        _viewModel = State(initialValue: viewModel)
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
        _trips = Query(filter: #Predicate<Trip> { $0.ownerID == id && $0.isActive })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if viewModel.isAfterCrash {
                    emergencyBar
                }
                assistanceControls
                messageList
                inputBar
            }
            .background(BrandBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            viewModel.contextProvider = makeContext
            consumePendingScenario()
            viewModel.begin(.general)
        }
        .onChange(of: env.router.pendingAssistantScenario) { consumePendingScenario() }
    }

    private func consumePendingScenario() {
        guard let scenario = env.router.pendingAssistantScenario else { return }
        env.router.pendingAssistantScenario = nil
        viewModel.contextProvider = makeContext
        assistanceStage = "active"
        viewModel.begin(scenario)
    }

    private func makeContext() -> AssistantContext {
        var context = AssistantContext.make(user: user, profile: profiles.first, activeTrip: trips.first,
                              isOnline: env.connectivity.isOnline, scenario: viewModel.scenario,
                              incident: viewModel.isAfterCrash ? env.router.assistantIncident : nil,
                              activity: env.intelligence.assistantActivity)
        context.jurisdiction = jurisdiction
        context.assistanceStage = viewModel.isAfterCrash ? assistanceStage : "followup"
        return context
    }

    private var assistanceControls: some View {
        HStack {
            Menu {
                Button("Washington") { jurisdiction = "WA" }
                Button("Oregon") { jurisdiction = "OR" }
                Button("California") { jurisdiction = "CA" }
                Button("Other state or not specified") { jurisdiction = "UNKNOWN" }
            } label: {
                Label("Crash location: " + (["WA": "Washington", "OR": "Oregon", "CA": "California"][jurisdiction] ?? "Not specified"),
                      systemImage: "mappin")
            }
            .accessibilityHint("Sets which state procedures can be shown")
            Spacer()
            if viewModel.isAfterCrash {
                Button(assistanceStage == "active" ? "Show follow-up help" : "Back to immediate steps") {
                    assistanceStage = assistanceStage == "active" ? "followup" : "active"
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, Space.md)
        .padding(.vertical, 6)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            PulseAvatar(size: 44, active: viewModel.isThinking || viewModel.isListening, listening: viewModel.isListening)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pulse").font(.title3.bold()).foregroundStyle(Brand.textPrimary)
                Text(viewModel.isThinking ? "Thinking…" : (env.connectivity.isOnline ? "Online assistant" : "Offline · using your trip pack"))
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            StatusChip(text: env.connectivity.isOnline ? "Online" : "Offline",
                       systemImage: env.connectivity.isOnline ? "cloud.fill" : "iphone",
                       tint: env.connectivity.isOnline ? Brand.greenInk : Brand.amberInk)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .animation(.easeOut, value: viewModel.isThinking)
    }

    private var emergencyBar: some View {
        Button {
            if let url = URL(string: "tel://911") { openURL(url) }
        } label: {
            Label("Anyone hurt? Call 911", systemImage: "phone.fill")
        }
        .buttonStyle(.pill(.danger, height: 50))
        .padding(.horizontal, Space.md)
        .padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity))
                    }
                    if viewModel.isThinking {
                        TypingIndicator().id("typing").transition(.opacity)
                    }
                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error)
                    }
                    if viewModel.messages.count <= 1 {
                        suggestionChips.padding(.top, 4)
                    }
                }
                .padding(Space.md)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.messages.count)
                .animation(.easeOut, value: viewModel.isThinking)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                withAnimation { proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: viewModel.isThinking) {
                if viewModel.isThinking { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
            ForEach(suggestions, id: \.1) { icon, text in
                Button {
                    Task { await viewModel.send(text) }
                } label: {
                    Label(text, systemImage: icon)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .foregroundStyle(Brand.blueInk)
                        .background(Brand.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Brand.blueInk.opacity(0.25)))
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                inputFocused = false
                Task { await viewModel.listen() }
            } label: {
                ZStack {
                    PulseRings(color: Brand.blue, count: 2, active: viewModel.isListening)
                    PulseVoiceFace(mood: viewModel.isListening ? .listening : (viewModel.isThinking ? .thinking : .idle),
                                   diameter: 52)
                }
                .frame(width: 52, height: 52)
            }
            .accessibilityLabel(viewModel.isListening ? "Listening" : "Speak to Pulse")
            .disabled(viewModel.isThinking)

            TextField("", text: $viewModel.draft,
                      prompt: Text(viewModel.isListening ? "Listening…" : "Message Pulse").foregroundStyle(Brand.textSecondary),
                      axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(minHeight: 52)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Brand.stroke))
                .submitLabel(.send)
                .onSubmit { Task { await viewModel.send() } }

            if viewModel.canSend {
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Brand.blue, in: Circle())
                }
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .animation(.spring(response: 0.3), value: viewModel.canSend)
    }
}

/// Pulse's avatar: the thinking orb on a blue disc. `active` switches it to the working
/// animation with rings; `animated: false` holds a still frame (for avatars repeated down a chat).
struct PulseAvatar: View {
    var size: CGFloat = 32
    var active = false
    var listening = false
    var animated = true

    var body: some View {
        ZStack {
            PulseRings(color: Brand.blue, count: 2, active: active)
            PulseOrbDisc(mood: listening ? .listening : (active ? .thinking : .idle), diameter: size,
                         animated: animated || active)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 48)
            } else {
                PulseAvatar(size: 28, animated: false)
            }
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(message.role == .user ? .white : Brand.textPrimary)
                .background(
                    message.role == .user ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Brand.surface),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 22,
                        bottomLeadingRadius: message.role == .user ? 22 : 6,
                        bottomTrailingRadius: message.role == .user ? 6 : 22,
                        topTrailingRadius: 22,
                        style: .continuous)
                )
                .overlay {
                    if message.role == .assistant {
                        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22,
                                               topTrailingRadius: 22, style: .continuous)
                            .strokeBorder(Brand.stroke)
                    }
                }
                .textSelection(.enabled)
            if message.role == .assistant { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((message.role == .user ? "You: " : "Pulse: ") + message.text)
    }
}

private struct TypingIndicator: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PulseAvatar(size: 28, active: true)
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 8, height: 8)
                        .phaseAnimator([0.3, 1]) { content, phase in
                            content.opacity(phase).scaleEffect(phase)
                        } animation: { _ in .easeInOut(duration: 0.5).delay(Double(index) * 0.15) }
                }
            }
            .foregroundStyle(Brand.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 16)
            .background(Brand.surface, in: Capsule())
        }
        .accessibilityLabel("Pulse is typing")
    }
}

#Preview("General") {
    let env = PreviewData.environment()
    AssistantView(user: PreviewData.user, viewModel: AssistantViewModel(
        service: env.assistant, voice: env.voiceInput,
        contextProvider: { AssistantContext.make(user: PreviewData.user, profile: nil, activeTrip: nil, isOnline: true) }))
        .environment(env)
        .modelContainer(PreviewData.container())
}
