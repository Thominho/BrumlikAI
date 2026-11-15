import SwiftUI

/// How follow-up emails are sent: through Apple Mail, or straight from BrumlikAI over the user's SMTP server.
struct EmailSettingsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    @State private var draft = SMTPSettings()
    @State private var portText = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, testing, ok, saved
        case failed(String)
    }

    var body: some View {
        Section {
            Picker(loc.t(.emailSendVia), selection: $appState.emailTransport) {
                Text(loc.t(.emailViaMail)).tag(EmailTransport.mail)
                Text(loc.t(.emailViaSMTP)).tag(EmailTransport.smtp)
            }
            .pickerStyle(.segmented)

            Text(loc.t(appState.emailTransport == .mail ? .emailViaMailHint : .emailViaSMTPHint))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.emailTransport == .smtp {
                TextField(loc.t(.smtpServer), text: $draft.host, prompt: Text("smtp.example.com"))
                Picker(loc.t(.smtpSecurity), selection: $draft.security) {
                    ForEach(SMTPSettings.Security.allCases) { security in
                        Text(security.title).tag(security)
                    }
                }
                .onChange(of: draft.security) { old, new in
                    // Follow the usual port unless the user typed a different one.
                    if Int(portText) == old.defaultPort || portText.isEmpty { portText = String(new.defaultPort) }
                }
                TextField(loc.t(.smtpPort), text: $portText, prompt: Text(String(draft.security.defaultPort)))
                TextField(loc.t(.smtpUsername), text: $draft.username, prompt: Text("jmeno@firma.cz"))
                SecureField(loc.t(.smtpPassword), text: $password, prompt: Text(hasStoredPassword ? loc.t(.smtpPasswordStored) : ""))
                TextField(loc.t(.smtpFromName), text: $draft.fromName, prompt: Text("Jan Novák"))
                TextField(loc.t(.smtpFromAddress), text: $draft.fromAddress, prompt: Text(draft.username.isEmpty ? "jmeno@firma.cz" : draft.username))
                Toggle(isOn: $draft.bccSelf) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t(.smtpBccSelf))
                        Text(loc.t(.smtpBccSelfHint)).font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button(loc.t(.save), action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!edited.isComplete)
                    Button(loc.t(.smtpTest), action: test)
                        .disabled(!edited.isComplete || status == .testing)
                    statusView
                    Spacer()
                }
            }
        } header: {
            Label(loc.t(.emailSettingsTitle), systemImage: "envelope")
        }
        .onAppear {
            draft = appState.smtpSettings
            portText = String(draft.port)
            hasStoredPassword = appState.hasSMTPPassword
        }
    }

    /// The settings as typed, with the port read from its field.
    private var edited: SMTPSettings {
        var settings = draft
        settings.host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.username = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.fromAddress = settings.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? settings.security.defaultPort
        return settings
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label(loc.t(.smtpTestOK), systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .saved:
            Label(loc.t(.smtpSaved), systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundColor(.orange).lineLimit(3).textSelection(.enabled)
        }
    }

    private func save() {
        appState.smtpSettings = edited
        if !password.isEmpty {
            appState.smtpPassword = password
            password = ""
            hasStoredPassword = true
        }
        withAnimation { status = .saved }
    }

    private func test() {
        let settings = edited
        // A freshly typed password is tested before it's saved; otherwise the saved one is used.
        let secret = password.isEmpty ? (appState.smtpPassword ?? "") : password
        status = .testing
        Task {
            do {
                try await coordinator.verifySMTP(settings, password: secret)
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
