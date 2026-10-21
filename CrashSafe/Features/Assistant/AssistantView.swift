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

    private let suggestions = ["I need a tow", "What do I tell insurance?", "What photos should I take?", "I'm shaking"]

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
                if viewModel.isAfterCrash {
                    emergencyBar
                }
                messageList
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { brainBadge }
            }
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
        viewModel.begin(scenario)
    }

    private func makeContext() -> AssistantContext {
        let profile = profiles.first
        let car = [profile?.carMake, profile?.carModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return AssistantContext(
            userName: user.name,
            isOnline: env.connectivity.isOnline,
            scenario: viewModel.scenario,
            carDescription: car.isEmpty ? (profile?.carType.label ?? "") : "\(car) (\(profile?.carType.label ?? ""))",
            insurer: profile?.insurer ?? "",
            medicalNotes: profile?.medicalNotes ?? "",
            familyContactNames: profile?.sortedContacts.map(\.name) ?? [],
            currentTrip: trips.first?.routeLabel
        )
    }

    // MARK: - Pieces

    private var brainBadge: some View {
        Label(env.connectivity.isOnline ? "Online" : "Offline",
              systemImage: env.connectivity.isOnline ? "cloud.fill" : "iphone")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityLabel(env.connectivity.isOnline ? "Using the online assistant" : "Using the offline assistant")
    }

    private var emergencyBar: some View {
        Button {
            if let url = URL(string: "tel://911") { openURL(url) }
        } label: {
            Label("Anyone hurt? Call 911", systemImage: "phone.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(Theme.emergencyFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isThinking {
                        TypingIndicator().id("typing")
                    }
                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error)
                    }
                    if viewModel.messages.count <= 1 {
                        suggestionChips
                    }
                }
                .padding()
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
            ForEach(suggestions, id: \.self) { text in
                Button(text) { Task { await viewModel.send(text) } }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.top, 4)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                inputFocused = false
                Task { await viewModel.listen() }
            } label: {
                Image(systemName: viewModel.isListening ? "waveform" : "mic.fill")
                    .font(.title2.weight(.semibold))
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isListening)
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.white)
                    .background(viewModel.isListening ? Theme.emergencyFill : Theme.accent, in: Circle())
            }
            .accessibilityLabel(viewModel.isListening ? "Listening" : "Speak to the assistant")
            .disabled(viewModel.isThinking)

            TextField(viewModel.isListening ? "Listening…" : "Ask anything", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                .submitLabel(.send)
                .onSubmit { Task { await viewModel.send() } }

            Button {
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 44))
                    .frame(width: 56, height: 56)
            }
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .background(
                    message.role == .user ? Theme.accent : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .textSelection(.enabled)
            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((message.role == .user ? "You: " : "Assistant: ") + message.text)
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = .pi }
        }
        .accessibilityLabel("Assistant is typing")
    }
}

#Preview("General") {
    let env = PreviewData.environment()
    AssistantView(user: PreviewData.user, viewModel: AssistantViewModel(
        service: env.assistant, voice: env.voiceInput,
        contextProvider: { AssistantContext(userName: "Jose", isOnline: true, scenario: .general, carDescription: "",
                                            insurer: "", medicalNotes: "", familyContactNames: []) }))
        .environment(env)
        .modelContainer(PreviewData.container())
}

#Preview("After crash") {
    let env = PreviewData.environment()
    env.router.pendingAssistantScenario = .afterCrash(.ok)
    return AssistantView(user: PreviewData.user, viewModel: AssistantViewModel(
        service: env.assistant, voice: env.voiceInput,
        contextProvider: { AssistantContext(userName: "Jose", isOnline: true, scenario: .general, carDescription: "",
                                            insurer: "", medicalNotes: "", familyContactNames: []) }))
        .environment(env)
        .modelContainer(PreviewData.container())
}
