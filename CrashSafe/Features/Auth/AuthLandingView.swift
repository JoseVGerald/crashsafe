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

    private let features: [(icon: String, tint: Color, title: String, detail: String)] = [
        ("waveform.path.ecg", Brand.red, "Checks on you after a crash", "If you don't answer, your family is alerted."),
        ("sparkles", Brand.indigo, "Pulse talks you through it", "Calm, step-by-step help — by voice."),
        ("antenna.radiowaves.left.and.right.slash", Brand.green, "Works with no signal", "Tow, hospitals and guides saved for your route."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.lg)

            ZStack {
                PulseRings(color: Brand.blue, count: 3)
                    .frame(width: 120, height: 120)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Brand.heroGradient, in: Circle())
                    .shadow(color: Brand.blue.opacity(0.4), radius: 24, y: 10)
            }
            .frame(height: 200)
            .fadeUp()

            VStack(spacing: Space.sm) {
                Text("CrashSafe")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Text("Help for what happens next.")
                    .font(.title3)
                    .foregroundStyle(Brand.textSecondary)
            }
            .fadeUp(delay: 0.08)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: 14) {
                        IconBadge(systemName: feature.icon, tint: feature.tint, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline).foregroundStyle(Brand.textPrimary)
                            Text(feature.detail).font(.subheadline).foregroundStyle(Brand.textSecondary)
                        }
                    }
                    .fadeUp(delay: 0.16 + Double(index) * 0.07)
                }
            }
            .padding(.top, Space.xl)
            .padding(.horizontal, Space.sm)

            Spacer(minLength: Space.lg)

            VStack(spacing: 12) {
                NavigationLink(value: AuthRoute.signUp) {
                    Text("Create account")
                }
                .buttonStyle(.primary)

                Button {
                    let viewModel = SignInViewModel(session: env.session)
                    appleViewModel = viewModel
                    Task { await viewModel.signInWithApple() }
                } label: {
                    if appleViewModel?.isLoading == true {
                        ProgressView()
                    } else {
                        Label("Continue with Apple", systemImage: "apple.logo")
                    }
                }
                .buttonStyle(.pill(.dark))

                NavigationLink(value: AuthRoute.signIn) {
                    Text("I already have an account")
                }
                .buttonStyle(.pill(.ghost, height: 48))
            }
            .fadeUp(delay: 0.4)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm)
        .frame(maxWidth: 680)
        .background(BrandBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    AuthFlowView()
        .environment(PreviewData.environment(signedIn: false))
}
