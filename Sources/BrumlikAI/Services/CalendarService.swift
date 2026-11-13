import Foundation
import EventKit

enum CalendarError: LocalizedError {
    case notAuthorized
    case invalidDate
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return L10n.t(.errCalendarNotAuthorized)
        case .invalidDate: return L10n.t(.errCalendarInvalidDate)
        case .saveFailed(let message): return L10n.f(.errCalendarSaveFailed, message)
        }
    }
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    func createEvent(from meeting: MeetingProposal, calendarId: String?) async throws -> EKEvent {
        guard try await requestAccess() else { throw CalendarError.notAuthorized }
        guard let start = meeting.startDate else { throw CalendarError.invalidDate }

        let event = EKEvent(eventStore: store)
        event.title = meeting.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(15, meeting.durationMinutes) * 60))
        event.location = meeting.location
        event.notes = [meeting.notes, L10n.t(.createdByBrumlik)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        event.calendar = calendarId.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewEvents
            ?? availableCalendars().first

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }
}
