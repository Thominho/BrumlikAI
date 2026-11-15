import XCTest
import SwiftUI
@testable import BrumlikAI

final class PrivateCallTests: XCTestCase {
    func testSameNumberIgnoresFormatting() {
        XCTAssertTrue(PhonebookEntry.sameNumber("+420 777 123 456", "777123456"))
        XCTAssertTrue(PhonebookEntry.sameNumber("00420777123456", "+420777123456"))
        XCTAssertTrue(PhonebookEntry.sameNumber("12345", "1 2 3 4 5"))
        XCTAssertFalse(PhonebookEntry.sameNumber("777123456", "777123457"))
        XCTAssertFalse(PhonebookEntry.sameNumber("", "777123456"))
        // Short numbers have to match in full.
        XCTAssertFalse(PhonebookEntry.sameNumber("12345", "912345"))
    }

    func testSameNameIgnoresCaseAndDiacritics() {
        XCTAssertTrue(PhonebookEntry.sameName("Jan Novák", " jan novak "))
        XCTAssertTrue(PhonebookEntry.sameName("Máma", "MAMA"))
        XCTAssertFalse(PhonebookEntry.sameName("Jan", "Jan Novák"))
        XCTAssertFalse(PhonebookEntry.sameName("", ""))
    }

    func testOlderPhonebookDecodesAsNotPrivate() throws {
        let json = #"[{"clientId":null,"name":"Jan Novák","number":"+420777123456","updatedAt":"2026-11-01T10:00:00Z"}]"#
        let entries = try JSONDecoder.brumlik.decode([PhonebookEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Jan Novák")
        XCTAssertFalse(entries[0].doNotRecord)
    }

    func testPrivateFlagSurvivesSaving() throws {
        let entry = PhonebookEntry(number: "+420 777 123 456", name: "", doNotRecord: true)
        let data = try JSONEncoder.brumlik.encode([entry])
        let decoded = try JSONDecoder.brumlik.decode([PhonebookEntry].self, from: data)
        XCTAssertEqual(decoded.first?.number, "+420777123456")
        XCTAssertEqual(decoded.first?.doNotRecord, true)
    }

    func testRuleMatchesNumberInAnyFormatOrName() {
        let book = [
            PhonebookEntry(number: "+420777123456", name: "Máma", doNotRecord: true),
            PhonebookEntry(number: "+420602000111", name: "Klient", doNotRecord: false),
            PhonebookEntry(number: "", name: "Petr Soukromý", doNotRecord: true)
        ]
        XCTAssertEqual(PrivateCalls.rule(in: book, number: "777 123 456", name: nil)?.name, "Máma")
        XCTAssertEqual(PrivateCalls.rule(in: book, number: nil, name: "mama")?.number, "+420777123456")
        XCTAssertEqual(PrivateCalls.rule(in: book, number: nil, name: "petr soukromy")?.name, "Petr Soukromý")
        XCTAssertNil(PrivateCalls.rule(in: book, number: "+420602000111", name: "Klient"))
        XCTAssertNil(PrivateCalls.rule(in: book, number: nil, name: nil))
    }

    func testMarkingKeepsTheEntryAndMakesNoTwins() {
        let client = UUID()
        var book = [PhonebookEntry(number: "+420777123456", name: "Jan Novák", clientId: client)]
        book = PrivateCalls.setting(true, number: "777 123 456", name: "Jan", in: book)
        XCTAssertEqual(book.count, 1)
        XCTAssertTrue(book[0].doNotRecord)
        XCTAssertEqual(book[0].name, "Jan Novák")
        XCTAssertEqual(book[0].clientId, client)

        // Blocked by name first (the call window showed only "Máma"), the number comes later.
        book = PrivateCalls.setting(true, number: nil, name: "Máma", in: book)
        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(book[1].number, "")
        book = PrivateCalls.setting(true, number: "+420 608 000 000", name: "máma", in: book)
        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(book[1].number, "+420608000000")
        XCTAssertEqual(book[1].name, "Máma")
    }

    func testUnmarkingDropsEntriesThatOnlyBlocked() {
        var book = PrivateCalls.setting(true, number: "+420777000111", name: nil, in: [])
        XCTAssertEqual(book.count, 1)
        book = PrivateCalls.setting(false, number: "777000111", name: nil, in: book)
        XCTAssertTrue(book.isEmpty)

        // A named phonebook entry stays; it's just no longer private.
        var named = [PhonebookEntry(number: "+420777123456", name: "Jan Novák", doNotRecord: true)]
        named = PrivateCalls.setting(false, number: "+420777123456", name: nil, in: named)
        XCTAssertEqual(named.count, 1)
        XCTAssertFalse(named[0].doNotRecord)
    }

    func testEmptyCallerChangesNothing() {
        let book = [PhonebookEntry(number: "+420777123456", name: "Jan Novák")]
        XCTAssertEqual(PrivateCalls.setting(true, number: " ", name: "", in: book), book)
    }

    func testCallerLabelFromCallWindow() {
        XCTAssertEqual(CallerLabel(hint: "+420 777 123 456").number, "+420 777 123 456")
        XCTAssertNil(CallerLabel(hint: "+420 777 123 456").name)
        XCTAssertEqual(CallerLabel(hint: "Jan Novák").name, "Jan Novák")
        XCTAssertTrue(CallerLabel(hint: "  ").isEmpty)
        XCTAssertTrue(CallerLabel(hint: nil).isEmpty)
        XCTAssertEqual(CallerLabel(name: "Jan", number: "777").subtitle, "777")
    }

    func testClockFormat() {
        XCTAssertEqual(CallOverlayCard.clock(83), "01:23")
        XCTAssertEqual(CallOverlayCard.clock(3725), "1:02:05")
        XCTAssertEqual(CallOverlayCard.clock(-4), "00:00")
    }

    /// Writes PNGs of every panel state when BRUMLIK_RENDER_DIR is set, for a visual check.
    @MainActor
    func testRenderCallPanel() throws {
        guard let directory = ProcessInfo.processInfo.environment["BRUMLIK_RENDER_DIR"] else {
            throw XCTSkip("Set BRUMLIK_RENDER_DIR to render the call panel.")
        }
        let caller = CallerLabel(name: "Jan Novák", number: "+420 777 123 456")
        let briefing = CallBriefing(
            recordingId: UUID(),
            date: Date().addingTimeInterval(-6 * 86_400),
            headline: "Nabídka na nový e-shop; klient chce spustit před Vánoci.",
            tasks: ["Poslat cenovou nabídku do pátku", "Ověřit volnou doménu"],
            meeting: Date().addingTimeInterval(3 * 86_400)
        )
        let states: [(String, CallOverlay, Bool)] = [
            ("1-recording", .recording(caller), false),
            ("2-pill", .recording(caller), true),
            ("3-discarded-ask", .discarded(caller, canRemember: true), false),
            ("4-discarded-unknown", .discarded(CallerLabel(), canRemember: false), false),
            ("5-remembered", .remembered(caller), false),
            ("6-skipped", .skipped(CallerLabel(name: "Máma")), false),
            ("7-briefing", .recording(caller, briefing: briefing), false),
            ("8-briefing-pill", .recording(caller, briefing: briefing), true)
        ]
        for language in AppLanguage.allCases {
            for (name, state, collapsed) in states {
                let view = CallOverlayCard(state: state, duration: 83, language: language, collapsed: .constant(collapsed))
                    .fixedSize()
                    .padding(28)
                    .background(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.92)], startPoint: .top, endPoint: .bottom))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(language.rawValue)-\(name).png"))
            }
        }
    }
}
