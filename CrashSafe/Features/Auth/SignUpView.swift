import SwiftUI

struct SignUpView: View {
    @State private var viewModel: SignUpViewModel
    @FocusState private var focus: SignUpViewModel.Field?

    init(viewModel: SignUpViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Create your account")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Brand.textPrimary)
                    Text("Takes a minute. Next, we'll set up your safety profile.")
                        .foregroundStyle(Brand.textSecondary)
                }
                .fadeUp()

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }

                VStack(spacing: 18) {
                    field(.name, "Full name", $viewModel.name, placeholder: "Jane Doe", icon: "person.fill",
                          contentType: .name, autocapitalization: .words)
                    field(.email, "Email", $viewModel.email, placeholder: "you@example.com", icon: "envelope.fill",
                          contentType: .emailAddress, keyboard: .emailAddress)
                    VStack(alignment: .leading, spacing: 10) {
                        field(.password, "Password", $viewModel.password, placeholder: "At least 8 characters", icon: "lock.fill",
                              secure: true, contentType: .newPassword)
                        if !viewModel.password.isEmpty {
                            PasswordStrengthMeter(password: viewModel.password)
                                .transition(.opacity)
                        }
                    }
                    field(.confirm, "Confirm password", $viewModel.confirmPassword, placeholder: "Type it again", icon: "lock.rotation",
                          secure: true, contentType: .newPassword)
                }
                .fadeUp(delay: 0.08)
                .animation(.easeOut(duration: 0.2), value: viewModel.password.isEmpty)

                VStack(spacing: Space.md) {
                    Button {
                        focus = nil
                        Task { await viewModel.submit() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Create account")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(viewModel.isLoading)

                    Label("Your profile, trips and medical notes stay on this phone.", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                        .frame(maxWidth: .infinity)
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
        .onChange(of: focus) { old, _ in
            // Validate a field once the user leaves it.
            if let old { viewModel.touched.insert(old) }
        }
    }

    private func field(_ field: SignUpViewModel.Field,
                       _ title: String,
                       _ text: Binding<String>,
                       placeholder: String? = nil,
                       icon: String,
                       secure: Bool = false,
                       contentType: UITextContentType? = nil,
                       keyboard: UIKeyboardType = .default,
                       autocapitalization: TextInputAutocapitalization = .never) -> some View {
        FormField(title: title, text: text, error: viewModel.error(for: field), placeholder: placeholder, isSecure: secure,
                  systemImage: icon, contentType: contentType, keyboard: keyboard,
                  autocapitalization: autocapitalization, focus: $focus, field: field)
            .submitLabel(field == .confirm ? .done : .next)
            .onSubmit {
                switch field {
                case .name: focus = .email
                case .email: focus = .password
                case .password: focus = .confirm
                case .confirm: Task { await viewModel.submit() }
                }
            }
    }
}

#Preview {
    NavigationStack {
        SignUpView(viewModel: SignUpViewModel(session: PreviewData.environment(signedIn: false).session))
    }
}
