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
                                         conditions: env.conditions, userID: user.id)
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppRouter.Tab.home)

            TripPlannerView(userID: user.id)
                .tabItem { Label("Trips", systemImage: "map.fill") }
                .tag(AppRouter.Tab.trips)

            PulseVoiceView(user: user, viewModel: env.pulseCall)
                .tabItem { Label("Pulse Voice", systemImage: "waveform.circle.fill") }
                .tag(AppRouter.Tab.pulseVoice)

            AssistantView(user: user, viewModel: AssistantViewModel(
                service: env.assistant,
                voice: env.voiceInput,
                // Replaced by AssistantView with one that reads the live profile.
                contextProvider: { [user] in
                    AssistantContext.make(user: user, profile: nil, activeTrip: nil, isOnline: true)
                }
            ))
            .tabItem { Label("Assistant", systemImage: "bubble.left.and.bubble.right.fill") }
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
        .onAppear {
            startBackgroundCoaching()
            updatePulseContext()
        }
        .onChange(of: profiles.first?.autoDetectDrives) { startBackgroundCoaching() }
        .onChange(of: profiles.first?.carType) { startBackgroundCoaching() }
    }

    /// Always-on: coach every drive, and start live monitoring + crash detection when Core Motion detects driving.
    private func startBackgroundCoaching() {
        let profiles = profiles
        env.coach.profileProvider = {
            let profile = profiles.first
            let first = profile?.sortedContacts.first
            let lovedOne = first.map { $0.relationship.isEmpty ? $0.name : "your \($0.relationship.lowercased())" }
            return (profile?.coachingStyle ?? .logical, profile?.experience ?? .newDriver, lovedOne)
        }
        env.coach.start()

        // Watch every drive: coaching + crash detection start when Core Motion notices a drive, and the
        // armed state is saved so a background relaunch (no screen) resumes it. "Always" location lets
        // iOS wake the app when the phone starts moving after it was closed.
        if profiles.first?.autoDetectDrives ?? true {
            env.driveWatcher.arm(.init(ownerID: user.id, carType: profiles.first?.carType ?? .sedan))
        } else {
            env.driveWatcher.disarm()
        }
    }

    private func updatePulseContext() {
        let user = user
        let profiles = profiles
        env.pulseCall.contextProvider = { [user, env, profiles] in
            AssistantContext.make(
                user: user,
                profile: profiles.first,
                activeTrip: nil,
                isOnline: env.connectivity.isOnline,
                activity: env.intelligence.assistantActivity
            )
        }
    }
}
