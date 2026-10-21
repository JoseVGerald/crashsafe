import SwiftData
import SwiftUI

/// The signed-in app.
struct MainTabView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [Profile]

    init(user: AuthUser) {
        self.user = user
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

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
        .onAppear(perform: startBackgroundCoaching)
        .onChange(of: profiles.first?.autoDetectDrives) { startBackgroundCoaching() }
    }

    /// Always-on: coach every drive, and start live monitoring when Core Motion detects driving.
    private func startBackgroundCoaching() {
        let profiles = profiles
        env.coach.profileProvider = {
            let profile = profiles.first
            let first = profile?.sortedContacts.first
            let lovedOne = first.map { $0.relationship.isEmpty ? $0.name : "your \($0.relationship.lowercased())" }
            return (profile?.coachingStyle ?? .logical, profile?.experience ?? .newDriver, lovedOne)
        }
        env.coach.start()

        guard profiles.first?.autoDetectDrives ?? true else {
            env.autoDetector.stop()
            return
        }
        let driving = env.driving
        env.autoDetector.onDriveStarted = {
            if !driving.isActive { driving.startLive(background: true) }
        }
        env.autoDetector.onDriveEnded = {
            if driving.mode == .live { driving.stop() }
        }
        env.autoDetector.start()
    }
}
