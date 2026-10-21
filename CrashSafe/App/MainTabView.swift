import SwiftUI

/// The signed-in app.
struct MainTabView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var router = env.router
        TabView(selection: $router.selectedTab) {
            HomeView(
                user: user,
                viewModel: HomeViewModel(detector: env.crashDetector, driving: env.driving,
                                         conditions: env.conditions, userID: user.id),
                talk: PressToTalkViewModel(assistant: env.assistant) { [user, env] in
                    AssistantContext.make(user: user, profile: nil, activeTrip: nil, isOnline: env.connectivity.isOnline)
                }
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppRouter.Tab.home)

            TripPlannerView(userID: user.id)
                .tabItem { Label("Trips", systemImage: "map.fill") }
                .tag(AppRouter.Tab.trips)

            AssistantView(user: user, viewModel: AssistantViewModel(
                service: env.assistant,
                voice: env.voiceInput,
                // Replaced by AssistantView with one that reads the live profile.
                contextProvider: { [user] in
                    AssistantContext.make(user: user, profile: nil, activeTrip: nil, isOnline: true)
                }
            ))
            .tabItem { Label("Pulse", systemImage: "sparkles") }
            .tag(AppRouter.Tab.assistant)

            ProfileView(user: user)
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(AppRouter.Tab.profile)
        }
        .fullScreenCover(item: $router.activeCrash) { event in
            CheckInContainer(event: event, user: user)
        }
        .fullScreenCover(isPresented: $router.showingCarPlay) {
            CarPlayModeView(user: user)
        }
    }
}
