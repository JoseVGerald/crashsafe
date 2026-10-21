import SwiftUI

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
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Welcome back")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Brand.textPrimary)
                    Text("Sign in to pick up where you left off.")
                        .foregroundStyle(Brand.textSecondary)
                }
                .fadeUp()

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }

                VStack(alignment: .trailing, spacing: 18) {
                    FormField(title: "Email", text: $viewModel.email, error: viewModel.emailError,
                              placeholder: "you@example.com", systemImage: "envelope.fill", contentType: .username, keyboard: .emailAddress,
                              autocapitalization: .never, focus: $focus, field: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                    FormField(title: "Password", text: $viewModel.password, error: viewModel.passwordError,
                              isSecure: true, systemImage: "lock.fill", contentType: .password,
                              autocapitalization: .never, focus: $focus, field: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await viewModel.signIn() } }

                    Button("Forgot password?") { showingForgotPassword = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.blueInk)
                        .frame(minHeight: 44)
                }
                .fadeUp(delay: 0.08)

                VStack(spacing: Space.md) {
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

                    HStack {
                        Rectangle().fill(Brand.stroke).frame(height: 1)
                        Text("or").font(.footnote).foregroundStyle(Brand.textSecondary)
                        Rectangle().fill(Brand.stroke).frame(height: 1)
                    }
                    .accessibilityHidden(true)

                    Button {
                        focus = nil
                        Task { await viewModel.signInWithApple() }
                    } label: {
                        Label("Continue with Apple", systemImage: "apple.logo")
                    }
                    .buttonStyle(.pill(.dark))
                    .disabled(viewModel.isLoading)
                }
                .fadeUp(delay: 0.16)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .frame(maxWidth: 680)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackground())
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.2), value: viewModel.errorMessage)
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(viewModel: ForgotPasswordViewModel(auth: env.session.auth, email: viewModel.email))
        }
    }
}

#Preview {
    NavigationStack {
        SignInView(viewModel: SignInViewModel(session: PreviewData.environment(signedIn: false).session))
    }
    .environment(PreviewData.environment(signedIn: false))
}
