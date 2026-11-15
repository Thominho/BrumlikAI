import XCTest
@testable import BrumlikAI

/// The call panel recalls the last call with the same caller.
final class BriefingTests: XCTestCase {
    private func call(
        daysAgo: Double,
        number: String? = nil,
        name: String? = nil,
        clientId: UUID? = nil,
        headline: String? = "Nabídka na e-shop.",
        summary: String = "Klient chce nový e-shop do 12. 11. Pak zavolá kvůli doméně.",
        tasks: [String] = [],
        meeting: Date? = nil
    ) -> Recording {
        let start = Date().addingTimeInterval(-daysAgo * 86_400)
        let meetingProposal = meeting.map {
            MeetingProposal(title: "Schůzka", startISO: ISO8601DateFormatter().string(from: $0), durationMinutes: 30, location: nil, notes: nil)
        }
        return Recording(
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            audioURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a"),
            summary: CallSummary(
                headline: headline,
                humanSummary: summary,
                aiPrompt: "",
                requests: [],
                meeting: meetingProposal,
                tasks: tasks.map { TaskProposal(title: $0) }
            ),
            status: .completed,
            clientId: clientId,
            phoneNumber: number,
            contactName: name
        )
    }

    func testFindsTheLatestCallByNumberClientOrName() {
        let client = UUID()
        let older = call(daysAgo: 10, number: "+420602000111")
        let latest = call(daysAgo: 2, number: "602 000 111")
        let colleague = call(daysAgo: 1, number: "+420777000222", clientId: client)
        let byName = call(daysAgo: 3, name: "Máma")
        var unfinished = call(daysAgo: 0.5, number: "+420602000111")
        unfinished.summary = nil
        let recordings = [older, latest, colleague, byName, unfinished]

        XCTAssertEqual(CallHistory.previousCall(in: recordings, number: "+420 602 000 111", name: nil, clientId: nil)?.id, latest.id)
        XCTAssertEqual(CallHistory.previousCall(in: recordings, number: "+420 602 000 111", name: nil, clientId: client)?.id, colleague.id)
        XCTAssertEqual(CallHistory.previousCall(in: recordings, number: nil, name: "mama", clientId: nil)?.id, byName.id)
        XCTAssertEqual(CallHistory.previousCall(in: recordings, number: "602000111", name: nil, clientId: nil, excluding: latest.id)?.id, older.id)
        XCTAssertNil(CallHistory.previousCall(in: recordings, number: "+420 999 999 999", name: nil, clientId: nil))
        XCTAssertNil(CallHistory.previousCall(in: recordings, number: nil, name: " ", clientId: nil))
    }

    func testBriefingShowsHeadlineTasksAndOnlyUpcomingMeetings() throws {
        let upcoming = Date().addingTimeInterval(3 * 86_400)
        let briefing = try XCTUnwrap(CallHistory.briefing(from: call(
            daysAgo: 2,
            tasks: ["Poslat nabídku", " ", "Ověřit doménu", "Zavolat grafikovi", "Čtvrtý úkol"],
            meeting: upcoming
        )))
        XCTAssertEqual(briefing.headline, "Nabídka na e-shop.")
        XCTAssertEqual(briefing.tasks, ["Poslat nabídku", "Ověřit doménu", "Zavolat grafikovi"])
        XCTAssertEqual(try XCTUnwrap(briefing.meeting).timeIntervalSince1970, upcoming.timeIntervalSince1970, accuracy: 1)

        let past = try XCTUnwrap(CallHistory.briefing(from: call(daysAgo: 9, meeting: Date().addingTimeInterval(-86_400))))
        XCTAssertNil(past.meeting)
    }

    func testOlderSummariesUseTheirFirstSentence() throws {
        let briefing = try XCTUnwrap(CallHistory.briefing(from: call(daysAgo: 1, headline: nil)))
        XCTAssertEqual(briefing.headline, "Klient chce nový e-shop do 12. 11.")
    }

    func testFirstSentence() {
        XCTAssertEqual(CallHistory.firstSentence(of: "Klient chce do 12. 11. nabídku. Pak zavolá."), "Klient chce do 12. 11. nabídku.")
        XCTAssertEqual(CallHistory.firstSentence(of: "Jedna věta bez tečky"), "Jedna věta bez tečky")
        XCTAssertEqual(CallHistory.firstSentence(of: "Řekl to! Šlo o web."), "Řekl to!")
        let cut = CallHistory.firstSentence(of: String(repeating: "slovo ", count: 40) + ".", limit: 50)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 51)
    }

    func testBriefingDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9, minute: 40)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 18)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10)))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 24, hour: 10)))

        // Czech formats put non-breaking spaces between the parts.
        func text(_ date: Date, _ language: AppLanguage) -> String {
            CallOverlayCard.briefingDate(date, language: language, now: now)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(text(today, .czech), "dnes 9:40")
        XCTAssertEqual(text(yesterday, .czech), "včera")
        XCTAssertEqual(text(earlier, .czech), "3. 11.")
        XCTAssertEqual(text(lastYear, .czech), "24. 12. 2025")
        XCTAssertEqual(text(earlier, .english), "Nov 3")
        XCTAssertEqual(text(yesterday, .english), "yesterday")
    }

    // MARK: - In a call

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "consentAcknowledged")
        UserDefaults.standard.removeObject(forKey: "showCallBriefing")
        super.tearDown()
    }

    @MainActor
    private func coordinator(with recordings: [Recording]) -> (AppState, RecordingCoordinator) {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        let appState = AppState()
        appState.consentAcknowledged = true
        recordings.forEach(appState.appendRecording)
        let coordinator = RecordingCoordinator(
            appState: appState,
            recorder: SilentRecorder(),
            contacts: NoContacts(),
            speech: FakeSpeech(),
            deepInfraToken: { nil }
        )
        coordinator.notificationsEnabled = false
        return (appState, coordinator)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting")
    }

    @MainActor
    func testCallPanelRecallsTheLastCall() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let previous = call(daysAgo: 3, number: "+420602000111", name: "Jan Novák", tasks: ["Poslat nabídku"])
        let (_, coordinator) = coordinator(with: [previous])

        coordinator.handleCallEvent(.started(callerHint: "+420 602 000 111"))
        try await waitUntil { coordinator.isRecording }
        guard case .recording(_, let briefing) = coordinator.overlay else {
            return XCTFail("The panel should show the recording")
        }
        XCTAssertEqual(briefing?.recordingId, previous.id)
        XCTAssertEqual(briefing?.headline, "Nabídka na e-shop.")
        XCTAssertEqual(briefing?.tasks, ["Poslat nabídku"])
        await coordinator.discardRecording()
    }

    @MainActor
    func testRecapCanBeTurnedOff() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let (appState, coordinator) = coordinator(with: [call(daysAgo: 3, number: "+420602000111")])
        appState.showCallBriefing = false

        coordinator.handleCallEvent(.started(callerHint: "+420 602 000 111"))
        try await waitUntil { coordinator.isRecording }
        XCTAssertEqual(coordinator.overlay, .recording(CallerLabel(number: "+420 602 000 111")))
        await coordinator.discardRecording()
    }

    @MainActor
    func testFirstCallHasNoRecap() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let (_, coordinator) = coordinator(with: [call(daysAgo: 3, number: "+420777000222")])

        coordinator.handleCallEvent(.started(callerHint: "+420 602 000 111"))
        try await waitUntil { coordinator.isRecording }
        XCTAssertEqual(coordinator.overlay, .recording(CallerLabel(number: "+420 602 000 111"), briefing: nil))
        await coordinator.discardRecording()
    }
}
