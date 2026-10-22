import Contacts
import ContactsUI
import UIKit

/// Apple's contact picker. It runs outside the app's process, so it needs no Contacts permission and
/// CrashSafe only ever sees the one name and phone number the person picks.
@MainActor
enum ContactPicker {
    struct Picked: Equatable, Identifiable {
        var id: String { name + phone }
        var name: String
        var phone: String
        /// From the contact's "related names" when the person set one for themselves (e.g. "mother").
        var relationship: String
    }

    /// Shows the picker over the current screen; nil if the person cancels.
    static func pickPhone() async -> Picked? {
        guard let presenter = topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let delegate = Delegate { picked in continuation.resume(returning: picked) }
            let picker = CNContactPickerViewController()
            picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
            picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
            // Contacts with a single number are picked with one tap; others show their numbers.
            picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
    }

    static func picked(from contact: CNContact, phone: CNPhoneNumber?) -> Picked? {
        guard let number = phone ?? contact.phoneNumbers.first?.value else { return nil }
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.givenName
        return Picked(name: name.trimmingCharacters(in: .whitespaces),
                      phone: PhoneFormat.display(number.stringValue),
                      relationship: "")
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Delegate: NSObject, CNContactPickerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        private var finish: ((Picked?) -> Void)?

        init(finish: @escaping (Picked?) -> Void) { self.finish = finish }

        private func complete(_ picked: Picked?) {
            finish?(picked)
            finish = nil
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            complete(ContactPicker.picked(from: contact, phone: nil))
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            complete(ContactPicker.picked(from: contactProperty.contact, phone: contactProperty.value as? CNPhoneNumber))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            complete(nil)
        }
    }
}
