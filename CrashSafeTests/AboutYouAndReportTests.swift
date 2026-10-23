import Foundation
import HealthKit
import Testing
@testable import CrashSafe

struct AboutYouTests {
    @Test func peopleNervesAndPastCrashesPickTheCalmNudge() {
        let result = CoachingStyle.recommended(experience: .experienced, passengers: .kids, feeling: .nervous, pastCrash: nil, purpose: nil)
        #expect(result.style == .emotional)
        #expect(result.reasons == ["kids ride with you", "driving makes you nervous"])
    }

    @Test func newDriversWhoDriveForWorkGetTheFacts() {
        let result = CoachingStyle.recommended(experience: .newDriver, passengers: .alone, feeling: .confident, pastCrash: PastCrash.none, purpose: .work)
        #expect(result.style == .logical)
        #expect(result.reasons.count == 2)
    }

    @Test func tiesAndNoAnswersGoToTheFacts() {
        #expect(CoachingStyle.recommended(experience: .veteran, passengers: nil, feeling: nil, pastCrash: nil, purpose: nil).style == .logical)
        // One point each way: facts.
        #expect(CoachingStyle.recommended(experience: .learner, passengers: .adults, feeling: .okay, pastCrash: nil, purpose: nil).style == .logical)
    }

    @Test func insurerPresetsAreTheBigCarriersWithClaimsLines() {
        #expect(InsurerPreset.all.count == 10)
        #expect(Set(InsurerPreset.all.map(\.name)).count == 10)
        #expect(InsurerPreset.all.allSatisfy { $0.claimsPhone.filter(\.isNumber).count == 10 })
        #expect(InsurerPreset.all.prefix(3).map(\.name) == ["State Farm", "GEICO", "Progressive"])
    }
}

struct ImpactReportTests {
    private func facts(simulated: Bool = false, medical: String? = nil) -> ImpactReportFacts {
        let impact = ImpactReport(peakG: 6.2, pulseDuration: 0.12, deltaVMPS: 8.0, preImpactSpeedMPS: 14.3,
                                  postImpactSpeedMPS: 0, timeToStop: 2.1, stopBasis: "gps", averageStopDecelerationG: 0.7,
                                  severity: .moderate, isSimulated: simulated)
        let snapshot = CrashSnapshot(date: Date(timeIntervalSince1970: 1_792_800_000), peakG: 6.2, speedDropMPH: 18,
                                     impact: impact, latitude: 45.5231, longitude: -122.6765, accuracyMeters: 8,
                                     street: "123 Main St", place: "Portland, OR", weather: "Rain, 48°F, dark",
                                     isSimulated: simulated)
        return ImpactReportFacts(snapshot: snapshot, outcome: .ok, driverName: "Jose Gerald", vehicle: "2019 Toyota Camry, silver, plate ABC123",
                                 insurer: "State Farm", policyNumber: "12-3456", claimsPhone: "(800) 732-5246",
                                 otherPlate: "XYZ987", medical: medical)
    }

    @Test func policeAndInsurerCopyHasTheFactsAndNoFault() {
        let text = facts().officialText
        for expected in ["Location: 123 Main St, Portland, OR (45.52310, -122.67650 ±8 m)", "Conditions: Rain, 48°F, dark",
                         "Driver: Jose Gerald", "Vehicle: 2019 Toyota Camry, silver, plate ABC123",
                         "Insurance: State Farm · Policy 12-3456 · Claims (800) 732-5246",
                         "moderate, peak 6.2 g, speed change about 18 mph over 120 ms, speed before about 32 mph (GPS), stopped 2.1 s later",
                         "Driver check-in: driver answered \"I'm okay\"", "Other vehicle plate: XYZ987", ImpactReportFacts.disclaimer] {
            #expect(text.contains(expected), "\(expected)")
        }
        #expect(!text.lowercased().contains("fault:") && !text.contains("Medical:") && !text.contains("TEST"))
        #expect(!text.contains("Other driver:"))  // blank details stay out
    }

    @Test func medicalAndTestCrashesAreMarked() {
        let text = facts(simulated: true, medical: "blood type O+").officialText
        #expect(text.contains("(TEST, SIMULATED DATA)") && text.contains("Medical: blood type O+"))
    }

    @Test func personalCopyIsPlainWords() {
        let lines = facts().whatHappened
        #expect(lines.first == "Your car's speed changed by about 18 mph in a split second (about 0.12 s).")
        #expect(lines.contains("You were going about 32 mph just before."))
        #expect(facts().headline.hasPrefix("Moderate impact"))
    }
}

@MainActor
struct AppleHealthImportTests {
    @Test func healthFillsTheProfileWithoutOverwritingWhatWasTyped() {
        let profile = Profile(ownerID: "u1", medicalNotes: "Allergic to penicillin. Takes Lisinopril.")
        profile.ageBand = .adult
        let filled = profile.apply(.init(bloodType: "O−", ageBand: .senior, medications: ["Lisinopril", "Metformin"]))
        #expect(profile.bloodType == "O−")
        #expect(profile.ageBand == .adult)  // already answered
        #expect(profile.medicalNotes == "Allergic to penicillin. Takes Lisinopril.\nMedications: Metformin")
        #expect(filled == ["blood type O−", "1 medication"])
        #expect(profile.apply(.init(bloodType: "O−", ageBand: nil, medications: ["metformin"])).isEmpty)  // nothing new
    }

    @Test func birthdaysAndBloodTypesMapLikeTheProfile() {
        #expect(AgeBand(age: 17) == .teen && AgeBand(age: 22) == .young && AgeBand(age: 44) == .adult)
        #expect(AgeBand(age: 64) == .midlife && AgeBand(age: 80) == .senior)
        #expect(AppleHealthImport.label(.abNegative) == "AB−" && AppleHealthImport.label(.notSet) == nil)
    }
}
