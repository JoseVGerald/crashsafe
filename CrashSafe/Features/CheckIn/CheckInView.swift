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
        return CheckInView(user: user, viewModel: viewModel)
    }
}

/// Full-screen "Are you OK?" check-in. Built for one-handed use: every action sits
/// in the bottom half of the screen, and the safest answer is the biggest button.
/// Once answered (or timed out), it becomes the post-crash help hub.
struct CheckInView: View {
    let user: AuthUser
    @State private var viewModel: CheckInViewModel
    /// Big for panicked eyes, but still scales with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 48
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 64

    init(user: AuthUser, viewModel: CheckInViewModel) {
        self.user = user
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ZStack {
            switch viewModel.phase {
            case .counting:
                countdown
                    .transition(.opacity)
            case .resolved(let outcome):
                RecoveryView(user: user, outcome: outcome, banner: banner(for: outcome))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: viewModel.phase)
        .sensoryFeedback(.warning, trigger: viewModel.secondsRemaining) { _, new in new <= 10 && new > 0 }
        .sensoryFeedback(.success, trigger: viewModel.phase) { _, new in new == .resolved(.ok) }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: Countdown

    private var countdown: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Label("Possible crash detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Brand.amber)
                if viewModel.event.isSimulated {
                    Text("SIMULATED")
                        .font(.caption.weight(.heavy))
                        .tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(.top, Space.lg)

            Spacer(minLength: Space.md)

            Text("Are you OK?")
                .font(.system(size: headlineSize, weight: .bold))
                .minimumScaleFactor(0.6)

            ZStack {
                PulseRings(color: Brand.red, count: 2)
                Circle().fill(Brand.navy)
                Circle().stroke(.white.opacity(0.1), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: viewModel.progress)
                    .stroke(Brand.red, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.progress)
                Text("\(viewModel.secondsRemaining)")
                    .font(.system(size: min(countdownSize, 84), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: viewModel.secondsRemaining)
            }
            .frame(width: 176, height: 176)
            .padding(.vertical, 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(viewModel.secondsRemaining) seconds to respond")

            Text(viewModel.recipients.isEmpty
                 ? "If you don't answer, we'll treat it as an emergency."
                 : "If you don't answer, we'll alert \(contactSummary).")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)

            Spacer(minLength: Space.md)

            VStack(spacing: 14) {
                Button {
                    viewModel.respond(.needsHelp)
                } label: {
                    Label("I need help", systemImage: "cross.case.fill")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.pill(.danger, height: 64))

                Button {
                    viewModel.respond(.ok)
                } label: {
                    Label("I'm OK", systemImage: "checkmark.circle.fill")
                        .font(.title.weight(.bold))
                }
                .buttonStyle(.pill(.safe, height: 92))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private var contactSummary: String {
        let names = viewModel.recipients.map(\.name)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "your \(names.count) family contacts"
        }
    }

    private func banner(for outcome: CheckInOutcome) -> RecoveryBanner {
        if outcome == .ok {
            return RecoveryBanner(text: "Glad you're OK. Take a slow breath — help is here if you need it.",
                                  systemImage: "checkmark.circle.fill", tint: Brand.greenInk)
        }
        if viewModel.recipients.isEmpty {
            return RecoveryBanner(text: "No family contacts saved. Call 911 if anyone is hurt.",
                                  systemImage: "exclamationmark.triangle.fill", tint: Brand.amberInk)
        }
        if viewModel.isAlerting {
            return RecoveryBanner(text: "Alerting \(contactSummary)…", systemImage: "bell.badge.fill", tint: Brand.amberInk)
        }
        switch viewModel.alertDelivery {
        case .sent:
            return RecoveryBanner(text: "\(contactSummary) got your location (demo).", systemImage: "checkmark.message.fill",
                                  tint: Brand.greenInk)
        case .queued:
            return RecoveryBanner(text: "No signal — your alert to \(contactSummary) will send when you reconnect.",
                                  systemImage: "clock.badge.exclamationmark", tint: Brand.amberInk)
        case nil:
            return RecoveryBanner(text: "Alerting \(contactSummary)…", systemImage: "bell.badge.fill", tint: Brand.amberInk)
        }
    }
}

#Preview("Countdown") {
    let env = PreviewData.environment()
    CheckInView(user: PreviewData.user, viewModel: CheckInViewModel(
        event: CrashEvent(date: .now, peakG: 6, speedDropMPH: 35, isSimulated: true),
        recipients: [AlertRecipient(name: "Maria", phone: "555-0100"), AlertRecipient(name: "Leo", phone: "555-0199")],
        alerts: MockEmergencyAlertService(),
        isOnline: { true }
    ))
    .environment(env)
    .modelContainer(PreviewData.container())
}
