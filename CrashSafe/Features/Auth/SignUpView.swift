import SwiftUI

struct SignUpView: View {
    @State private var viewModel: SignUpViewModel
    @FocusState private var focus: SignUpViewModel.Field?

    init(viewModel: SignUpViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create your account")
                        .font(.largeTitle.bold())
                    Text("Your profile and trips stay on this phone.")
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }

                VStack(spacing: 16) {
                    field(.name, "Full name", $viewModel.name, contentType: .name, autocapitalization: .words)
                    field(.email, "Email", $viewModel.email, contentType: .emailAddress,
                          keyboard: .emailAddress, autocapitalization: .never)
                    field(.password, "Password", $viewModel.password, secure: true, contentType: .newPassword)
                    field(.confirm, "Confirm password", $viewModel.confirmPassword, secure: true, contentType: .newPassword)
                }

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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focus) { old, _ in
            // Validate a field once the user leaves it.
            if let old { viewModel.touched.insert(old) }
        }
    }

    private func field(_ field: SignUpViewModel.Field,
                       _ title: String,
                       _ text: Binding<String>,
                       secure: Bool = false,
                       contentType: UITextContentType? = nil,
                       keyboard: UIKeyboardType = .default,
                       autocapitalization: TextInputAutocapitalization = .never) -> some View {
        FormField(title: title, text: text, error: viewModel.error(for: field), isSecure: secure,
                  contentType: contentType, keyboard: keyboard, autocapitalization: autocapitalization)
            .focused($focus, equals: field)
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
