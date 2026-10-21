import AuthenticationServices
import SwiftUI

/// Apple's own "Continue with Apple" button (official artwork, sizing and styles, per the HIG).
/// The tap is routed to `action`, so the active AuthService runs the real or mock flow.
struct SystemAppleButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Representable(style: colorScheme == .dark ? .white : .black, action: action)
            .id(colorScheme) // rebuild when the style changes
            .frame(height: Theme.bigTapTarget)
            .accessibilityLabel("Continue with Apple")
    }

    private struct Representable: UIViewRepresentable {
        let style: ASAuthorizationAppleIDButton.Style
        let action: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(action: action) }

        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: style)
            button.cornerRadius = Theme.bigTapTarget / 2 // pill, matching the app's other buttons
            button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
            return button
        }

        func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
            context.coordinator.action = action
        }

        final class Coordinator: NSObject {
            var action: () -> Void
            init(action: @escaping () -> Void) { self.action = action }
            @objc func tapped() { action() }
        }
    }
}
