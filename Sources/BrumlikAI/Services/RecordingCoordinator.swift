import Foundation
import AVFoundation
import Combine
import UserNotifications

enum ProcessingError: LocalizedError {
    case emptyTranscript
    case audioMissing

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return L10n.t(.errEmptyTranscript)
        case .audioMissing: return L10n.t(.errAudioMissing)
        }
    }
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    struct ChunkProgress: Equatable {
        let recordingId: UUID
        let current: Int
        let total: Int
    }

    @Published private(set) var isRecording = false
    @Published private(set) var activeRecordingId: UUID?
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var chunkProgress: ChunkProgress?
    @Published private(set) var processingIds: Set<UUID> = []

    var notificationsEnabled = true
    private(set) var lastCapture: AudioRecorder.Result?

    private let appState: AppState
    private let recorder = AudioRecorder()
    private let calendar = CalendarService()
    private let reminders = RemindersService()
    private let contacts = ContactsService()
    private let deepInfra = DeepInfraClient { Keychain.read(key: "deepinfra_token") }

    private var durationTimer: Timer?
    private var startedAt: Date?
    private var autoStarted = false

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Recording

    func toggleManual() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording(callerHint: nil, auto: false)
            }
        }
    }

    func handleCallEvent(_ event: CallEvent) {
        switch event {
        case .started(let hint):
            // Never record on its own before onboarding is done and the user agreed to tell callers.
            guard !isRecording, appState.consentAcknowledged,
                  UserDefaults.standard.bool(forKey: "onboardingCompleted") else { return }
            Task { await startRecording(callerHint: hint, auto: true) }
        case .ended:
            guard isRecording, autoStarted else { return }
            Task { await stopRecording() }
        }
    }

    func startRecording(callerHint: String?, auto: Bool) async {
        guard !isRecording else { return }
        // Until access is decided, macOS hands the app only silence, so ask before the recording starts.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard !isRecording else { return }
        let id = UUID()
        do {
            try recorder.start(recordingId: id, mode: auto ? .callFocused : .allExceptSelf)
        } catch {
            appState.lastError = error.localizedDescription
            notify(error.localizedDescription)
            return
        }

        isRecording = true
        autoStarted = auto
        activeRecordingId = id
        let start = Date()
        startedAt = start
        appState.appendRecording(Recording(id: id, startedAt: start, audioURL: RecordingStore.mixedURL(for: id), status: .recording))
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.currentDuration = Date().timeIntervalSince(startedAt)
            }
        }
        notify(L10n.t(.notifRecordingStarted))

        let caller = await resolveCaller(hint: callerHint)
        guard caller.number != nil || caller.name != nil else { return }
        appState.mutateRecording(id) { recording in
            recording.phoneNumber = caller.number
            recording.contactName = caller.name
            if recording.clientId == nil { recording.clientId = caller.clientId }
        }
    }

    /// Stops the running recording and, unless told otherwise, processes it right away.
    @discardableResult
    func stopRecording(process shouldProcess: Bool = true) async -> UUID? {
        guard isRecording, let id = activeRecordingId else { return nil }
        isRecording = false
        autoStarted = false
        activeRecordingId = nil
        durationTimer?.invalidate()
        durationTimer = nil
        startedAt = nil
        currentDuration = 0

        do {
            let capture = try recorder.stop()
            lastCapture = capture
            if let peak = capture.systemPeak, peak > SystemAudioTap.silenceThreshold {
                SetupChecklist.shared.markSystemAudioWorking()
            }
            appState.mutateRecording(id) { recording in
                recording.endedAt = Date()
                recording.status = .pendingTranscription
                recording.audioWarning = capture.warnings.isEmpty ? nil : capture.warnings.joined(separator: "\n")
            }
        } catch {
            markFailed(id, error)
            return id
        }

        if shouldProcess { await process(recordingId: id) }
        return id
    }

    // MARK: - Processing

    func retry(recordingId: UUID) {
        Task { await process(recordingId: recordingId) }
    }

    /// Mix → transcribe → summarise. Steps that already have a result are skipped, so a retry continues where it failed.
    func process(recordingId id: UUID) async {
        guard !processingIds.contains(id), appState.recording(id) != nil else { return }
        processingIds.insert(id)
        defer { processingIds.remove(id) }
        appState.mutateRecording(id) { $0.errorMessage = nil }

        do {
            let audioURL = try await prepareAudio(for: id)

            if appState.recording(id)?.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                appState.mutateRecording(id) { $0.status = .transcribing }
                let language = appState.callLanguage == "auto" ? nil : appState.callLanguage
                let transcript = try await deepInfra.transcribe(audio: audioURL, language: language) { [weak self] current, total in
                    Task { @MainActor in
                        self?.chunkProgress = total > 1 ? ChunkProgress(recordingId: id, current: current, total: total) : nil
                    }
                }
                chunkProgress = nil
                guard !transcript.isEmpty else { throw ProcessingError.emptyTranscript }
                appState.mutateRecording(id) { $0.transcript = transcript }
            }

            guard let recording = appState.recording(id), let transcript = recording.transcript else { return }
            appState.mutateRecording(id) { $0.status = .summarizing }
            let summary = try await deepInfra.summarize(
                transcript: transcript,
                clientContext: appState.client(for: recording)?.aiContext(),
                userRole: userRole,
                language: AppLanguage.current,
                now: Date()
            )
            appState.mutateRecording(id) { recording in
                recording.summary = summary
                recording.status = .completed
            }
            notify(L10n.t(summary.meeting == nil ? .notifSummarised : .notifSummarisedMeeting))
        } catch {
            chunkProgress = nil
            markFailed(id, error)
            notify(L10n.t(.notifFailed))
        }
    }

    /// Returns the single mixed audio file of a recording, mixing its parts first when needed.
    func prepareAudio(for id: UUID) async throws -> URL {
        let fileManager = FileManager.default
        let mixed = RecordingStore.mixedURL(for: id)
        if fileManager.fileExists(atPath: mixed.path) { return mixed }
        if let legacy = appState.recording(id)?.audioURL, legacy != mixed, legacy.pathExtension != "caf",
           fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }

        let parts = [RecordingStore.systemPartURL(for: id), RecordingStore.micPartURL(for: id)]
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !parts.isEmpty else { throw ProcessingError.audioMissing }
        appState.mutateRecording(id) { $0.status = .pendingTranscription }
        try await AudioMixer.mix(parts, to: mixed)
        RecordingStore.removeParts(for: id)
        appState.mutateRecording(id) { $0.audioURL = mixed }
        return mixed
    }

    private func markFailed(_ id: UUID, _ error: Error) {
        appState.mutateRecording(id) { recording in
            recording.status = .failed
            recording.errorMessage = error.localizedDescription
        }
    }

    private var userRole: String? {
        let role = appState.userRole.trimmingCharacters(in: .whitespacesAndNewlines)
        return role.isEmpty ? nil : role
    }

    // MARK: - Client & caller

    func assignClient(_ clientId: UUID?, to recordingId: UUID) async {
        appState.mutateRecording(recordingId) { $0.clientId = clientId }
        if let recording = appState.recording(recordingId),
           let phone = recording.phoneNumber, !phone.isEmpty,
           let name = recording.contactName, !name.isEmpty {
            appState.upsertPhonebook(number: phone, name: name, clientId: clientId)
        }
        await regeneratePrompt(for: recordingId)
    }

    /// Saves name, company and number for the recording and remembers them in the phonebook for future calls.
    func updateCaller(for recordingId: UUID, phoneNumber: String, contactName: String, clientId: UUID?) async {
        let phone = PhonebookEntry.normalize(phoneNumber)
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.mutateRecording(recordingId) { recording in
            recording.phoneNumber = phone.isEmpty ? nil : phone
            recording.contactName = name.isEmpty ? nil : name
            recording.clientId = clientId
        }
        if !phone.isEmpty, !name.isEmpty {
            appState.upsertPhonebook(number: phone, name: name, clientId: clientId)
        }
        await regeneratePrompt(for: recordingId)
    }

    private func regeneratePrompt(for id: UUID) async {
        guard appState.showAIPrompt, let recording = appState.recording(id), let summary = recording.summary else { return }
        do {
            let prompt = try await deepInfra.regenerateAIPrompt(
                humanSummary: summary.humanSummary,
                requests: summary.requests,
                clientContext: appState.client(for: recording)?.aiContext(),
                userRole: userRole,
                language: AppLanguage.current
            )
            appState.mutateRecording(id) { $0.summary?.aiPrompt = prompt }
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    // MARK: - Calendar & Reminders

    func saveTask(_ task: TaskProposal, for recording: Recording) async -> Bool {
        do {
            _ = try await reminders.createReminder(
                from: task,
                clientName: appState.client(for: recording)?.name,
                listId: appState.defaultRemindersListId
            )
            return true
        } catch {
            appState.lastError = error.localizedDescription
            return false
        }
    }

    func saveMeeting(_ meeting: MeetingProposal, for recording: Recording) async -> Bool {
        do {
            _ = try await calendar.createEvent(from: meeting, calendarId: appState.defaultCalendarId)
            notify(L10n.t(.notifMeetingAdded))
            return true
        } catch {
            appState.lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Turns a hint ("+420 777 123 456", "Jan Novák") into number, name and client — the BrumlikAI phonebook
    /// wins over macOS Contacts.
    private func resolveCaller(hint: String?) async -> (number: String?, name: String?, clientId: UUID?) {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else {
            return (nil, nil, nil)
        }
        guard CallerDetector.looksLikePhoneNumber(hint) else { return (nil, hint, nil) }

        let number = PhonebookEntry.normalize(hint)
        if let entry = appState.phonebookEntry(for: number) {
            return (number, entry.name, entry.clientId)
        }
        return (number, await contacts.name(for: number), nil)
    }

    private func notify(_ body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "BrumlikAI"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension ISO8601DateFormatter {
    static let brumlik: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}
