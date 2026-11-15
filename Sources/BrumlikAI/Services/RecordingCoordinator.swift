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

/// Who is on the line, as far as BrumlikAI knows.
struct CallerLabel: Equatable {
    var name: String?
    var number: String?

    init(name: String? = nil, number: String? = nil) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedNumber = number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmedName.isEmpty ? nil : trimmedName
        self.number = PhonebookEntry.normalize(trimmedNumber).isEmpty ? nil : trimmedNumber
    }

    /// The raw text from the call window: either a number or a name.
    init(hint: String?) {
        let text = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if CallerDetector.looksLikePhoneNumber(text) {
            self.init(number: text)
        } else {
            self.init(name: text)
        }
    }

    var isEmpty: Bool { name == nil && number == nil }
    var title: String? { name ?? number }
    /// The number shown under the name, when both are known.
    var subtitle: String? { name == nil ? nil : number }
}

/// What the floating call panel shows.
enum CallOverlay: Equatable {
    /// A call is being recorded and can still be marked private. `briefing` recalls the last call with this caller.
    case recording(CallerLabel, briefing: CallBriefing? = nil)
    /// The call was marked private and its recording deleted; `canRemember` offers to never record this caller.
    case discarded(CallerLabel, canRemember: Bool)
    /// The caller was just added to the private list.
    case remembered(CallerLabel)
    /// The caller is on the private list, so this call isn't recorded.
    case skipped(CallerLabel)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
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
    @Published private(set) var overlay: CallOverlay?
    /// The running recording was started by a detected call (and ends with it).
    @Published private(set) var autoStarted = false

    var notificationsEnabled = true
    private(set) var lastCapture: AudioRecorder.Result?

    private let appState: AppState
    private let recorder: CallAudioRecorder
    private let calendar = CalendarService()
    private let reminders = RemindersService()
    private let contacts: CallerDirectory
    private let deepInfra: DeepInfraClient
    private let transcriber: CallTranscriber
    private let makeSMTPTransport: () -> SMTPTransport

    private var durationTimer: Timer?
    private var startedAt: Date?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    /// The call the detector reported, while it lasts.
    private var currentCallHint: String?
    private var currentCaller = CallerLabel()
    private var currentBriefing: CallBriefing?
    private var callSerial = 0
    private var overlayToken = UUID()

    /// Tests pass fakes for the recorder, Contacts, speech-to-text, the API token and the SMTP connection.
    init(
        appState: AppState,
        recorder: CallAudioRecorder? = nil,
        contacts: CallerDirectory? = nil,
        speech: SpeechTranscribing? = nil,
        deepInfraToken: (() -> String?)? = nil,
        smtpTransport: (() -> SMTPTransport)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder ?? AudioRecorder()
        self.contacts = contacts ?? ContactsService()
        let deepInfra = DeepInfraClient(token: deepInfraToken ?? { Keychain.read(key: "deepinfra_token") })
        self.deepInfra = deepInfra
        self.transcriber = CallTranscriber(engine: speech ?? deepInfra)
        self.makeSMTPTransport = smtpTransport ?? { StreamTaskTransport() }
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
        callSerial += 1
        let serial = callSerial
        switch event {
        case .started(let hint):
            currentCallHint = hint
            currentCaller = CallerLabel(hint: hint)
            // Never record on its own before onboarding is done and the user agreed to tell callers.
            guard !isRecording, appState.consentAcknowledged,
                  UserDefaults.standard.bool(forKey: "onboardingCompleted") else { return }
            Task {
                // Who is calling is looked up once: for the private list and for the recording.
                let caller = await resolveCaller(hint: hint)
                let rule = await privateRule(forHint: hint, resolved: caller)
                guard serial == callSerial, !isRecording else { return }
                if let rule {
                    showOverlay(.skipped(label(for: rule, hint: hint)), hideAfter: 10)
                } else {
                    await startRecording(callerHint: hint, auto: true, resolved: caller)
                }
            }
        case .ended:
            currentCallHint = nil
            currentCaller = CallerLabel()
            switch overlay {
            case .skipped:
                showOverlay(nil)
            case .some(.discarded(let caller, canRemember: true)):
                // Leave the question up a little after hanging up, then let it go.
                showOverlay(.discarded(caller, canRemember: true), hideAfter: 12)
            default:
                break
            }
            guard isRecording, autoStarted else { return }
            Task { await stopRecording() }
        }
    }

    typealias ResolvedCaller = (number: String?, name: String?, clientId: UUID?)

    /// `resolved` skips the caller lookup when the call handler has done it already.
    func startRecording(callerHint: String?, auto: Bool, resolved: ResolvedCaller? = nil) async {
        guard !isRecording else { return }
        await recorder.requestAccessIfNeeded()
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
        if auto {
            if let resolved {
                // Keep the number as the call window wrote it; it reads better than the normalised one.
                currentCaller = CallerLabel(name: resolved.name, number: currentCaller.number ?? resolved.number)
            }
            currentBriefing = briefing(for: resolved, excluding: id)
            // The floating panel says it's recording, recalls the last call and offers "Private – don't record".
            showOverlay(.recording(currentCaller, briefing: currentBriefing))
        } else {
            notify(L10n.t(.notifRecordingStarted))
        }

        let caller: ResolvedCaller
        if let resolved {
            caller = resolved
        } else {
            caller = await resolveCaller(hint: callerHint)
        }
        guard caller.number != nil || caller.name != nil else { return }
        appState.mutateRecording(id) { recording in
            recording.phoneNumber = caller.number
            recording.contactName = caller.name
            if recording.clientId == nil { recording.clientId = caller.clientId }
        }
        if auto, activeRecordingId == id {
            // Keep the number as the call window wrote it; it reads better than the normalised one.
            currentCaller = CallerLabel(name: caller.name, number: currentCaller.number ?? caller.number)
            currentBriefing = briefing(for: caller, excluding: id)
            if overlay?.isRecording == true { showOverlay(.recording(currentCaller, briefing: currentBriefing)) }
        }
    }

    /// What the panel recalls about the last summarised call with this caller, when the user wants it.
    private func briefing(for caller: ResolvedCaller?, excluding id: UUID) -> CallBriefing? {
        guard appState.showCallBriefing else { return nil }
        let previous = CallHistory.previousCall(
            in: appState.recordings,
            number: caller?.number ?? currentCaller.number,
            name: caller?.name ?? currentCaller.name,
            clientId: caller?.clientId,
            excluding: id
        )
        return previous.flatMap { CallHistory.briefing(from: $0) }
    }

    /// Stops the running recording and, unless told otherwise, processes it right away.
    @discardableResult
    func stopRecording(process shouldProcess: Bool = true) async -> UUID? {
        guard isRecording, let id = activeRecordingId else { return nil }
        resetRecordingState()
        if overlay?.isRecording == true { showOverlay(nil) }

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

    private func resetRecordingState() {
        isRecording = false
        autoStarted = false
        activeRecordingId = nil
        currentBriefing = nil
        durationTimer?.invalidate()
        durationTimer = nil
        startedAt = nil
        currentDuration = 0
    }

    // MARK: - Private calls

    /// "Private – don't record": stops the recording and deletes it on the spot. Nothing is kept or sent.
    func discardRecording() async {
        guard isRecording, let id = activeRecordingId else { return }
        let wasCall = autoStarted
        resetRecordingState()
        _ = try? recorder.stop()
        if let recording = appState.recording(id) {
            appState.deleteRecording(recording)
        } else {
            RecordingStore.removeFiles(for: id)
        }

        let caller = wasCall ? currentCaller : CallerLabel()
        let canRemember = !caller.isEmpty && appState.privateRule(number: caller.number, name: caller.name) == nil
        showOverlay(.discarded(caller, canRemember: canRemember), hideAfter: canRemember ? 45 : 6)
    }

    /// Answer to "Never record this number?" right after a call was marked private.
    func rememberDiscardedCaller() {
        guard case .discarded(let caller, canRemember: true) = overlay else { return }
        appState.setDoNotRecord(true, number: caller.number, name: caller.name)
        showOverlay(.remembered(caller), hideAfter: 6)
    }

    /// The caller is on the private list, but the user wants this call recorded after all.
    func recordAnyway() {
        guard case .skipped = overlay, !isRecording else { return }
        let hint = currentCallHint
        showOverlay(nil)
        Task { await startRecording(callerHint: hint, auto: true) }
    }

    func dismissOverlay() {
        showOverlay(nil)
    }

    /// Diagnostics only (`--preview-call-panel`): shows a panel state without any call or recording.
    func previewOverlay(_ value: CallOverlay?) {
        showOverlay(value)
    }

    /// Removes a call from the history. The one being recorded is discarded like a private call,
    /// and one still being processed stops uploading.
    func deleteRecording(_ id: UUID) async {
        if activeRecordingId == id {
            await discardRecording()
            return
        }
        processingTasks[id]?.cancel()
        guard let recording = appState.recording(id) else { return }
        appState.deleteRecording(recording)
    }

    /// The private-list entry that covers the caller shown in the call window, if any.
    /// `resolved` is what the phonebook and Contacts know about that caller.
    func privateRule(forHint hint: String?, resolved: ResolvedCaller? = nil) async -> PhonebookEntry? {
        let shown = CallerLabel(hint: hint)
        guard !shown.isEmpty else { return nil }
        let caller: ResolvedCaller
        if let resolved {
            caller = resolved
        } else {
            caller = await resolveCaller(hint: hint)
        }
        // By number, or by the name the number is saved under — the person may be on the list by name only.
        if let rule = appState.privateRule(number: shown.number, name: shown.name ?? caller.name) { return rule }

        if let name = shown.name {
            // macOS often shows only the contact's name; one of their numbers may be on the list.
            for number in await contacts.numbers(forName: name) {
                if let rule = appState.privateRule(number: number, name: nil) { return rule }
            }
        }
        return nil
    }

    private func label(for rule: PhonebookEntry, hint: String?) -> CallerLabel {
        let shown = CallerLabel(hint: hint)
        return CallerLabel(
            name: rule.name.isEmpty ? shown.name : rule.name,
            number: rule.number.isEmpty ? shown.number : rule.number
        )
    }

    private func showOverlay(_ value: CallOverlay?, hideAfter seconds: TimeInterval? = nil) {
        overlay = value
        let token = UUID()
        overlayToken = token
        guard value != nil, let seconds else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.overlayToken == token else { return }
            self.overlay = nil
        }
    }

    // MARK: - Processing

    func retry(recordingId: UUID) {
        Task { await process(recordingId: recordingId) }
    }

    /// Mix → transcribe → summarise. Steps that already have a result are skipped, so a retry continues where it failed.
    func process(recordingId id: UUID) async {
        guard !processingIds.contains(id), appState.recording(id) != nil else { return }
        processingIds.insert(id)
        let task = Task { await self.runPipeline(id) }
        processingTasks[id] = task
        await task.value
        processingTasks[id] = nil
        processingIds.remove(id)
        // Deleted while it was being processed: drop whatever the pipeline left behind.
        if appState.recording(id) == nil { RecordingStore.removeFiles(for: id) }
    }

    private func runPipeline(_ id: UUID) async {
        appState.mutateRecording(id) { $0.errorMessage = nil }

        do {
            let audioURL = try await prepareAudio(for: id)
            try Task.checkCancellation()

            if appState.recording(id)?.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                appState.mutateRecording(id) { $0.status = .transcribing }
                let language = appState.callLanguage == "auto" ? nil : appState.callLanguage
                let tracks = CallTranscriber.Tracks(
                    mixed: audioURL,
                    mine: RecordingStore.myTrackURL(for: id),
                    other: RecordingStore.otherTrackURL(for: id)
                )
                let result = try await transcriber.transcribe(tracks, language: language) { [weak self] current, total in
                    Task { @MainActor in
                        self?.chunkProgress = ChunkProgress(recordingId: id, current: current, total: total)
                    }
                }
                chunkProgress = nil
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProcessingError.emptyTranscript
                }
                appState.mutateRecording(id) { recording in
                    recording.transcript = result.text
                    recording.segments = result.segments
                }
                // The separate sides were only needed to tell the speakers apart; the mixed file stays for playback.
                RecordingStore.removeTracks(for: id)
            }

            try Task.checkCancellation()
            guard let recording = appState.recording(id), let transcript = recording.transcriptForAI else { return }
            appState.mutateRecording(id) { $0.status = .summarizing }
            let summary = try await deepInfra.summarize(
                transcript: transcript,
                hasSpeakers: recording.hasSpeakers,
                clientContext: appState.client(for: recording)?.aiContext(),
                userRole: userRole,
                language: AppLanguage.current,
                now: Date()
            )
            guard appState.recording(id) != nil else { return }
            appState.mutateRecording(id) { recording in
                recording.summary = summary
                recording.status = .completed
            }
            notify(L10n.t(summary.meeting == nil ? .notifSummarised : .notifSummarisedMeeting))
        } catch {
            chunkProgress = nil
            // A call deleted mid-way isn't a failure worth reporting.
            guard appState.recording(id) != nil, !Task.isCancelled else { return }
            markFailed(id, error)
            notify(L10n.t(.notifFailed))
        }
    }

    /// Returns the mixed audio file of a recording (for playback and as a fallback for the transcript).
    /// Fresh recording parts are mixed first, and each side is also kept on its own until the call is transcribed,
    /// so the transcript can tell who said what.
    func prepareAudio(for id: UUID) async throws -> URL {
        let fileManager = FileManager.default
        let mixed = RecordingStore.mixedURL(for: id)
        let system = RecordingStore.systemPartURL(for: id)
        let mic = RecordingStore.micPartURL(for: id)
        let parts = [system, mic].filter { fileManager.fileExists(atPath: $0.path) }

        if parts.isEmpty {
            if fileManager.fileExists(atPath: mixed.path) { return mixed }
            if let legacy = appState.recording(id)?.audioURL, legacy != mixed, legacy.pathExtension != "caf",
               fileManager.fileExists(atPath: legacy.path) {
                return legacy
            }
            throw ProcessingError.audioMissing
        }

        appState.mutateRecording(id) { $0.status = .pendingTranscription }
        if !fileManager.fileExists(atPath: mixed.path) {
            try await AudioMixer.mix(parts, to: mixed)
        }
        // A side that can't be converted only means the speakers won't be told apart.
        if fileManager.fileExists(atPath: mic.path) {
            try? await AudioLevels.exportSpeech(from: mic, to: RecordingStore.myTrackURL(for: id))
        }
        if fileManager.fileExists(atPath: system.path) {
            try? await AudioLevels.exportSpeech(from: system, to: RecordingStore.otherTrackURL(for: id))
        }
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

    // MARK: - Follow-up email

    /// Writes the follow-up email for a call from its summary and transcript, and keeps it with the call.
    /// An address the user already typed is kept when the email is written again.
    @discardableResult
    func draftEmail(for recordingId: UUID) async throws -> EmailDraft {
        guard let recording = appState.recording(recordingId), let summary = recording.summary else {
            throw FollowUpError.noSummary
        }
        let client = appState.client(for: recording)
        let result = try await deepInfra.draftFollowUpEmail(
            transcript: recording.transcriptForAI ?? "",
            summary: summary,
            recipientName: client?.contactPerson.nonEmpty ?? recording.contactName.nonEmpty,
            company: client?.name.nonEmpty,
            language: AppLanguage.current,
            now: Date()
        )
        let typed = appState.recording(recordingId)?.emailDraft?.to.nonEmpty
        let draft = EmailDraft(
            to: typed ?? client?.email.nonEmpty ?? "",
            subject: result.subject,
            body: result.body,
            createdAt: Date()
        )
        appState.mutateRecording(recordingId) { $0.emailDraft = draft }
        return draft
    }

    func saveEmailDraft(_ draft: EmailDraft, for recordingId: UUID) {
        guard let recording = appState.recording(recordingId), recording.emailDraft != draft else { return }
        appState.mutateRecording(recordingId) { $0.emailDraft = draft }
    }

    /// Opens the email in Apple Mail (or the default mail app), where the user checks and sends it.
    func openEmailInMail(_ draft: EmailDraft, for recordingId: UUID) -> Bool {
        saveEmailDraft(draft, for: recordingId)
        return MailComposer.open(to: EmailAddress.list(draft.to), subject: draft.subject, body: draft.body)
    }

    /// Sends the email straight through the user's SMTP server and notes when and to whom it went.
    func sendEmail(_ draft: EmailDraft, for recordingId: UUID) async throws {
        let settings = appState.smtpSettings
        guard settings.isComplete else { throw SMTPError.notConfigured }
        let recipients = EmailAddress.list(draft.to)
        guard !recipients.isEmpty else { throw SMTPError.noRecipient }
        if let invalid = recipients.first(where: { !EmailAddress.isValid($0) }) {
            throw SMTPError.invalidAddress(invalid)
        }
        let sender = settings.senderAddress
        let copyToSelf = settings.bccSelf
            && !recipients.contains { $0.caseInsensitiveCompare(sender) == .orderedSame }
        let email = OutgoingEmail(
            fromName: settings.fromName.trimmingCharacters(in: .whitespacesAndNewlines),
            fromAddress: sender,
            to: recipients,
            bcc: copyToSelf ? [sender] : [],
            subject: draft.subject,
            body: draft.body
        )
        saveEmailDraft(draft, for: recordingId)
        let client = SMTPClient(settings: settings, password: appState.smtpPassword ?? "", makeTransport: makeSMTPTransport)
        try await client.send(email)
        var sent = draft
        sent.sentAt = Date()
        sent.sentTo = recipients.joined(separator: ", ")
        appState.mutateRecording(recordingId) { $0.emailDraft = sent }
    }

    /// Signs in to the SMTP server and out again without sending anything.
    func verifySMTP(_ settings: SMTPSettings, password: String) async throws {
        try await SMTPClient(settings: settings, password: password, makeTransport: makeSMTPTransport).verify()
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
        let entry = appState.phonebookEntry(for: number)
        if let entry, !entry.name.isEmpty {
            return (number, entry.name, entry.clientId)
        }
        // A private-list entry may have the number without a name.
        return (number, await contacts.name(for: number), entry?.clientId)
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
