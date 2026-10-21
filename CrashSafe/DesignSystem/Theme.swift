import SwiftUI

/// Shared look and feel. The app is used by people who may be panicking,
/// so everything favors high contrast, large tap targets and Dynamic Type.
enum Theme {
    static let accent = Color.accentColor
    static let danger = Color("Danger")

    /// Minimum height for primary actions (well above Apple's 44pt minimum).
    static let bigTapTarget: CGFloat = 60
    static let cornerRadius: CGFloat = 16
    static let spacing: CGFloat = 16
}

/// Full-width, high-contrast button for the main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Theme.bigTapTarget)
            .padding(.horizontal)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(tint.opacity(isEnabled ? 1 : 0.4))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Outlined companion to `PrimaryButtonStyle` for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tint, lineWidth: 2)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(tint: Color) -> PrimaryButtonStyle { PrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(tint: Color) -> SecondaryButtonStyle { SecondaryButtonStyle(tint: tint) }
}

/// Rounded container used for dashboard cards.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

/// Label + value status row with a colored SF Symbol.
struct StatusRow: View {
    let systemImage: String
    let title: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline error message shown under form fields and at the top of forms.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Error: \(message)")
    }
}

#Preview("Buttons & cards") {
    VStack(spacing: 16) {
        Button("Start a trip") {}.buttonStyle(.primary)
        Button("I need help") {}.buttonStyle(.primary(tint: Theme.danger))
        Button("Secondary") {}.buttonStyle(.secondary)
        Card {
            StatusRow(systemImage: "car.fill", title: "Current trip", value: "Seattle → Spokane", tint: Theme.accent)
        }
        ErrorBanner(message: "That password is incorrect.")
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
