import Foundation

/// What the call panel recalls about the previous call with the same person.
struct CallBriefing: Equatable {
    let recordingId: UUID
    let date: Date
    /// What that call was about, in one sentence.
    let headline: String
    /// What the user was to do after it (at most three).
    let tasks: [String]
    /// A meeting agreed in that call that hasn't happened yet.
    let meeting: Date?
}

enum CallHistory {
    /// The latest summarised call with the same caller — the same number, client or name.
    static func previousCall(
        in recordings: [Recording],
        number: String?,
        name: String?,
        clientId: UUID?,
        excluding excluded: UUID? = nil
    ) -> Recording? {
        let number = PhonebookEntry.normalize(number ?? "")
        let name = name.nonEmpty
        guard !number.isEmpty || name != nil || clientId != nil else { return nil }
        return recordings
            .filter { $0.id != excluded && $0.summary != nil }
            .filter { recording in
                if !number.isEmpty, let phone = recording.phoneNumber, PhonebookEntry.sameNumber(phone, number) { return true }
                if let clientId, recording.clientId == clientId { return true }
                if let name, let contact = recording.contactName, PhonebookEntry.sameName(contact, name) { return true }
                return false
            }
            .max { $0.startedAt < $1.startedAt }
    }

    static func briefing(from recording: Recording, now: Date = Date()) -> CallBriefing? {
        guard let summary = recording.summary else { return nil }
        let headline = summary.headline.nonEmpty ?? firstSentence(of: summary.humanSummary)
        let tasks = (summary.tasks ?? []).map(\.title).compactMap(\.nonEmpty).prefix(3)
        let meeting = summary.meeting?.startDate.flatMap { $0 > now ? $0 : nil }
        guard !headline.isEmpty || !tasks.isEmpty || meeting != nil else { return nil }
        return CallBriefing(recordingId: recording.id, date: recording.startedAt, headline: headline, tasks: Array(tasks), meeting: meeting)
    }

    /// The first sentence of a text, cut at a word boundary when it's longer than `limit` characters.
    /// "12. 11." or "s.r.o." don't end a sentence: an end is ".", "!" or "?" followed by a capital letter.
    static func firstSentence(of text: String, limit: Int = 140) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = text
        if let match = text.range(of: #"[.!?](?=\s+\p{Lu})"#, options: .regularExpression) {
            sentence = String(text[..<match.upperBound])
        } else if let newline = text.firstIndex(of: "\n") {
            sentence = String(text[..<newline])
        }
        guard sentence.count > limit else { return sentence }
        let cut = sentence.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }
}
