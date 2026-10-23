import Foundation
import HealthKit

/// Prefills the safety profile from Apple Health: read-only, and only what the person allows. Blood type,
/// birthday (for the age question) and, on iOS 26 and later, the medications they track in Health.
/// Apple's Medical ID (its notes and emergency contacts) and Family Sharing aren't available to apps, so
/// those stay typed in or picked from Contacts.
@MainActor
final class AppleHealthImport {
    struct Found: Equatable {
        var bloodType: String?
        var ageBand: AgeBand?
        var medications: [String] = []

        var isEmpty: Bool { bloodType == nil && ageBand == nil && medications.isEmpty }
    }

    enum Failure: LocalizedError {
        case unavailable, notAllowed
        var errorDescription: String? {
            switch self {
            case .unavailable: "Apple Health isn't available on this device."
            case .notAllowed: "CrashSafe can't read Apple Health in this build yet."
            }
        }
    }

    /// Health exists on this device and this build is signed with the HealthKit capability.
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable() && Bundle.main.object(forInfoDictionaryKey: "PulseHealthImport") as? String == "YES"
    }

    private let store = HKHealthStore()

    /// Asks for permission (the system sheet lists each item) and reads what was allowed.
    func read(now: Date = .now) async throws -> Found {
        guard Self.isAvailable else { throw Failure.unavailable }
        // Medications are not allowed in this request (iOS throws); they get their own per-item prompt below.
        let types: Set<HKObjectType> = [HKCharacteristicType(.bloodType), HKCharacteristicType(.dateOfBirth)]
        do {
            try await store.requestAuthorization(toShare: [], read: types)
        } catch {
            throw Failure.notAllowed  // e.g. a build signed without the HealthKit capability
        }

        var found = Found()
        // Health hides whether reading was refused: a refused or empty value simply reads as "not set".
        if let blood = try? store.bloodType().bloodType { found.bloodType = Self.label(blood) }
        if let birth = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: birth),
           let years = Calendar.current.dateComponents([.year], from: date, to: now).year {
            found.ageBand = AgeBand(age: years)
        }
        if #available(iOS 26.0, *) {
            // The person picks which medications CrashSafe may see.
            try? await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
            let medications = (try? await HKUserAnnotatedMedicationQueryDescriptor(limit: 30).result(for: store)) ?? []
            found.medications = medications.filter { !$0.isArchived }.map { $0.nickname ?? $0.medication.displayText }
        }
        return found
    }

    /// Health's blood types, written the way the profile shows them ("A−" uses a true minus sign).
    static func label(_ type: HKBloodType) -> String? {
        switch type {
        case .aPositive: "A+"
        case .aNegative: "A−"
        case .bPositive: "B+"
        case .bNegative: "B−"
        case .abPositive: "AB+"
        case .abNegative: "AB−"
        case .oPositive: "O+"
        case .oNegative: "O−"
        case .notSet: nil
        @unknown default: nil
        }
    }
}

extension AgeBand {
    init?(age: Int) {
        switch age {
        case ..<0: return nil
        case ..<20: self = .teen
        case ..<25: self = .young
        case ..<45: self = .adult
        case ..<65: self = .midlife
        default: self = .senior
        }
    }
}

extension Profile {
    /// Fills in what Health had, without overwriting what the person already typed. Returns what changed,
    /// in plain words.
    @discardableResult
    func apply(_ found: AppleHealthImport.Found) -> [String] {
        var filled: [String] = []
        if let blood = found.bloodType, bloodType != blood {
            bloodType = blood
            filled.append("blood type \(blood)")
        }
        if let band = found.ageBand, ageBand == nil {
            ageBand = band
            filled.append("age")
        }
        let new = found.medications.filter { !medicalNotes.localizedCaseInsensitiveContains($0) }
        if !new.isEmpty {
            let line = "Medications: " + new.joined(separator: ", ")
            medicalNotes = medicalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? line : medicalNotes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + line
            filled.append(new.count == 1 ? "1 medication" : "\(new.count) medications")
        }
        return filled
    }
}
