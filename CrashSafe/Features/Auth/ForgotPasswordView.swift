import SwiftUI

struct ForgotPasswordView: View {
    @State private var viewModel: ForgotPasswordViewModel
    @FocusState private var focus: Bool?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ForgotPasswordViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                if viewModel.sent {
                    VStack(spacing: Space.md) {
                        IconBadge(systemName: "envelope.badge.fill", tint: Brand.blue, size: 64)
                        Text("Check your email").font(.title2.bold()).foregroundStyle(Brand.textPrimary)
                        Text("If an account exists for \(viewModel.email), we sent a link to reset your password.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.primary)
                } else {
                    Text("Enter the email you signed up with and we'll send you a reset link.")
                        .foregroundStyle(Brand.textSecondary)
                    FormField(title: "Email", text: $viewModel.email, error: viewModel.errorMessage,
                              systemImage: "envelope.fill", contentType: .emailAddress, keyboard: .emailAddress,
                              autocapitalization: .never, focus: $focus, field: true)
                    Spacer()
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
                }
            }
            .padding(Space.lg)
            .background(BrandBackground())
            .animation(.spring(response: 0.4), value: viewModel.sent)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationCornerRadius(28)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ForgotPasswordView(viewModel: ForgotPasswordViewModel(auth: MockAuthService(), email: "jose@example.com"))
    }
}
