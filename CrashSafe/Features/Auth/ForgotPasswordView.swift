import SwiftUI

struct ForgotPasswordView: View {
    @State private var viewModel: ForgotPasswordViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ForgotPasswordViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.sent {
                    ContentUnavailableView(
                        "Check your email",
                        systemImage: "envelope.badge.fill",
                        description: Text("If an account exists for \(viewModel.email), we sent a link to reset your password.")
                    )
                    Button("Done") { dismiss() }
                        .buttonStyle(.primary)
                } else {
                    Text("Enter the email you signed up with and we'll send you a reset link.")
                        .foregroundStyle(.secondary)
                    FormField(title: "Email", text: $viewModel.email, error: viewModel.errorMessage,
                              contentType: .emailAddress, keyboard: .emailAddress, autocapitalization: .never)
                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send reset link")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(viewModel.isLoading)
                    Spacer()
                }
            }
            .padding(24)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ForgotPasswordView(viewModel: ForgotPasswordViewModel(auth: MockAuthService(), email: "jose@example.com"))
    }
}
