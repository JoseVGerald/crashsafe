import SwiftData
import SwiftUI

/// Shows the check-in that `CrashResponseCenter` started the moment the crash was detected
/// (the countdown is already running, even if the phone was locked until now).
struct CheckInContainer: View {
    let event: CrashEvent
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let viewModel = env.crashCenter.current, viewModel.event.id == event.id {
            CheckInView(user: user, viewModel: viewModel)
        } else {
            // Opened without a running check-in (shouldn't happen): go straight to the help hub.
            RecoveryView(user: user, outcome: nil)
        }
    }
}

/// Full-screen "Are you OK?" check-in. Built for one-handed use: every action sits
/// in the bottom half of the screen, and the safest answer is the biggest button.
/// Once answered (or timed out), it becomes the post-crash help hub.
struct CheckInView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
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
        .onAppear { viewModel.start() } // already running; start() is a no-op then
    }

    // MARK: Countdown

    private var countdown: some View {
        VStack(spacing: 0) {
            // Photo header (mockup: "Are you okay?" over the road at dusk).
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    PulseWordmark()
                    if viewModel.event.isSimulated {
                        Text("SIMULATED")
                            .font(.caption.weight(.heavy))
                            .tracking(1)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Brand.amber)
                    .frame(width: 84, height: 84)
                    .background(Brand.navy.opacity(0.75), in: Circle())
                    .overlay(Circle().strokeBorder(Brand.amber.opacity(0.7), lineWidth: 2))
                    .accessibilityHidden(true)
                Text("Are you okay?")
                    .font(.system(size: headlineSize, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .phaseAnimator([1.0, 1.06], trigger: env.crashCenter.promptsSpoken) { view, scale in
                        view.scaleEffect(scale)
                    } animation: { _ in .spring(response: 0.25, dampingFraction: 0.5) }
                Label("Asking out loud every 5 seconds", systemImage: "speaker.wave.2.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityAddTraits(.isHeader)
                Text("A sudden impact was detected.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, Space.sm)
            .padding(.bottom, Space.lg)
            .padding(.horizontal, Space.lg)
            .frame(height: 340)
            .frame(maxWidth: .infinity)
            .background {
                BrandPhotoView(photo: .roadHero)
                    .overlay(Color.black.opacity(0.5))
                    .ignoresSafeArea(edges: .top)
            }

            HStack(spacing: Space.md) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: viewModel.progress)
                        .stroke(Brand.amber, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: viewModel.progress)
                    Text("\(viewModel.secondsRemaining)")
                        .font(.system(size: min(countdownSize, 64) * 0.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: viewModel.secondsRemaining)
                }
                .frame(width: 72, height: 72)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(viewModel.secondsRemaining) seconds to respond")

                Text(viewModel.recipients.isEmpty
                     ? "If you don't answer, we'll treat it as an emergency."
                     : "If you don't answer, we'll alert \(contactSummary).")
                    .font(.body)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .card(padding: Space.md)
            .padding(.horizontal, 20)
            .padding(.top, Space.md)

            if let impact = viewModel.event.impact {
                ImpactSummary(impact: impact)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            Spacer(minLength: Space.md)

            VStack(spacing: 14) {
                Button {
                    viewModel.respond(.ok)
                } label: {
                    Label("I'm okay", systemImage: "checkmark")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(.pill(.primary, height: 84))

                Button {
                    viewModel.respond(.needsHelp)
                } label: {
                    Label("I need help", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.amberInk)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(Brand.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Brand.stroke))
                }
                .buttonStyle(.pressable)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Brand.background.ignoresSafeArea())
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
            return RecoveryBanner(text: "We texted and called \(contactSummary) with your location.",
                                  systemImage: "checkmark.message.fill", tint: Brand.greenInk)
        case .dryRun:
            return RecoveryBanner(text: viewModel.event.isSimulated
                                    ? "Test crash: \(contactSummary) would get a text and a call with your location. Nothing was sent."
                                    : "Texting and calling aren't set up on the CrashSafe server yet, so nothing was sent. Call \(contactSummary) yourself.",
                                  systemImage: "exclamationmark.bubble.fill", tint: Brand.amberInk)
        case .queued:
            return RecoveryBanner(text: "Couldn't reach the CrashSafe server — call or text \(contactSummary) yourself if you can.",
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

/// "How hard was the hit?" — measured from the rolling sensor history.
struct ImpactSummary: View {
    let impact: ImpactReport

    var body: some View {
        HStack(spacing: Space.md) {
            metric("\(Int(impact.peakG.rounded())) g", "peak")
            metric("\(Int(impact.deltaVMPH.rounded())) mph", "speed change")
            metric(impact.timeToStop.map { String(format: "%.1f s", $0) } ?? "—", "to stop")
            Spacer(minLength: 0)
            Text(impact.severity.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(impact.severity == .minor ? Brand.greenInk : impact.severity == .moderate ? Brand.amberInk : Brand.redInk)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .padding(Space.md)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(impact.severity.label) impact: \(Int(impact.peakG.rounded())) g peak, about \(Int(impact.deltaVMPH.rounded())) miles per hour speed change"
                            + (impact.isSimulated ? ", simulated" : ""))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Brand.textPrimary)
            Text(label).font(.caption).foregroundStyle(Brand.textSecondary)
        }
    }
}
