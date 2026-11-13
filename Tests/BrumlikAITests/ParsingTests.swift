import XCTest
@testable import BrumlikAI

final class CallSummaryDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> CallSummary {
        try JSONDecoder().decode(CallSummary.self, from: Data(json.utf8))
    }

    func testDecodesCompleteSummary() throws {
        let summary = try decode("""
        {"humanSummary": "Klient chce černá tlačítka.", "aiPrompt": "Uprav CSS.", "requests": ["Změnit barvu tlačítek"],
         "tasks": [{"title": "Poslat náhled", "dueISO": "2026-11-20T10:00:00+01:00", "notes": null}],
         "meeting": {"title": "Schůzka", "startISO": "2026-11-24T10:00:00+01:00", "durationMinutes": 45, "location": "Pekárna", "notes": null}}
        """)
        XCTAssertEqual(summary.humanSummary, "Klient chce černá tlačítka.")
        XCTAssertEqual(summary.requests, ["Změnit barvu tlačítek"])
        XCTAssertEqual(summary.tasks?.map(\.title), ["Poslat náhled"])
        XCTAssertNotNil(summary.tasks?.first?.dueDate)
        XCTAssertEqual(summary.meeting?.durationMinutes, 45)
        XCTAssertEqual(summary.meeting?.location, "Pekárna")
        XCTAssertNotNil(summary.meeting?.startDate)
    }

    func testMissingFieldsFallBackToEmptyValues() throws {
        let summary = try decode("{}")
        XCTAssertEqual(summary.humanSummary, "")
        XCTAssertEqual(summary.aiPrompt, "")
        XCTAssertEqual(summary.requests, [])
        XCTAssertNil(summary.meeting)
        XCTAssertNil(summary.tasks)
    }

    func testMeetingWithoutTimeIsDroppedButSummaryKept() throws {
        let summary = try decode(#"{"humanSummary": "x", "meeting": {"title": "Schůzka", "startISO": null}}"#)
        XCTAssertNil(summary.meeting)
        XCTAssertEqual(summary.humanSummary, "x")
    }

    func testMeetingGetsDefaultsForMissingTitleAndStringDuration() throws {
        let summary = try decode(#"{"meeting": {"startISO": "2026-11-24T10:00:00", "durationMinutes": "60"}}"#)
        XCTAssertEqual(summary.meeting?.durationMinutes, 60)
        XCTAssertFalse(summary.meeting?.title.isEmpty ?? true)
    }

    func testMalformedTasksAreSkipped() throws {
        let summary = try decode(#"{"tasks": [{"title": "A"}, {"notes": "no title"}, {"title": "  "}, {"title": "B", "dueISO": "2026-11-21"}]}"#)
        XCTAssertEqual(summary.tasks?.map(\.title), ["A", "B"])
    }

    func testJSONIsExtractedFromMarkdownFence() throws {
        let reply = "Here you go:\n```json\n{\"humanSummary\": \"A\", \"requests\": []}\n```"
        let data = try XCTUnwrap(DeepInfraClient.extractJSONObject(from: reply))
        XCTAssertEqual(try JSONDecoder().decode(CallSummary.self, from: data).humanSummary, "A")
    }

    func testNoJSONObjectInReply() {
        XCTAssertNil(DeepInfraClient.extractJSONObject(from: "Sorry, I can't help with that."))
    }

    func testSummaryRoundTrips() throws {
        let original = try decode(#"{"humanSummary": "A", "aiPrompt": "B", "requests": ["r"], "tasks": [{"title": "t"}]}"#)
        let again = try JSONDecoder().decode(CallSummary.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, again)
    }
}

final class FlexibleDateTests: XCTestCase {
    func testISOWithOffset() throws {
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z"))
        XCTAssertEqual(FlexibleDate.parse("2026-11-20T10:00:00+01:00"), expected)
    }

    func testISOWithFractionalSeconds() {
        XCTAssertNotNil(FlexibleDate.parse("2026-11-20T09:00:00.000Z"))
    }

    func testLocalDateTimeWithoutZone() throws {
        let date = try XCTUnwrap(FlexibleDate.parse("2026-11-20T10:30:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 20, 10, 30])
    }

    func testDateOnlyMeansNineInTheMorning() throws {
        let date = try XCTUnwrap(FlexibleDate.parse("2026-11-21"))
        XCTAssertEqual(Calendar.current.component(.hour, from: date), 9)
    }

    func testUnparseableValues() {
        XCTAssertNil(FlexibleDate.parse("příští úterý"))
        XCTAssertNil(FlexibleDate.parse(""))
        XCTAssertNil(FlexibleDate.parse(nil))
    }
}

final class CallerTests: XCTestCase {
    func testNormalizesPhoneNumbers() {
        XCTAssertEqual(PhonebookEntry.normalize(" +420 777 123 456 "), "+420777123456")
    }

    func testRecognisesPhoneNumbers() {
        XCTAssertTrue(CallerDetector.looksLikePhoneNumber("+420 777 123 456"))
        XCTAssertTrue(CallerDetector.looksLikePhoneNumber("(02) 1234-5678"))
        XCTAssertFalse(CallerDetector.looksLikePhoneNumber("Jan Novák"))
        XCTAssertFalse(CallerDetector.looksLikePhoneNumber("Pekárna 12345"))
        XCTAssertFalse(CallerDetector.looksLikePhoneNumber("123"))
    }

    func testExtractsCallerFromWindowTitles() {
        XCTAssertEqual(CallerDetector.extractCaller(from: "FaceTime — Jan Novák"), "Jan Novák")
        XCTAssertEqual(CallerDetector.extractCaller(from: "Audio call with +420 777 123 456"), "+420 777 123 456")
        XCTAssertEqual(CallerDetector.extractCaller(from: "Volání s Janou Malou"), "Janou Malou")
        XCTAssertEqual(CallerDetector.extractCaller(from: "Jan Novák - Design s.r.o."), "Jan Novák - Design s.r.o.")
        XCTAssertNil(CallerDetector.extractCaller(from: "FaceTime"))
        XCTAssertNil(CallerDetector.extractCaller(from: "   "))
    }
}

final class ClientContextTests: XCTestCase {
    func testContextListsManagedSystems() {
        let client = Client(name: "Pekárna U Lípy", ico: "12345678", assets: [
            ManagedAsset(kind: .website, name: "Web", url: "https://pekarna.cz", server: "22.34.23.32", technology: "WordPress"),
            ManagedAsset(kind: .crm, name: "CRM", url: "https://crm.pekarna.cz")
        ])
        let context = client.aiContext()
        for expected in ["Pekárna U Lípy", "12345678", "https://pekarna.cz", "22.34.23.32", "WordPress", "https://crm.pekarna.cz"] {
            XCTAssertTrue(context.contains(expected), "missing \(expected)")
        }
    }

    func testContextNeverContainsCredentialHints() {
        let client = Client(name: "X", assets: [ManagedAsset(name: "Web", credentialsHint: "heslo je v 1Password")])
        XCTAssertFalse(client.aiContext().contains("1Password"))
    }
}
