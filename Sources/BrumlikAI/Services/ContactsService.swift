import Foundation
import Contacts

/// Where the coordinator looks callers up; tests use a fake instead of the user's Contacts.
@MainActor
protocol CallerDirectory: AnyObject {
    func name(for phoneNumber: String) async -> String?
    func numbers(forName name: String) async -> [String]
}

/// Čte jméno kontaktu podle telefonního čísla z macOS Kontaktů.
/// Vyžaduje NSContactsUsageDescription v Info.plist.
/// Lookups run off the main thread, because a call is waiting on them and the address book can be large.
@MainActor
final class ContactsService: CallerDirectory {
    /// Lookups during a call never ask for access — the setup guide does that.
    nonisolated static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Hledá kontakt podle čísla. Vrací první shodu.
    func name(for phoneNumber: String) async -> String? {
        guard Self.isAuthorized, !PhonebookEntry.normalize(phoneNumber).isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.lookUpName(for: phoneNumber)
        }.value
    }

    /// Numbers of the contacts called exactly this name — the call window often shows only the name.
    func numbers(forName name: String) async -> [String] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAuthorized, !wanted.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.lookUpNumbers(forName: wanted)
        }.value
    }

    private nonisolated static func lookUpName(for phoneNumber: String) -> String? {
        let store = CNContactStore()
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
            return displayName(for: first)
        }

        // Fallback: projít všechny kontakty a porovnat normalizovaná čísla
        var match: CNContact?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            if contact.phoneNumbers.contains(where: { PhonebookEntry.sameNumber($0.value.stringValue, phoneNumber) }) {
                match = contact
                stop.pointee = true
            }
        }
        return match.map { displayName(for: $0) }
    }

    private nonisolated static func lookUpNumbers(forName wanted: String) -> [String] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingName: wanted)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { return [] }

        return contacts
            .filter { contact in
                let given = contact.givenName, family = contact.familyName
                let variants = [
                    [given, family].filter { !$0.isEmpty }.joined(separator: " "),
                    [family, given].filter { !$0.isEmpty }.joined(separator: " "),
                    contact.nickname,
                    contact.organizationName
                ]
                return variants.contains { PhonebookEntry.sameName($0, wanted) }
            }
            .flatMap { $0.phoneNumbers.map { PhonebookEntry.normalize($0.value.stringValue) } }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func displayName(for contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return contact.phoneNumbers.first?.value.stringValue ?? ""
    }
}
