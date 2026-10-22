import Foundation

extension AssistantContext {
    /// Everything Pulse may use, built from the on-device profile and live services.
    static func make(user: AuthUser, profile: Profile?, activeTrip: Trip?, isOnline: Bool,
                     scenario: AssistantScenario = .general, incident: AssistantIncident? = nil) -> AssistantContext {
        AssistantContext(
            userName: user.name,
            isOnline: isOnline,
            scenario: scenario,
            carDescription: profile?.primaryVehicle?.displayName ?? "",
            insurer: profile?.insurer ?? "",
            medicalNotes: profile?.medicalNotes ?? "",
            familyContactNames: profile?.sortedContacts.map(\.name) ?? [],
            currentTrip: activeTrip?.routeLabel,
            responseStyle: profile?.coachingStyle == .emotional ? "supportive" : "practical",
            jurisdiction: "UNKNOWN",
            assistanceStage: scenario == .general ? "followup" : "active",
            incident: incident
        )
    }
}
