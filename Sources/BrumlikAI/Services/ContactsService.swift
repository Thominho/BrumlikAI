import Foundation
import Contacts

/// Čte jméno kontaktu podle telefonního čísla z macOS Kontaktů.
/// Vyžaduje NSContactsUsageDescription v Info.plist.
@MainActor
final class ContactsService {
    private let store = CNContactStore()

    func requestAccess() async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            return true
        }
        return await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    /// Hledá kontakt podle čísla. Vrací první shodu.
    func name(for phoneNumber: String) async -> String? {
        guard await requestAccess() else { return nil }

        let needle = PhonebookEntry.normalize(phoneNumber)
        guard !needle.isEmpty else { return nil }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        // CNContact.predicateForContacts(matching:) používá CNPhoneNumber shodu,
        // která respektuje mezinárodní formát — spolehlivější než vlastní porovnání.
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber))
        if let results = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
           let first = results.first {
            return Self.displayName(for: first)
        }

        // Fallback: projít všechny kontakty a porovnat normalizovaná čísla
        var match: CNContact?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            for phone in contact.phoneNumbers {
                if PhonebookEntry.normalize(phone.value.stringValue).hasSuffix(needle.suffix(9)) {
                    match = contact
                    stop.pointee = true
                    return
                }
            }
        }
        return match.map { Self.displayName(for: $0) }
    }

    private static func displayName(for contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return contact.phoneNumbers.first?.value.stringValue ?? ""
    }
}
