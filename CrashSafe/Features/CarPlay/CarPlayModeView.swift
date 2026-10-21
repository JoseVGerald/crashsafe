import SwiftUI

/// CarPlay-style driving mode (built after the core features).
struct CarPlayModeView: View {
    let user: AuthUser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Close") { dismiss() }
    }
}
