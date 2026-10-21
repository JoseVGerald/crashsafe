import Foundation
import SwiftData

/// Mock data for SwiftUI previews.
enum PreviewData {
    static let user = AuthUser(id: "preview-user", name: "Jose Gerald", email: "jose@example.com")

    static func environment(signedIn: Bool = true) -> AppEnvironment {
        let env = AppEnvironment(
            auth: MockAuthService(defaults: UserDefaults(suiteName: "preview")!, latency: .milliseconds(300)),
            crashDetector: MockCrashDetector(),
            assistant: MockAssistantService(latency: .milliseconds(300)),
            voiceInput: MockVoiceInputService(),
            tripPacks: MockTripPackService(),
            alerts: MockEmergencyAlertService(),
            connectivity: ConnectivityMonitor(start: false)
        )
        if signedIn { env.session.forceSignIn(user) }
        return env
    }

    /// In-memory store with a profile, a couple of trips and a check-in.
    static func container(empty: Bool = false) -> ModelContainer {
        let schema = Schema(AppSchema.models)
        let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        guard !empty else { return container }
        let context = container.mainContext

        let profile = Profile(ownerID: user.id,
                              medicalNotes: "Allergic to penicillin. Asthma — inhaler in glovebox.",
                              carMake: "Toyota", carModel: "Camry", carType: .sedan,
                              insurer: "State Farm", policyNumber: "SF-123-456")
        context.insert(profile)
        let mom = FamilyContact(name: "Maria Gerald", phone: "555-0100", relationship: "Mom")
        let bro = FamilyContact(name: "Leo Gerald", phone: "555-0199", relationship: "Brother")
        profile.familyContacts.append(contentsOf: [mom, bro])

        let trip = Trip(ownerID: user.id, origin: "Seattle", destination: "Spokane",
                        startDate: .now, endDate: .now.addingTimeInterval(86_400 * 2))
        trip.isActive = true
        trip.startedAt = .now.addingTimeInterval(-1_800)
        trip.tripPackStatus = .ready
        trip.tripPackSummary = "3 tow companies · 2 hospitals · 3 guides"
        context.insert(trip)

        let later = Trip(ownerID: user.id, origin: "Bellevue", destination: "Portland",
                         startDate: .now.addingTimeInterval(86_400 * 7), endDate: .now.addingTimeInterval(86_400 * 9))
        context.insert(later)

        context.insert(CheckInRecord(ownerID: user.id, outcome: .ok, wasSimulated: true,
                                     date: .now.addingTimeInterval(-3_600 * 5)))
        try? context.save()
        return container
    }
}
