import SwiftUI

/// Labeled text field: soft fill, focus ring, inline error. Generic over the screen's focus enum.
struct FormField<Field: Hashable>: View {
    let title: String
    @Binding var text: String
    var error: String?
    /// Example text shown when empty; defaults to the title.
    var placeholder: String?
    var isSecure = false
    var systemImage: String?
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var focus: FocusState<Field?>.Binding
    let field: Field

    @State private var revealed = false

    private var isFocused: Bool { focus.wrappedValue == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.textSecondary)
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(isFocused ? Brand.blueInk : Brand.textSecondary)
                        .frame(width: 20)
                }
                Group {
                    if isSecure && !revealed {
                        SecureField("", text: $text, prompt: Text(placeholder ?? title).foregroundStyle(Brand.textSecondary.opacity(0.7)))
                    } else {
                        TextField("", text: $text, prompt: Text(placeholder ?? title).foregroundStyle(Brand.textSecondary.opacity(0.7)))
                    }
                }
                .focused(focus, equals: field)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(isSecure || keyboard == .emailAddress)
                .foregroundStyle(Brand.textPrimary)

                if isSecure {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(revealed ? "Hide password" : "Show password")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, isSecure ? 2 : 14)
            .frame(minHeight: 54)
            .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused || error != nil ? 2 : 0)
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Brand.redInk)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: error)
    }

    private var borderColor: Color {
        if error != nil { return Brand.redInk }
        return isFocused ? Brand.blueInk : .clear
    }
}

/// Four-segment password strength meter.
struct PasswordStrengthMeter: View {
    let password: String

    static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var score = password.count >= 8 ? 1 : 0
        if password.count >= 12 { score += 1 }
        if password.contains(where: \.isUppercase) && password.contains(where: \.isLowercase) { score += 1 }
        if password.contains(where: \.isNumber) || password.contains(where: { !$0.isLetter && !$0.isNumber }) { score += 1 }
        return min(score, 4)
    }

    private var score: Int { Self.score(password) }

    private var label: (String, Color) {
        switch score {
        case 0, 1: ("Weak", Brand.redInk)
        case 2: ("Okay", Brand.amberInk)
        case 3: ("Good", Brand.blueInk)
        default: ("Strong", Brand.greenInk)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < score ? label.1 : Brand.fieldFill)
                    .frame(height: 5)
            }
            Text(label.0)
                .font(.caption.weight(.semibold))
                .foregroundStyle(label.1)
                .frame(width: 48, alignment: .trailing)
        }
        .animation(.spring(response: 0.3), value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(label.0)")
    }
}

extension View {
    /// For multi-line fields: Return ends editing instead of inserting a new line.
    func finishOnReturn(text: Binding<String>, focus: FocusState<Bool>.Binding) -> some View {
        self
            .focused(focus)
            .onChange(of: text.wrappedValue) { _, new in
                guard new.hasSuffix("\n") else { return }
                text.wrappedValue = String(new.dropLast())
                focus.wrappedValue = false
            }
    }
}
