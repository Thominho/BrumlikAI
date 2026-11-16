import SwiftUI
import EventKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager
    @EnvironmentObject var checklist: SetupChecklist

    var onReopenOnboarding: () -> Void = {}
    var onOpenPermissionsGuide: () -> Void = {}

    @State private var apiToken = ""
    @State private var revealToken = false
    @State private var savedFlash = false
    @State private var calendars: [EKCalendar] = []
    @State private var reminderLists: [EKCalendar] = []
    @State private var launchAtLogin = false

    private struct CallLanguage: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private let callLanguages = [
        CallLanguage(code: "cs", name: "Čeština"),
        CallLanguage(code: "sk", name: "Slovenčina"),
        CallLanguage(code: "en", name: "English"),
        CallLanguage(code: "de", name: "Deutsch")
    ]

    var body: some View {
        Form {
            Section {
                Button(action: onOpenPermissionsGuide) {
                    HStack {
                        Label(loc.t(.settingsOpenGuide), systemImage: "checkmark.shield")
                        Spacer()
                        if checklist.requiredMissingCount > 0 {
                            Text("\(checklist.requiredMissingCount)")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))
                        }
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section(loc.t(.settingsLanguage)) {
                Picker(loc.t(.settingsLanguage), selection: $loc.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(loc.t(.settingsApiToken)) {
                HStack {
                    Group {
                        if revealToken {
                            TextField(loc.t(.onboardingApiPlaceholder), text: $apiToken)
                        } else {
                            SecureField(loc.t(.onboardingApiPlaceholder), text: $apiToken)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    Button(loc.t(.settingsApiSave), action: saveToken)
                        .buttonStyle(.borderedProminent)
                        .disabled(apiToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 8) {
                    Button(loc.t(.guideCheckToken)) { Task { await checklist.checkToken() } }
                        .disabled(checklist.status(.deepInfra) == .checking || apiToken.isEmpty)
                    tokenStatus
                    Spacer()
                    if savedFlash {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    }
                }
            }

            Section(loc.t(.settingsCallLanguage)) {
                Picker(loc.t(.settingsCallLanguage), selection: $appState.callLanguage) {
                    Text(loc.t(.settingsCallLanguageAuto)).tag("auto")
                    ForEach(callLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .labelsHidden()
                Text(loc.t(.settingsCallLanguageHint)).font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle(isOn: $appState.showAIPrompt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t(.settingsShowAIPrompt))
                        Text(loc.t(.settingsShowAIPromptHint)).font(.caption).foregroundColor(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t(.settingsRole)).font(.headline)
                    Text(loc.t(.settingsRoleHelp)).font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $appState.userRole)
                        .font(.body)
                        .frame(minHeight: 64)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
                }
            }

            Section(loc.t(.settingsCalendar)) {
                Picker(loc.t(.settingsCalendar), selection: Binding(
                    get: { appState.defaultCalendarId ?? "" },
                    set: { appState.defaultCalendarId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Text(calendar.title).tag(calendar.calendarIdentifier)
                    }
                }
                .labelsHidden()
            }

            Section(loc.t(.settingsRemindersList)) {
                Picker(loc.t(.settingsRemindersList), selection: Binding(
                    get: { appState.defaultRemindersListId ?? "" },
                    set: { appState.defaultRemindersListId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    ForEach(reminderLists, id: \.calendarIdentifier) { list in
                        Text(list.title).tag(list.calendarIdentifier)
                    }
                }
                .labelsHidden()
            }

            Section {
                Toggle(loc.t(.settingsAutoDetect), isOn: $appState.autoDetectEnabled)
                Toggle(isOn: $appState.showCallBriefing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t(.settingsBriefing))
                        Text(loc.t(.settingsBriefingHint)).font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $appState.recordOnlineCalls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t(.settingsOnlineCalls))
                        Text(loc.t(.settingsOnlineCallsHint)).font(.caption).foregroundColor(.secondary)
                    }
                }
                .disabled(!appState.autoDetectEnabled)
                if appState.autoDetectEnabled, appState.recordOnlineCalls, !CGPreflightScreenCaptureAccess() {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(loc.t(.settingsOnlineCallsNoTitles), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button(loc.t(.guideAllow)) {
                            Task { await SetupChecklist.shared.perform(.screenRecording) }
                        }
                        .controlSize(.small)
                    }
                }
                Toggle(loc.t(.settingsConsent), isOn: $appState.consentAcknowledged)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(loc.t(.settingsLaunchAtLogin), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in applyLaunchAtLogin(enabled) }
                    Text(loc.t(.settingsLaunchAtLoginHint)).font(.caption).foregroundColor(.secondary)
                }
            }

            PrivateCallsSection()

            EmailSettingsSection()

            UpdatesSection()

            DiagnosticsSection()

            Section {
                Button(action: onReopenOnboarding) {
                    Label(loc.t(.settingsReopenGuide), systemImage: "sparkles")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 720)
        .onAppear {
            apiToken = appState.deepInfraToken ?? ""
            launchAtLogin = LaunchAgent.isEnabled
            loadLists()
        }
    }

    @ViewBuilder
    private var tokenStatus: some View {
        switch checklist.status(.deepInfra) {
        case .checking:
            ProgressView().controlSize(.small)
        case .done:
            Label(loc.t(.guideStatusWorks), systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .failed(let message):
            Text(message).foregroundColor(.orange).font(.caption).lineLimit(2)
        case .missing, .unknown:
            EmptyView()
        }
    }

    private func saveToken() {
        appState.deepInfraToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation { savedFlash = true }
        Task {
            await checklist.checkToken()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedFlash = false }
        }
    }

    /// Only lists what is already allowed — asking for access is the setup guide's job.
    private func loadLists() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            calendars = CalendarService().availableCalendars()
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            reminderLists = RemindersService().availableLists()
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAgent.isEnabled else { return }
        do {
            try LaunchAgent.setEnabled(enabled)
        } catch {
            appState.lastError = error.localizedDescription
            launchAtLogin = LaunchAgent.isEnabled
        }
    }
}

/// Numbers (or contact names) that are never recorded.
private struct PrivateCallsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager

    @State private var number = ""
    @State private var name = ""

    var body: some View {
        Section {
            Text(loc.t(.settingsPrivateBody))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(loc.t(.settingsPrivateNumber), text: $number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 180)
                    .onSubmit(add)
                TextField(loc.t(.settingsPrivateName), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) {
                    Label(loc.t(.settingsPrivateAdd), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
            Text(loc.t(.settingsPrivateNameHint))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.privateCallers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "lock.open")
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(loc.t(.settingsPrivateEmpty))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(appState.privateCallers) { entry in
                    row(entry)
                }
            }
        } header: {
            Label(loc.t(.settingsPrivateTitle), systemImage: "lock.shield")
        }
    }

    private var canAdd: Bool {
        !PhonebookEntry.normalize(number).isEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        withAnimation { appState.setDoNotRecord(true, number: number, name: name) }
        number = ""
        name = ""
    }

    private func row(_ entry: PhonebookEntry) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: entry.number.isEmpty ? "person.fill" : "phone.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.isEmpty ? entry.number : entry.name)
                    .font(entry.name.isEmpty ? .system(.body, design: .monospaced) : .body)
                if let detail = detail(for: entry) {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                withAnimation { appState.removePrivate(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(loc.t(.settingsPrivateRemove))
            .accessibilityLabel(loc.t(.settingsPrivateRemove))
        }
    }

    private func detail(for entry: PhonebookEntry) -> String? {
        var parts: [String] = []
        if entry.number.isEmpty {
            parts.append(loc.t(.settingsPrivateByName))
        } else if !entry.name.isEmpty {
            parts.append(entry.number)
        }
        if let clientId = entry.clientId, let client = appState.clients.first(where: { $0.id == clientId }) {
            parts.append(client.name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct UpdatesSection: View {
    @EnvironmentObject var loc: LocalizationManager
    @EnvironmentObject var updater: UpdateChecker

    var body: some View {
        Section(loc.t(.updatesTitle)) {
            HStack(spacing: 8) {
                Text(String(format: loc.t(.updatesCurrentVersion), updater.currentVersion))
                Spacer()
                status
                Button(loc.t(.updatesCheckNow)) { Task { await updater.check() } }
                    .disabled(isBusy)
            }
            if let release = updater.availableRelease {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: loc.t(.updatesAvailable), release.version)).fontWeight(.semibold)
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.caption).foregroundColor(.secondary).lineLimit(6)
                    }
                    HStack {
                        Button(loc.t(.updatesInstall)) { Task { await updater.install(release) } }
                            .buttonStyle(.borderedProminent)
                        if let page = release.pageURL {
                            Link(loc.t(.updatesReleaseNotes), destination: page)
                        }
                    }
                }
            }
            Toggle(loc.t(.updatesAutoCheck), isOn: $updater.checksAutomatically)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(loc.t(.updatesAutoInstall), isOn: $updater.installsAutomatically)
                    .disabled(!updater.checksAutomatically)
                Text(loc.t(.updatesAutoInstallHint)).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
            Text(loc.t(.updatesChecking)).font(.caption).foregroundColor(.secondary)
        case .downloading:
            ProgressView().controlSize(.small)
            Text(loc.t(.updatesDownloading)).font(.caption).foregroundColor(.secondary)
        case .installing:
            ProgressView().controlSize(.small)
            Text(loc.t(.updatesInstalling)).font(.caption).foregroundColor(.secondary)
        case .upToDate:
            Label(loc.t(.updatesUpToDate), systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundColor(.orange).lineLimit(2)
        case .notConfigured:
            Text(loc.t(.updatesNotConfigured)).font(.caption).foregroundColor(.secondary)
        case .idle, .available:
            EmptyView()
        }
    }
}

private struct DiagnosticsSection: View {
    @EnvironmentObject var loc: LocalizationManager
    @EnvironmentObject var coordinator: RecordingCoordinator

    @State private var running = false
    @State private var result: SelfTest.AudioCheck?
    @State private var processes: [CoreAudioProcesses.Info] = []

    var body: some View {
        Section(loc.t(.settingsDiagnostics)) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: runTest) {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? loc.t(.settingsTestRunning) : loc.t(.settingsTestRecording))
                    }
                }
                .disabled(running || coordinator.isRecording)
                Text(loc.t(.settingsTestHint)).font(.caption).foregroundColor(.secondary)
                Text(String(format: loc.t(.settingsInputDevice), CoreAudioUtils.defaultInputDeviceName() ?? "—"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let result {
                    resultRow(loc.t(.settingsTestCaller), peak: result.systemPeak)
                    resultRow(loc.t(.settingsTestMic), peak: result.micPeak)
                    ForEach(result.warnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundColor(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loc.t(.settingsProcesses)).font(.headline)
                    Spacer()
                    Button(loc.t(.settingsRefresh)) { processes = CoreAudioProcesses.list() }
                }
                Text(loc.t(.settingsProcessesHint)).font(.caption).foregroundColor(.secondary)
                ForEach(processes) { process in
                    HStack(spacing: 8) {
                        Text(process.displayName).font(.callout)
                        if process.isCallProcess || process.isOnlineCallApp {
                            Text(loc.t(process.isCallProcess ? .settingsCallTag : .settingsOnlineTag))
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        Spacer()
                        Image(systemName: "mic.fill")
                            .foregroundColor(process.isRunningInput ? .red : .secondary.opacity(0.25))
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundColor(process.isRunningOutput ? .accentColor : .secondary.opacity(0.25))
                    }
                }
            }
        }
        .onAppear { processes = CoreAudioProcesses.list() }
    }

    private func resultRow(_ title: String, peak: Float?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let peak, peak > SystemAudioTap.silenceThreshold {
                Label("\(loc.t(.settingsTestOK)) (\(Self.decibels(peak)))", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if peak != nil {
                Label(loc.t(.settingsTestSilent), systemImage: "speaker.slash.fill").foregroundColor(.orange)
            } else {
                Label(loc.t(.settingsTestNotRecorded), systemImage: "xmark.circle.fill").foregroundColor(.orange)
            }
        }
        .font(.callout)
    }

    private static func decibels(_ peak: Float) -> String {
        String(format: "%.0f dB", 20 * log10(max(peak, 0.000001)))
    }

    private func runTest() {
        running = true
        Task {
            result = await SelfTest.audioCheck(seconds: 5)
            processes = CoreAudioProcesses.list()
            running = false
        }
    }
}
