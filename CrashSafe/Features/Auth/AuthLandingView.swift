import SwiftUI

/// Root of the signed-out flow: brand moment + one clear primary action.
struct AuthFlowView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            AuthLandingView()
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .signUp: SignUpView(viewModel: SignUpViewModel(session: env.session))
                    case .signIn: SignInView(viewModel: SignInViewModel(session: env.session))
                    }
                }
        }
        .tint(Brand.blueInk)
    }
}

enum AuthRoute: Hashable {
    case signUp, signIn
}

struct AuthLandingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var appleViewModel: SignInViewModel?

    private let features: [(icon: String, title: String, detail: String)] = [
        ("waveform.path.ecg", "Checks on you after a crash", "If you don't answer, your family is alerted."),
        ("mic.fill", "Pulse talks you through it", "Calm, step-by-step help — by voice."),
        ("antenna.radiowaves.left.and.right.slash", "Works with no signal", "Tow, hospitals and guides saved for your route."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md + 4) {
                PulseWordmark()
                    .padding(.top, Space.xs)
                    .fadeUp()

                BrandPhotoView(photo: .roadHero)
                    .frame(height: 176)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
                    .fadeUp(delay: 0.04)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Stay safe on every drive.")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("CrashSafe watches for crashes, checks on you, and gets help to the right place.")
                        .font(.body)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fadeUp(delay: 0.08)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(spacing: 14) {
                            Image(systemName: feature.icon)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Brand.blueInk)
                                .frame(width: 40, height: 40)
                                .background(Brand.surface, in: Circle())
                                .overlay(Circle().strokeBorder(Brand.stroke))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title).font(.headline).foregroundStyle(Brand.textPrimary)
                                Text(feature.detail).font(.subheadline).foregroundStyle(Brand.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .fadeUp(delay: 0.12 + Double(index) * 0.05)
                    }
                }

                VStack(spacing: 12) {
                    NavigationLink(value: AuthRoute.signUp) {
                        Text("Create account")
                    }
                    .buttonStyle(.primary)

                    SystemAppleButton {
                        let viewModel = SignInViewModel(session: env.session)
                        appleViewModel = viewModel
                        Task { await viewModel.signInWithApple() }
                    }
                    .disabled(appleViewModel?.isLoading == true)

                    NavigationLink(value: AuthRoute.signIn) {
                        Text("I already have an account")
                    }
                    .buttonStyle(.pill(.ghost, height: 48))
                }
                .fadeUp(delay: 0.3)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(BrandBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    AuthFlowView()
        .environment(PreviewData.environment(signedIn: false))
}
