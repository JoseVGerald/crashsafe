import SwiftUI

/// The signed-in app.
struct MainTabView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var router = env.router
        TabView(selection: $router.selectedTab) {
            HomeView(user: user, viewModel: HomeViewModel(detector: env.crashDetector, userID: user.id))
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
                    AssistantContext(userName: user.name, isOnline: true, scenario: .general, carDescription: "",
                                     insurer: "", medicalNotes: "", familyContactNames: [])
                }
            ))
            .tabItem { Label("Assistant", systemImage: "waveform.circle.fill") }
            .tag(AppRouter.Tab.assistant)

            ProfileView(user: user, viewModel: ProfileViewModel(userID: user.id, session: env.session))
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(AppRouter.Tab.profile)
        }
        .fullScreenCover(item: $router.activeCrash) { event in
            CheckInContainer(event: event, user: user)
        }
    }
}
