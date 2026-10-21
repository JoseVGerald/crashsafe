import SwiftData
import SwiftUI

/// Loads the driver's contacts, records the outcome, and hosts `CheckInView`.
struct CheckInContainer: View {
    let event: CrashEvent
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]

    init(event: CrashEvent, user: AuthUser) {
        self.event = event
        self.user = user
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    var body: some View {
        let recipients = profiles.first?.sortedContacts.map { AlertRecipient(name: $0.name, phone: $0.phone) } ?? []
        let connectivity = env.connectivity
        let viewModel = CheckInViewModel(event: event, recipients: recipients, alerts: env.alerts,
                                         isOnline: { connectivity.isOnline })
        viewModel.onResolve = { [context, user] outcome in
            context.insert(CheckInRecord(ownerID: user.id, outcome: outcome, wasSimulated: event.isSimulated))
        }
        return CheckInView(viewModel: viewModel)
    }
}

/// Full-screen "Are you OK?" check-in. Built for one-handed use: every action sits
/// in the bottom half of the screen, and the safest answer is the biggest button.
struct CheckInView: View {
    @State private var viewModel: CheckInViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL

    init(viewModel: CheckInViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.phase {
            case .counting:
                countdown
            case .resolved(let outcome):
                resolved(outcome)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: viewModel.phase)
        .sensoryFeedback(.warning, trigger: viewModel.secondsRemaining) { _, new in new <= 10 && new > 0 }
        .sensoryFeedback(.success, trigger: viewModel.phase) { _, new in new == .resolved(.ok) }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Countdown

    private var countdown: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Label("Possible crash detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                if viewModel.event.isSimulated {
                    Text("SIMULATED")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            Text("Are you OK?")
                .font(.system(size: 48, weight: .bold))
                .minimumScaleFactor(0.6)

            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: viewModel.progress)
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.progress)
                Text("\(viewModel.secondsRemaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: viewModel.secondsRemaining)
            }
            .frame(width: 170, height: 170)
            .padding(.vertical, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(viewModel.secondsRemaining) seconds to respond")

            Text(viewModel.recipients.isEmpty
                 ? "If you don't answer, we'll treat it as an emergency."
                 : "If you don't answer, we'll alert \(contactSummary).")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Button {
                    viewModel.respond(.needsHelp)
                } label: {
                    Label("I need help", systemImage: "cross.case.fill")
                        .frame(minHeight: 64)
                }
                .buttonStyle(.primary(tint: Theme.emergencyFill))

                Button {
                    viewModel.respond(.ok)
                } label: {
                    Label("I'm OK", systemImage: "checkmark.circle.fill")
                        .font(.title.weight(.bold))
                        .frame(minHeight: 96)
                }
                .buttonStyle(.primary(tint: Theme.safeFill))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var contactSummary: String {
        let names = viewModel.recipients.map(\.name)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "your \(names.count) family contacts"
        }
    }

    // MARK: - Outcomes

    @ViewBuilder
    private func resolved(_ outcome: CheckInOutcome) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 24)
            Image(systemName: outcome.systemImage)
                .font(.system(size: 60))
                .foregroundStyle(outcome == .ok ? .green : Theme.danger)
            Text(title(for: outcome))
                .font(.largeTitle.bold())
            Text(message(for: outcome))
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))

            if outcome != .ok {
                alertStatus
            }

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                if outcome != .ok {
                    Button {
                        if let url = URL(string: "tel://911") { openURL(url) }
                    } label: {
                        Label("Call 911", systemImage: "phone.fill")
                            .font(.title2.weight(.bold))
                            .frame(minHeight: 72)
                    }
                    .buttonStyle(.primary(tint: Theme.emergencyFill))
                }

                Button {
                    env.router.openAssistant(after: outcome)
                } label: {
                    Label(outcome == .noResponse ? "I'm awake — help me" : "Talk to the assistant",
                          systemImage: "waveform.circle.fill")
                        .frame(minHeight: outcome == .ok ? 80 : 60)
                }
                .buttonStyle(.primary)

                Button("Close") { env.router.activeCrash = nil }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var alertStatus: some View {
        HStack(spacing: 12) {
            if viewModel.recipients.isEmpty {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text("No family contacts yet. Add them in Profile so we can reach them next time.")
            } else if viewModel.isAlerting {
                ProgressView().tint(.white)
                Text("Alerting \(contactSummary)…")
            } else if let delivery = viewModel.alertDelivery {
                Image(systemName: delivery == .sent ? "checkmark.message.fill" : "clock.badge.exclamationmark")
                    .foregroundStyle(delivery == .sent ? .green : .yellow)
                Text(delivery == .sent
                     ? "Alert sent to \(contactSummary) (demo)."
                     : "No signal — alert to \(contactSummary) will send when you reconnect.")
            }
        }
        .font(.body.weight(.medium))
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func title(for outcome: CheckInOutcome) -> String {
        switch outcome {
        case .ok: "Glad you're OK"
        case .needsHelp: "Getting you help"
        case .noResponse: "We didn't hear from you"
        }
    }

    private func message(for outcome: CheckInOutcome) -> String {
        switch outcome {
        case .ok: "Let's go through what to do next, one step at a time."
        case .needsHelp: "If anyone is hurt, call 911 first. Then the assistant will stay with you."
        case .noResponse: "Your family contacts are being alerted. If you're hurt, call 911."
        }
    }
}

#Preview("Countdown") {
    let env = PreviewData.environment()
    CheckInView(viewModel: CheckInViewModel(
        event: CrashEvent(date: .now, peakG: 6, speedDropMPH: 35, isSimulated: true),
        recipients: [AlertRecipient(name: "Maria", phone: "555-0100"), AlertRecipient(name: "Leo", phone: "555-0199")],
        alerts: MockEmergencyAlertService(),
        isOnline: { true }
    ))
    .environment(env)
}
