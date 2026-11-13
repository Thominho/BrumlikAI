import SwiftUI

struct EditableMeetingCard: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let meeting: MeetingProposal
    let recording: Recording

    @State private var editing = false
    @State private var saved = false
    @State private var title: String = ""
    @State private var start: Date = Date()
    @State private var duration: Int = 30
    @State private var location: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(loc.t(.recordingMeeting)).font(.headline)
                } icon: {
                    Image(systemName: "calendar.badge.plus").foregroundColor(.orange)
                }
                Spacer()
                if !editing && !saved {
                    Button(action: beginEdit) {
                        Label(loc.t(.meetingEdit), systemImage: "pencil")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if editing {
                editor
            } else {
                summary
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.title3).fontWeight(.medium)
            if let date = meeting.startDate {
                Label(formatDate(date), systemImage: "clock")
                    .foregroundColor(.secondary).font(.callout)
            }
            if let locationValue = meeting.location, !locationValue.isEmpty {
                Label(locationValue, systemImage: "mappin.and.ellipse")
                    .foregroundColor(.secondary).font(.callout)
            }
            if saved {
                Label(loc.t(.recordingAdded), systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .padding(.top, 2)
            } else {
                Button(action: save) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(loc.t(.recordingAddToCalendar))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(loc.t(.meetingTitleField)) {
                TextField("", text: $title).textFieldStyle(.roundedBorder)
            }
            LabeledContent(loc.t(.meetingStartField)) {
                DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            LabeledContent(loc.t(.meetingDurationField)) {
                HStack(spacing: 6) {
                    Stepper(value: $duration, in: 5...480, step: 5) {
                        Text("\(duration) \(loc.t(.meetingDurationMinutes))").frame(minWidth: 80, alignment: .leading)
                    }
                }
            }
            LabeledContent(loc.t(.meetingLocationField)) {
                TextField("", text: $location).textFieldStyle(.roundedBorder)
            }
            LabeledContent(loc.t(.meetingNotesField)) {
                TextField("", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            }
            HStack {
                Button(loc.t(.cancel)) { editing = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: save) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text(loc.t(.meetingSaveEdit))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private func beginEdit() {
        title = meeting.title
        start = meeting.startDate ?? Date().addingTimeInterval(24 * 3600)
        duration = meeting.durationMinutes
        location = meeting.location ?? ""
        notes = meeting.notes ?? ""
        editing = true
    }

    private func save() {
        let final: MeetingProposal
        if editing {
            let iso = ISO8601DateFormatter.brumlik.string(from: start)
            final = MeetingProposal(
                title: title,
                startISO: iso,
                durationMinutes: duration,
                location: location.isEmpty ? nil : location,
                notes: notes.isEmpty ? nil : notes
            )
        } else {
            final = meeting
        }
        Task {
            let ok = await coordinator.saveMeeting(final, for: recording)
            await MainActor.run {
                editing = false
                saved = ok
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: LocalizationManager.shared.language == .czech ? "cs_CZ" : "en_US")
        return f.string(from: date)
    }
}

struct TaskRow: View {
    @EnvironmentObject var coordinator: RecordingCoordinator
    @EnvironmentObject var loc: LocalizationManager

    let task: TaskProposal
    let recording: Recording
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.hexagongrid.circle")
                .foregroundColor(.teal)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.callout).fontWeight(.medium)
                if let date = task.dueDate {
                    Label("\(loc.t(.tasksDue)): \(formatDate(date))", systemImage: "clock")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(action: save) {
                HStack(spacing: 5) {
                    if saving { ProgressView().controlSize(.mini) }
                    Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                    Text(saved ? loc.t(.tasksAdded) : loc.t(.tasksAddToReminders))
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .disabled(saving || saved)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
    }

    private func save() {
        saving = true
        Task {
            let ok = await coordinator.saveTask(task, for: recording)
            await MainActor.run {
                saving = false
                saved = ok
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: LocalizationManager.shared.language == .czech ? "cs_CZ" : "en_US")
        return f.string(from: date)
    }
}
