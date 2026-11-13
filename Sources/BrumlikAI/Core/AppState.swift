import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var clients: [Client] = []
    @Published var phonebook: [PhonebookEntry] = []
    @Published var autoDetectEnabled: Bool = AppState.storedBool("autoDetectEnabled", default: true) {
        didSet { UserDefaults.standard.set(autoDetectEnabled, forKey: "autoDetectEnabled") }
    }
    @Published var showAIPrompt: Bool = AppState.storedBool("showAIPrompt", default: false) {
        didSet { UserDefaults.standard.set(showAIPrompt, forKey: "showAIPrompt") }
    }
    @Published var consentAcknowledged: Bool = UserDefaults.standard.bool(forKey: "consentAcknowledged") {
        didSet { UserDefaults.standard.set(consentAcknowledged, forKey: "consentAcknowledged") }
    }
    @Published var defaultCalendarId: String? = UserDefaults.standard.string(forKey: "defaultCalendarId") {
        didSet { UserDefaults.standard.set(defaultCalendarId, forKey: "defaultCalendarId") }
    }
    @Published var defaultRemindersListId: String? = UserDefaults.standard.string(forKey: "defaultRemindersListId") {
        didSet { UserDefaults.standard.set(defaultRemindersListId, forKey: "defaultRemindersListId") }
    }
    @Published var userRole: String = UserDefaults.standard.string(forKey: "userRole") ?? "" {
        didSet { UserDefaults.standard.set(userRole, forKey: "userRole") }
    }
    /// "auto", or an ISO 639-1 code passed to Whisper.
    @Published var callLanguage: String = UserDefaults.standard.string(forKey: "callLanguage") ?? "auto" {
        didSet { UserDefaults.standard.set(callLanguage, forKey: "callLanguage") }
    }
    @Published var lastError: String?

    var deepInfraToken: String? {
        get { Keychain.read(key: "deepinfra_token") }
        set {
            if let value = newValue, !value.isEmpty {
                Keychain.write(key: "deepinfra_token", value: value)
            } else {
                Keychain.delete(key: "deepinfra_token")
            }
            SetupChecklist.shared.tokenChanged()
            objectWillChange.send()
        }
    }

    init() {
        recordings = RecordingStore.load()
        clients = ClientStore.load()
        phonebook = PhonebookStore.load()
        recoverInterruptedRecordings()
    }

    nonisolated static func storedBool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    /// A recording still marked as running means the app quit or crashed mid-way; mark it failed so it can be retried.
    private func recoverInterruptedRecordings() {
        var changed = false
        for index in recordings.indices {
            switch recordings[index].status {
            case .recording:
                recordings[index].status = .failed
                recordings[index].errorMessage = L10n.t(.errInterruptedRecording)
                changed = true
            case .pendingTranscription, .transcribing, .summarizing:
                recordings[index].status = .failed
                recordings[index].errorMessage = L10n.t(.errInterruptedProcessing)
                changed = true
            case .completed, .failed:
                break
            }
        }
        if changed { RecordingStore.save(recordings) }
    }

    // MARK: - Recordings

    func recording(_ id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func appendRecording(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        RecordingStore.save(recordings)
    }

    /// Changes the stored copy in place, so edits made elsewhere in the meantime aren't overwritten.
    func mutateRecording(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
        RecordingStore.save(recordings)
    }

    func deleteRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        RecordingStore.removeFiles(for: recording.id)
        try? FileManager.default.removeItem(at: recording.audioURL)
        RecordingStore.save(recordings)
    }

    func client(for recording: Recording) -> Client? {
        guard let id = recording.clientId else { return nil }
        return clients.first(where: { $0.id == id })
    }

    // MARK: - Clients

    func upsertClient(_ client: Client) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index] = client
        } else {
            clients.insert(client, at: 0)
        }
        ClientStore.save(clients)
    }

    func deleteClient(_ client: Client) {
        clients.removeAll { $0.id == client.id }
        for index in recordings.indices where recordings[index].clientId == client.id {
            recordings[index].clientId = nil
        }
        for index in phonebook.indices where phonebook[index].clientId == client.id {
            phonebook[index].clientId = nil
        }
        ClientStore.save(clients)
        RecordingStore.save(recordings)
        PhonebookStore.save(phonebook)
    }

    // MARK: - Phonebook

    func phonebookEntry(for number: String) -> PhonebookEntry? {
        let needle = PhonebookEntry.normalize(number)
        guard !needle.isEmpty else { return nil }
        if let exact = phonebook.first(where: { $0.number == needle }) { return exact }
        let suffix = needle.suffix(9)
        return phonebook.first { $0.number.hasSuffix(suffix) }
    }

    func upsertPhonebook(number: String, name: String, clientId: UUID?) {
        let normalized = PhonebookEntry.normalize(number)
        guard !normalized.isEmpty else { return }
        let entry = PhonebookEntry(number: normalized, name: name, clientId: clientId, updatedAt: Date())
        if let index = phonebook.firstIndex(where: { $0.number == normalized }) {
            phonebook[index] = entry
        } else {
            phonebook.append(entry)
        }
        PhonebookStore.save(phonebook)

        for index in recordings.indices where PhonebookEntry.normalize(recordings[index].phoneNumber ?? "") == normalized {
            recordings[index].contactName = name
            if let clientId { recordings[index].clientId = clientId }
        }
        RecordingStore.save(recordings)
    }
}
