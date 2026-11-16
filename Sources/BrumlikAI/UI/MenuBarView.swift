import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager
    @EnvironmentObject var checklist: SetupChecklist
    @EnvironmentObject var updater: UpdateChecker

    let onRecordTap: () -> Void
    let onOpenSettings: () -> Void
    let onOpenClients: () -> Void
    let onOpenRecording: (UUID) -> Void
    let onOpenGuide: () -> Void

    @State private var searchQuery: String = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if coordinator.isRecording {
                privateCallCard
            }
            banners
            if !appState.recordings.isEmpty {
                searchBar
            }
            Group {
                if appState.recordings.isEmpty {
                    emptyState
                } else if filteredRecordings.isEmpty {
                    noResults
                } else {
                    recordingsList
                }
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 600)
    }

    /// While recording: what happens if you do nothing, and the way out for a private call.
    private var privateCallCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.autoStarted {
                Label(loc.t(.hudKeepHint), systemImage: "checkmark.circle")
            }
            Label(loc.t(.hudPrivateHint), systemImage: "lock")
            Button {
                Task { await coordinator.discardRecording() }
            } label: {
                Label(loc.t(.hudPrivateButton), systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 2)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var banners: some View {
        if appState.lastError != nil || checklist.requiredMissingCount > 0 || updater.availableRelease != nil {
            VStack(spacing: 6) {
                ErrorBanner(message: $appState.lastError)
                if checklist.requiredMissingCount > 0 {
                    SetupBanner(missingCount: checklist.requiredMissingCount, onOpen: onOpenGuide)
                }
                if let release = updater.availableRelease {
                    UpdateBanner(version: release.version) {
                        Task { await updater.install(release) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(loc.t(.searchPlaceholder), text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    private var filteredRecordings: [Recording] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return appState.recordings }
        return appState.recordings.filter { rec in
            if rec.contactName?.lowercased().contains(q) == true { return true }
            if rec.phoneNumber?.lowercased().contains(q) == true { return true }
            if let online = rec.onlineCall,
               online.detail.lowercased().contains(q) || online.title?.lowercased().contains(q) == true { return true }
            if rec.transcript?.lowercased().contains(q) == true { return true }
            if let s = rec.summary {
                if s.humanSummary.lowercased().contains(q) { return true }
                if appState.showAIPrompt, s.aiPrompt.lowercased().contains(q) { return true }
                if s.requests.contains(where: { $0.lowercased().contains(q) }) { return true }
                if s.tasks?.contains(where: { $0.title.lowercased().contains(q) }) == true { return true }
            }
            if let client = appState.client(for: rec), client.name.lowercased().contains(q) { return true }
            return false
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 36)).foregroundColor(.secondary.opacity(0.5))
            Text(loc.t(.searchNoResults))
                .font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t(.appName))
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onRecordTap) {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(loc.t(coordinator.isRecording ? .menuStop : .menuRecord))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isRecording ? .red : .accentColor)
        }
        .padding(14)
    }

    private var statusIcon: String {
        if coordinator.isRecording { return "waveform" }
        return "waveform.circle"
    }

    private var statusColor: Color {
        if coordinator.isRecording { return .red }
        return .accentColor
    }

    private var statusText: String {
        if coordinator.isRecording { return loc.t(.statusRecording) + " · " + formatDuration(coordinator.currentDuration) }
        return loc.t(.statusIdle)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "phone.circle")
                .font(.system(size: 42))
                .foregroundColor(.secondary.opacity(0.6))
            Text(loc.t(.recordingsEmpty))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var recordingsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Text(loc.t(.recordingsTitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                ForEach(filteredRecordings) { rec in
                    RecordingListRow(recording: rec, onTap: { onOpenRecording(rec.id) })
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: onOpenClients) {
                Label(loc.t(.menuClients), systemImage: "person.2")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundColor(.secondary)

            Button(action: onOpenSettings) {
                Label(loc.t(.menuSettings), systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundColor(.secondary)

            Spacer()

            Button(action: { NSApp.terminate(nil) }) {
                Label(loc.t(.menuQuit), systemImage: "power")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct RecordingListRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: LocalizationManager
    let recording: Recording
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(iconTint.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: iconName).foregroundColor(iconTint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryTitle)
                        .font(.system(.subheadline, design: .rounded)).fontWeight(.medium)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        if let client = appState.client(for: recording) {
                            Label(client.name, systemImage: "building.2.fill")
                                .foregroundColor(.accentColor)
                            Text("·")
                        }
                        Text(recording.displayTitle)
                        if recording.status == .failed {
                            Text("·")
                            Text(loc.t(.statusFailedShort)).foregroundColor(.orange)
                        }
                        if recording.summary != nil {
                            Text("·")
                            Text(formatDuration(recording.duration))
                        }
                        if let meeting = recording.summary?.meeting, meeting.startDate != nil {
                            Text("·")
                            Label("", systemImage: "calendar.badge.plus")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                statusBadge
                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovering ? Color.secondary.opacity(0.1) : Color.secondary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var primaryTitle: String {
        if let name = recording.contactName, !name.isEmpty { return name }
        if let client = appState.client(for: recording) { return client.name }
        if let phone = recording.phoneNumber, !phone.isEmpty { return phone }
        if let online = recording.onlineCall { return online.displayTitle }
        if let brief = recording.summary?.humanSummary {
            return brief.components(separatedBy: ".").first.map { String($0) } ?? recording.displayTitle
        }
        return loc.t(.detailContactUnknown)
    }

    private var iconName: String {
        if recording.status == .recording { return "waveform" }
        if let online = recording.onlineCall { return online.service == .meet ? "video.circle.fill" : "message.circle.fill" }
        if recording.clientId != nil { return "person.crop.circle.fill" }
        return "phone.circle.fill"
    }

    private var iconTint: Color {
        if recording.status == .recording { return .red }
        if recording.status == .failed { return .orange }
        return .accentColor
    }

    private var statusBadge: some View {
        Group {
            switch recording.status {
            case .recording:
                Label("", systemImage: "waveform").foregroundColor(.red)
            case .pendingTranscription, .transcribing, .summarizing:
                ProgressView().controlSize(.mini)
            case .completed:
                EmptyView()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
        }
        .font(.caption)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
