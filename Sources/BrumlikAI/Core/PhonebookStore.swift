import Foundation

/// Lokální telefonní seznam — uživatelem přejmenovaná čísla a jejich propojení s klientem.
/// Přetíží vše, co BrumlikAI zjistí z Kontaktů.
enum PhonebookStore {
    private static var fileURL: URL {
        RecordingStore.storageDirectory.appendingPathComponent("phonebook.json")
    }

    static func load() -> [PhonebookEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.brumlik.decode([PhonebookEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [PhonebookEntry]) {
        if let data = try? JSONEncoder.brumlik.encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
