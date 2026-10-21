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
                contextProvider: { [user] in
                    AssistantContext(userName: user.name, isOnline: true, scenario: .general, carDescription: "",
                                     insurer: "", medicalNotes: "", familyContactNames: [])
                }
            ))
            .tabItem { Label("Assistant", systemImage: "waveform.circle.fill") }
                .tag(AppRouter.Tab.assistant)
            VStack(spacing: 16) {
                Text("Signed in as \(user.name)")
                Button("Sign out") { env.session.signOut() }.buttonStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
            .tag(AppRouter.Tab.profile)
        }
        .fullScreenCover(item: $router.activeCrash) { event in
            CheckInContainer(event: event, user: user)
        }
    }

    private func placeholder(_ title: String) -> some View {
        Text(title).font(.title)
    }
}
