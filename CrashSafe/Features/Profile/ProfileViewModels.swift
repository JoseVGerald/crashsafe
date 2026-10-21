import Foundation
import Observation
import SwiftData

@Observable
final class AddContactViewModel {
    var name = ""
    var phone = ""
    var relationship = ""
    private(set) var submitAttempted = false

    var nameError: String? {
        submitAttempted && name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name." : nil
    }

    var phoneError: String? {
        submitAttempted ? Validation.phone(phone) : nil
    }

    /// Adds the contact to `profile` if the form is valid. Returns whether it was added.
    func add(to profile: Profile) -> Bool {
        submitAttempted = true
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, Validation.phone(phone) == nil else { return false }
        let contact = FamilyContact(name: name.trimmingCharacters(in: .whitespaces),
                                    phone: phone.trimmingCharacters(in: .whitespaces),
                                    relationship: relationship.trimmingCharacters(in: .whitespaces))
        profile.modelContext?.insert(contact)
        profile.familyContacts.append(contact)
        return true
    }
}

extension Validation {
    static func phone(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        if digits.isEmpty { return "Enter a phone number." }
        return digits.count < 7 ? "That phone number looks too short." : nil
    }
}
