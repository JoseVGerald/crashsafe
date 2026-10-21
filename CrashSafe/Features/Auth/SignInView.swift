import SwiftUI

/// Root of the signed-out flow.
struct AuthFlowView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            SignInView(viewModel: SignInViewModel(session: env.session))
        }
    }
}

struct SignInView: View {
    @State private var viewModel: SignInViewModel
    @State private var showingForgotPassword = false
    @FocusState private var focus: Field?
    @Environment(AppEnvironment.self) private var env

    private enum Field { case email, password }

    init(viewModel: SignInViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }

                VStack(spacing: 16) {
                    FormField(title: "Email", text: $viewModel.email, error: viewModel.emailError,
                              contentType: .username, keyboard: .emailAddress, autocapitalization: .never)
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                    FormField(title: "Password", text: $viewModel.password, error: viewModel.passwordError,
                              isSecure: true, contentType: .password, autocapitalization: .never)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await viewModel.signIn() } }

                    Button("Forgot password?") { showingForgotPassword = true }
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                }

                Button {
                    focus = nil
                    Task { await viewModel.signIn() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign in")
                    }
                }
                .buttonStyle(.primary)
                .disabled(viewModel.isLoading)

                divider

                AppleSignInButton {
                    focus = nil
                    Task { await viewModel.signInWithApple() }
                }
                .disabled(viewModel.isLoading)

                HStack {
                    Text("New here?").foregroundStyle(.secondary)
                    NavigationLink("Create an account") {
                        SignUpView(viewModel: SignUpViewModel(session: env.session))
                    }
                    .fontWeight(.semibold)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(viewModel: ForgotPasswordViewModel(auth: env.session.auth, email: viewModel.email))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Welcome back")
                .font(.largeTitle.bold())
            Text("Sign in to get help after a crash — even with no signal.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var divider: some View {
        HStack {
            Rectangle().fill(Color(.separator)).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(Color(.separator)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Apple-style button that defers the real flow to the active `AuthService`.
/// (The system `SignInWithAppleButton` drives its own request, which doesn't fit the mock.)
struct AppleSignInButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Label("Sign in with Apple", systemImage: "apple.logo")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Theme.bigTapTarget)
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(colorScheme == .dark ? .white : .black)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AuthFlowView()
        .environment(PreviewData.environment(signedIn: false))
}
