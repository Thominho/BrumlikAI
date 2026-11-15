import SwiftUI

struct RecordingDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let recordingId: UUID
    var onDeleted: () -> Void = {}
    @State private var regenerating = false
    @State private var editingContact = false
    @State private var confirmingDelete = false
    @State private var transcriptExpanded = true
    @StateObject private var player = AudioPlayback()

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
                        FollowUpEmailCard(recording: rec)
                    } else if rec.status == .failed {
                        failedCard(rec)
                    } else {
                        processingCard(rec)
                    }

                    if rec.transcript?.isEmpty == false || player.isReady {
                        recordingCard(rec)
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 680, minHeight: 620)
            .background(backgroundGradient)
            .onAppear { loadAudio(rec) }
            .onChange(of: rec.status) { _, _ in loadAudio(rec) }
            .onDisappear { player.stop() }
            .confirmationDialog(loc.t(.detailDeleteConfirmTitle), isPresented: $confirmingDelete) {
                Button(loc.t(.detailDeleteCall), role: .destructive) { delete(rec) }
                Button(loc.t(.cancel), role: .cancel) {}
            } message: {
                Text(loc.t(.detailDeleteConfirmBody))
            }
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
                    Button { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .padding(7)
                            .background(Circle().fill(Color.secondary.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(loc.t(.detailDeleteCall))
                    .accessibilityLabel(loc.t(.detailDeleteCall))
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

    /// The player and the transcript: who said what, and every sentence plays from where it was said.
    private func recordingCard(_ rec: Recording) -> some View {
        let segments = rec.segments ?? []
        let canPlay = player.isReady
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(loc.t(.detailRecordingTitle)).font(.headline)
                } icon: {
                    Image(systemName: "waveform").foregroundColor(.accentColor)
                }
                Spacer()
                if let copy = transcriptCopyText(rec) {
                    CopyButton(text: copy, compact: true)
                }
            }

            if canPlay {
                AudioPlayerBar(player: player)
            } else if rec.status == .completed {
                Text(loc.t(.playerUnavailable)).font(.caption).foregroundColor(.secondary)
            }

            if !segments.isEmpty {
                DisclosureGroup(isExpanded: $transcriptExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if canPlay {
                            Text(loc.t(.detailTranscriptHint)).font(.caption).foregroundColor(.secondary)
                        }
                        TranscriptTurnsView(
                            segments: segments,
                            turns: TranscriptBuilder.turns(segments),
                            otherName: otherName(rec),
                            activeIndex: player.isPlaying || player.currentTime > 0
                                ? TranscriptTurnsView.activeIndex(in: segments, at: player.currentTime)
                                : nil,
                            canPlay: canPlay
                        ) { segment in
                            player.play(from: max(0, segment.start - 0.2))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(loc.t(.detailTranscript)).font(.subheadline.weight(.semibold))
                }
            } else if let transcript = rec.transcript, !transcript.isEmpty {
                DisclosureGroup(isExpanded: $transcriptExpanded) {
                    Text(transcript)
                        .font(.system(.callout, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                } label: {
                    Text(loc.t(.detailTranscript)).font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1))
    }

    /// How the other side is called in the transcript: their name when it's known.
    private func otherName(_ rec: Recording) -> String {
        rec.contactName.nonEmpty ?? appState.client(for: rec)?.contactPerson.nonEmpty ?? loc.t(.transcriptOther)
    }

    private func transcriptCopyText(_ rec: Recording) -> String? {
        if let segments = rec.segments, !segments.isEmpty {
            let other = otherName(rec)
            return TranscriptBuilder.labelledText(segments, withTimes: true) { speaker in
                switch speaker {
                case .me: return loc.t(.transcriptMe)
                case .other: return other
                case .unknown: return nil
                }
            }
        }
        return rec.transcript.nonEmpty
    }

    /// The mixed file is complete once transcription starts; before that it may still be written.
    private func loadAudio(_ rec: Recording) {
        switch rec.status {
        case .recording, .pendingTranscription:
            return
        case .transcribing, .summarizing, .completed, .failed:
            player.load(rec.audioURL)
        }
    }

    // MARK: - Actions

    private func delete(_ rec: Recording) {
        Task {
            await coordinator.deleteRecording(rec.id)
            onDeleted()
        }
    }

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
