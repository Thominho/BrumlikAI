import SwiftUI

/// The follow-up email for a call: written by the AI, edited here, then opened in Mail or sent over SMTP.
struct FollowUpEmailCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let recording: Recording

    @State private var to = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var loadedDraft: EmailDraft?
    @State private var working: Work?
    @State private var message: Message?
    @State private var confirmingSend = false

    private enum Work { case writing, sending }

    private enum Message: Equatable {
        case info(String)
        case error(String)
    }

    private var draft: EmailDraft? { recording.emailDraft }

    private var usesSMTP: Bool { appState.emailTransport == .smtp && appState.smtpSettings.isComplete }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(loc.t(.emailCardTitle)).font(.headline)
                } icon: {
                    Image(systemName: "envelope").foregroundColor(.indigo)
                }
                Spacer()
                if draft != nil {
                    CopyButton(text: subject.isEmpty ? bodyText : subject + "\n\n" + bodyText)
                }
            }
            Text(loc.t(.emailCardHint)).font(.caption).foregroundColor(.secondary)

            if draft == nil {
                Button(action: write) {
                    HStack(spacing: 6) {
                        if working == .writing {
                            ProgressView().controlSize(.small)
                            Text(loc.t(.emailWriting))
                        } else {
                            Image(systemName: "sparkles")
                            Text(loc.t(.emailWrite))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working != nil)
            } else {
                editor
                actions
                if let sentAt = draft?.sentAt, let sentTo = draft?.sentTo {
                    Label(String(format: loc.t(.emailSentAt), formatDate(sentAt), sentTo), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if appState.emailTransport == .smtp && !appState.smtpSettings.isComplete {
                    Text(loc.t(.emailSMTPMissing)).font(.caption).foregroundColor(.secondary)
                }
            }

            if let message {
                switch message {
                case .info(let text):
                    Label(text, systemImage: "checkmark.circle").font(.caption).foregroundColor(.secondary)
                case .error(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.indigo.opacity(0.22), lineWidth: 1))
        .onAppear(perform: loadDraft)
        .onChange(of: recording.emailDraft) { _, _ in loadDraft() }
        .onDisappear(perform: saveEdits)
        .confirmationDialog(
            String(format: loc.t(.emailConfirmTitle), EmailAddress.list(to).joined(separator: ", ")),
            isPresented: $confirmingSend
        ) {
            Button(loc.t(.emailSend), action: send)
            Button(loc.t(.cancel), role: .cancel) {}
        } message: {
            Text(loc.t(.emailConfirmBody))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(loc.t(.emailTo)) {
                TextField("client@example.com", text: $to)
                    .textFieldStyle(.roundedBorder)
            }
            field(loc.t(.emailSubject)) {
                TextField("", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $bodyText)
                .font(.system(.body))
                .frame(minHeight: 200)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: write) {
                HStack(spacing: 5) {
                    if working == .writing {
                        ProgressView().controlSize(.mini)
                        Text(loc.t(.emailWriting))
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text(loc.t(.emailRewrite))
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(working != nil)

            Spacer()

            if usesSMTP {
                Button {
                    guard checkRecipient() else { return }
                    confirmingSend = true
                } label: {
                    HStack(spacing: 6) {
                        if working == .sending {
                            ProgressView().controlSize(.small)
                            Text(loc.t(.emailSending))
                        } else {
                            Image(systemName: "paperplane.fill")
                            Text(loc.t(.emailSend))
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working != nil || bodyText.nonEmpty == nil)
            } else {
                Button(action: openInMail) {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.arrow.triangle.branch")
                        Text(loc.t(.emailOpenInMail))
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working != nil || bodyText.nonEmpty == nil)
            }
        }
    }

    // MARK: - Actions

    private var currentDraft: EmailDraft {
        var edited = draft ?? EmailDraft(to: "", subject: "", body: "", createdAt: Date())
        edited.to = to
        edited.subject = subject
        edited.body = bodyText
        return edited
    }

    private func loadDraft() {
        guard let draft, draft != loadedDraft else { return }
        loadedDraft = draft
        to = draft.to
        subject = draft.subject
        bodyText = draft.body
    }

    private func saveEdits() {
        guard draft != nil else { return }
        coordinator.saveEmailDraft(currentDraft, for: recording.id)
    }

    private func write() {
        saveEdits()
        working = .writing
        message = nil
        Task {
            defer { working = nil }
            do {
                try await coordinator.draftEmail(for: recording.id)
            } catch {
                message = .error(error.localizedDescription)
            }
        }
    }

    private func openInMail() {
        message = nil
        if coordinator.openEmailInMail(currentDraft, for: recording.id) {
            message = .info(loc.t(.emailOpenedInMail))
        } else {
            message = .error(loc.t(.emailMailFailed))
        }
    }

    private func checkRecipient() -> Bool {
        guard !EmailAddress.list(to).isEmpty else {
            message = .error(loc.t(.emailNoRecipient))
            return false
        }
        return true
    }

    private func send() {
        working = .sending
        message = nil
        let edited = currentDraft
        Task {
            defer { working = nil }
            do {
                try await coordinator.sendEmail(edited, for: recording.id)
            } catch {
                message = .error(error.localizedDescription)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: loc.language.localeIdentifier)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
