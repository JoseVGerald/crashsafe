import SwiftUI

/// Labeled text field with a large tap area and an inline error below it.
struct FormField: View {
    let title: String
    @Binding var text: String
    var error: String?
    var isSecure = false
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Group {
                    if isSecure && !revealed {
                        SecureField(title, text: $text)
                    } else {
                        TextField(title, text: $text)
                    }
                }
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(isSecure || keyboard == .emailAddress)
                .font(.body)

                if isSecure {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(revealed ? "Hide password" : "Show password")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, isSecure ? 4 : 14)
            .frame(minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(error == nil ? Color(.separator) : Theme.danger, lineWidth: error == nil ? 1 : 2)
            )

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.danger)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: error)
    }
}

#Preview {
    VStack(spacing: 20) {
        FormField(title: "Email", text: .constant("jose@"), error: "Enter a valid email address.")
        FormField(title: "Password", text: .constant("secret"), isSecure: true)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
