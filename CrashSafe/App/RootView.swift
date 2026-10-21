import SwiftUI

/// Routes between splash, the signed-out flow and the signed-in app.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            switch env.session.phase {
            case .launching:
                SplashView()
                    .transition(.opacity)
            case .signedOut:
                AuthFlowView()
                    .transition(.opacity)
            case .signedIn(let user):
                MainTabView(user: user)
                    .id(user.id) // fresh state per account
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: env.session.phase)
        .task { await env.session.restore() }
    }
}
