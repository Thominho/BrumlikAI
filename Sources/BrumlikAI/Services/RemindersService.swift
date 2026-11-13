import Foundation
import EventKit

enum RemindersError: LocalizedError {
    case notAuthorized
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return L10n.t(.errRemindersNotAuthorized)
        case .saveFailed(let message): return L10n.f(.errRemindersSaveFailed, message)
        }
    }
}

@MainActor
final class RemindersService {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func availableLists() -> [EKCalendar] {
        store.calendars(for: .reminder).filter { $0.allowsContentModifications }
    }

    func createReminder(from task: TaskProposal, clientName: String?, listId: String?) async throws -> EKReminder {
        guard try await requestAccess() else { throw RemindersError.notAuthorized }

        let reminder = EKReminder(eventStore: store)
        reminder.title = clientName.map { "[\($0)] \(task.title)" } ?? task.title
        reminder.notes = [task.notes, L10n.t(.createdByBrumlik)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if let due = task.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        reminder.calendar = listId.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewReminders()
            ?? availableLists().first

        do {
            try store.save(reminder, commit: true)
            return reminder
        } catch {
            throw RemindersError.saveFailed(error.localizedDescription)
        }
    }
}
