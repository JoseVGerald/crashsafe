import SwiftUI

/// Routes between splash, the signed-out flow and the signed-in app.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

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
        .preferredColorScheme(.dark) // the Pulse brand is a dark, night-driving theme
        .animation(.easeInOut(duration: 0.35), value: env.session.phase)
        .task { await env.session.restore() }
        .task { await env.permissions.refresh() }
        .onChange(of: env.session.user?.id) { _, id in
            env.intelligence.setActivitySensing(id != nil && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings (or the background): pick up permission changes right away.
            // On screen: keep sensors running so Home can show what you're doing (walking, driving…).
            env.intelligence.setActivitySensing(phase == .active && env.session.user != nil)
            guard phase == .active else { return }
            env.location.refreshAuthorization()
            env.sensors.refreshAfterForeground()
            Task { await env.permissions.refresh() }
        }
        .onChange(of: env.router.activeCrash == nil) { _, closed in
            if closed { env.crashCenter.dismiss() }
        }
        .onChange(of: env.session.user?.id) { previous, current in
            if previous != nil, previous != current {
                env.crashDetector.stopMonitoring()
                env.driving.stop()
                env.driveWatcher.disarm()
            }
        }
    }
}
