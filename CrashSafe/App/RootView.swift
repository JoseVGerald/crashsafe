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
                SignedInRoot(user: user)
                    .id(user.id) // fresh state per account
                    .transition(.opacity)
            }
        }
        .tint(Brand.blueInk)
        .animation(.easeInOut(duration: 0.35), value: env.session.phase)
        .task { await env.session.restore() }
        .task { await listenForCrashes() }
    }

    /// One listener for the app's lifetime (an AsyncStream ends when its consumer is cancelled,
    /// so this must not live in a view that comes and goes, like the tab view).
    private func listenForCrashes() async {
        for await event in env.crashDetector.events {
            guard env.session.user != nil, env.router.activeCrash == nil else { continue }
            env.router.activeCrash = event
        }
    }
}
