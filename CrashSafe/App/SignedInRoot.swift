import SwiftData
import SwiftUI

/// Shows onboarding until the user's profile is complete, then the main app.
struct SignedInRoot: View {
    let user: AuthUser
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]

    init(user: AuthUser) {
        self.user = user
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    var body: some View {
        ZStack {
            if let profile = profiles.first {
                if profile.onboardingCompleted {
                    MainTabView(user: user)
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    OnboardingFlowView(user: user, profile: profile)
                        .transition(.opacity)
                }
            } else {
                BrandBackground()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: profiles.first?.onboardingCompleted)
        .onAppear {
            if profiles.isEmpty { context.insert(Profile(ownerID: user.id)) }
        }
    }
}
