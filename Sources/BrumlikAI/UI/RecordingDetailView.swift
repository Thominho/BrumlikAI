import SwiftUI

struct RecordingDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let recordingId: UUID
    @State private var regenerating = false
    @State private var editingContact = false

    private var recording: Recording? {
        appState.recordings.first(where: { $0.id == recordingId })
    }

    var body: some View {
        if let rec = recording {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(rec)
                    contactCard(rec)
                    ErrorBanner(message: $appState.lastError)
                    if let warning = rec.audioWarning {
                        audioWarningCard(warning)
                    }

                    if let summary = rec.summary {
                        summaryCard(
                            title: loc.t(.detailHumanSummary),
                            hint: loc.t(.detailHumanSummaryHint),
                            icon: "doc.text",
                            tint: .accentColor,
                            text: summary.humanSummary,
                            bullets: summary.requests.isEmpty ? nil : summary.requests
                        )
                        if appState.showAIPrompt && !summary.aiPrompt.isEmpty {
                            summaryCard(
                                title: loc.t(.detailAiPrompt),
                                hint: loc.t(.detailAiPromptHint),
                                icon: "sparkles",
                                tint: .purple,
                                text: summary.aiPrompt,
                                regenerating: regenerating
                            )
                        }
                        if let tasks = summary.tasks, !tasks.isEmpty {
                            tasksCard(tasks, for: rec)
                        }
                        if let meeting = summary.meeting {
                            EditableMeetingCard(meeting: meeting, recording: rec)
                                .environmentObject(appState)
                                .environmentObject(coordinator)
                                .environmentObject(loc)
                        }
                    } else if rec.status == .failed {
                        failedCard(rec)
                    } else {
                        processingCard(rec)
                    }

                    if let transcript = rec.transcript, !transcript.isEmpty {
                        transcriptCard(transcript)
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 680, minHeight: 620)
            .background(backgroundGradient)
            .sheet(isPresented: $editingContact) {
                ContactEditSheet(
                    recording: rec,
                    onSave: { editingContact = false }
                )
                .environmentObject(appState)
                .environmentObject(coordinator)
                .environmentObject(loc)
            }
        } else {
            VStack { Text(loc.t(.recordingsEmpty)).foregroundColor(.secondary) }
                .frame(minWidth: 680, minHeight: 620)
        }
    }

    private func contactCard(_ rec: Recording) -> some View {
        let client = appState.client(for: rec)
        let hasAny = (rec.contactName?.isEmpty == false) || (rec.phoneNumber?.isEmpty == false)

        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 52, height: 52)
                Image(systemName: hasAny ? "person.crop.circle.fill" : "questionmark.circle")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.contactName ?? (rec.phoneNumber?.isEmpty == false ? rec.phoneNumber! : loc.t(.detailContactUnknown)))
                    .font(.system(.title3, design: .rounded)).fontWeight(.semibold)
                HStack(spacing: 10) {
                    if let phone = rec.phoneNumber, !phone.isEmpty {
                        Label(phone, systemImage: "phone.fill")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let client = client {
                        Label(client.name, systemImage: "building.2.fill")
                            .font(.caption).foregroundColor(.accentColor)
                    }
                }
            }
            Spacer()
            Button(action: { editingContact = true }) {
                Label(loc.t(.detailEditContact), systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Pieces

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.07), Color.purple.opacity(0.05), Color.clear],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func header(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: "phone.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t(.detailTitle))
                        .font(.caption).foregroundColor(.secondary)
                    Text(rec.displayTitle)
                        .font(.system(.title2, design: .rounded)).fontWeight(.semibold)
                }
                Spacer()
                HStack(spacing: 14) {
                    metaBubble(icon: "clock", text: formatDuration(rec.duration))
                    statusBadge(rec.status)
                }
            }
        }
    }

    private func metaBubble(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .foregroundColor(.secondary)
    }

    private func statusBadge(_ status: ProcessingStatus) -> some View {
        Group {
            switch status {
            case .recording:
                Label(loc.t(.statusRecording), systemImage: "waveform").foregroundColor(.red)
            case .pendingTranscription, .transcribing, .summarizing:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(loc.t(.recordingProcessing))
                }
                .foregroundColor(.secondary)
            case .completed:
                Label("", systemImage: "checkmark.seal.fill").foregroundColor(.green)
            case .failed:
                Label("", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
        }
        .font(.caption)
    }

    private func clientPicker(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t(.detailClient), systemImage: "person.crop.circle")
                .font(.caption).foregroundColor(.secondary)

            Menu {
                Button(loc.t(.detailUnassigned)) {
                    Task { await changeClient(to: nil, for: rec.id) }
                }
                Divider()
                ForEach(appState.clients) { client in
                    Button(client.name) {
                        Task { await changeClient(to: client.id, for: rec.id) }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(rec.clientId == nil ? .secondary : .accentColor)
                    Text(appState.client(for: rec)?.name ?? loc.t(.detailUnassigned))
                        .foregroundColor(.primary)
                        .fontWeight(.medium)
                    Spacer()
                    if regenerating {
                        ProgressView().controlSize(.mini)
                        Text(loc.t(.detailRegeneratingPrompt))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundColor(.secondary).font(.caption)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func summaryCard(
        title: String,
        hint: String,
        icon: String,
        tint: Color,
        text: String,
        bullets: [String]? = nil,
        regenerating: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    Image(systemName: icon).foregroundColor(tint)
                }
                Spacer()
                CopyButton(text: fullCopyText(summary: text, bullets: bullets))
                    .opacity(regenerating ? 0.4 : 1)
                    .disabled(regenerating)
            }
            Text(hint).font(.caption).foregroundColor(.secondary)

            if regenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t(.detailRegeneratingPrompt)).foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let bullets = bullets, !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t(.recordingRequests))
                        .font(.caption).foregroundColor(.secondary).padding(.top, 2)
                    ForEach(bullets, id: \.self) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
                            Text(b).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }

    private func fullCopyText(summary: String, bullets: [String]?) -> String {
        guard let bullets = bullets, !bullets.isEmpty else { return summary }
        return summary + "\n\n" + bullets.map { "- \($0)" }.joined(separator: "\n")
    }

    private func tasksCard(_ tasks: [TaskProposal], for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(loc.t(.tasksTitle)).font(.headline)
                } icon: {
                    Image(systemName: "checklist").foregroundColor(.teal)
                }
                Spacer()
            }
            ForEach(tasks) { task in
                TaskRow(task: task, recording: rec)
                    .environmentObject(coordinator)
                    .environmentObject(loc)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.teal.opacity(0.22), lineWidth: 1))
    }

    private func processingCard(_ rec: Recording) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text(processingText(rec))
                .font(.callout).foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
    }

    private func processingText(_ rec: Recording) -> String {
        switch rec.status {
        case .recording:
            return loc.t(.statusRecording)
        case .pendingTranscription:
            return loc.t(.statusPreparing)
        case .transcribing:
            if let progress = coordinator.chunkProgress, progress.recordingId == rec.id {
                return String(format: loc.t(.chunkingProgress), progress.current, progress.total)
            }
            return loc.t(.statusTranscribing)
        case .summarizing:
            return loc.t(.statusSummarizing)
        case .completed, .failed:
            return loc.t(.recordingProcessing)
        }
    }

    private func failedCard(_ rec: Recording) -> some View {
        let retrying = coordinator.processingIds.contains(rec.id)
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(loc.t(.failedTitle)).font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
            if let message = rec.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button(action: { coordinator.retry(recordingId: rec.id) }) {
                HStack(spacing: 6) {
                    if retrying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(loc.t(.retryButton))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }

    private func audioWarningCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.slash.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t(.audioWarningTitle)).font(.callout.weight(.semibold))
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }

    private func transcriptCard(_ transcript: String) -> some View {
        DisclosureGroup {
            Text(transcript)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 8)
        } label: {
            HStack {
                Label(loc.t(.detailTranscript), systemImage: "text.alignleft").font(.headline)
                Spacer()
                CopyButton(text: transcript, compact: true)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
    }

    // MARK: - Actions

    private func changeClient(to clientId: UUID?, for recordingId: UUID) async {
        regenerating = true
        await coordinator.assignClient(clientId, to: recordingId)
        regenerating = false
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: LocalizationManager.shared.language == .czech ? "cs_CZ" : "en_US")
        return f.string(from: date)
    }
}
