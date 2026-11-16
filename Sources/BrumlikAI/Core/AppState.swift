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
    /// The call panel recalls the last call with the same caller.
    @Published var showCallBriefing: Bool = AppState.storedBool("showCallBriefing", default: true) {
        didSet { UserDefaults.standard.set(showCallBriefing, forKey: "showCallBriefing") }
    }
    /// Google Meet and WhatsApp calls (in Chrome or the WhatsApp app) are detected and recorded like phone calls.
    @Published var recordOnlineCalls: Bool = AppState.storedBool("recordOnlineCalls", default: true) {
        didSet { UserDefaults.standard.set(recordOnlineCalls, forKey: "recordOnlineCalls") }
    }
    @Published var emailTransport: EmailTransport = EmailTransport(rawValue: UserDefaults.standard.string(forKey: "emailTransport") ?? "") ?? .mail {
        didSet { UserDefaults.standard.set(emailTransport.rawValue, forKey: "emailTransport") }
    }
    @Published var smtpSettings: SMTPSettings = AppState.storedSMTPSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(smtpSettings) {
                UserDefaults.standard.set(data, forKey: "smtpSettings")
            }
        }
    }
    @Published var lastError: String?

    /// Read only when sending or testing, so opening Settings never asks for Keychain access.
    var smtpPassword: String? {
        get { Keychain.read(key: "smtp_password") }
        set {
            if let value = newValue, !value.isEmpty {
                Keychain.write(key: "smtp_password", value: value)
            } else {
                Keychain.delete(key: "smtp_password")
            }
            objectWillChange.send()
        }
    }

    var hasSMTPPassword: Bool { Keychain.exists(key: "smtp_password") }

    nonisolated static func storedSMTPSettings() -> SMTPSettings {
        guard let data = UserDefaults.standard.data(forKey: "smtpSettings"),
              let settings = try? JSONDecoder().decode(SMTPSettings.self, from: data) else { return SMTPSettings() }
        return settings
    }

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
        return phonebook.first { PhonebookEntry.sameNumber($0.number, needle) }
    }

    func upsertPhonebook(number: String, name: String, clientId: UUID?) {
        let normalized = PhonebookEntry.normalize(number)
        guard !normalized.isEmpty else { return }
        // Updated in place, so a number marked private stays private.
        if let index = phonebook.firstIndex(where: { $0.number == normalized })
            ?? phonebook.firstIndex(where: { PhonebookEntry.sameNumber($0.number, normalized) }) {
            phonebook[index].name = name
            phonebook[index].clientId = clientId
            phonebook[index].updatedAt = Date()
        } else {
            phonebook.append(PhonebookEntry(number: normalized, name: name, clientId: clientId))
        }
        PhonebookStore.save(phonebook)

        for index in recordings.indices where PhonebookEntry.sameNumber(recordings[index].phoneNumber ?? "", normalized) {
            recordings[index].contactName = name
            if let clientId { recordings[index].clientId = clientId }
        }
        RecordingStore.save(recordings)
    }

    // MARK: - Private calls

    /// Callers that are never recorded, newest first.
    var privateCallers: [PhonebookEntry] {
        phonebook.filter(\.doNotRecord).sorted { $0.updatedAt > $1.updatedAt }
    }

    func privateRule(number: String?, name: String?) -> PhonebookEntry? {
        PrivateCalls.rule(in: phonebook, number: number, name: name)
    }

    func setDoNotRecord(_ value: Bool, number: String?, name: String?) {
        let updated = PrivateCalls.setting(value, number: number, name: name, in: phonebook)
        guard updated != phonebook else { return }
        phonebook = updated
        PhonebookStore.save(phonebook)
    }

    /// Takes exactly this entry off the private list (other entries with the same name stay).
    func removePrivate(_ entry: PhonebookEntry) {
        guard let index = phonebook.firstIndex(where: { $0.id == entry.id }) else { return }
        phonebook[index].doNotRecord = false
        phonebook[index].updatedAt = Date()
        if PrivateCalls.isObsolete(phonebook[index]) { phonebook.remove(at: index) }
        PhonebookStore.save(phonebook)
    }
}
