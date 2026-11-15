import XCTest
@testable import BrumlikAI

/// "Who said what": loudness, echo, merging, and the whole pipeline on real generated audio.
final class TranscriptTests: XCTestCase {
    // MARK: - Builder

    func testSpeechThresholdIgnoresSilentTracks() throws {
        XCTAssertNil(TranscriptBuilder.speechThreshold(for: []))
        XCTAssertNil(TranscriptBuilder.speechThreshold(for: Array(repeating: 0.0005, count: 100)))
        let envelope = Array(repeating: Float(0.001), count: 80) + Array(repeating: Float(0.2), count: 20)
        let threshold = try XCTUnwrap(TranscriptBuilder.speechThreshold(for: envelope))
        XCTAssertGreaterThan(threshold, 0.001)
        XCTAssertLessThan(threshold, 0.2)
    }

    func testTextInventedOverSilenceIsDropped() {
        // Loud from 1.0 s to 2.0 s only.
        let envelope = (0..<50).map { (10..<20).contains($0) ? Float(0.2) : Float(0.0005) }
        let segments = [
            WhisperSegment(start: 1.0, end: 2.0, text: "Dobrý den."),
            WhisperSegment(start: 3.0, end: 4.5, text: "Děkuji za pozornost.")
        ]
        let kept = TranscriptBuilder.keepAudible(segments, envelope: envelope, threshold: 0.02)
        XCTAssertEqual(kept.map(\.text), ["Dobrý den."])
        XCTAssertTrue(TranscriptBuilder.isPhantom("Titulky vytvořil JohnyX"))
        XCTAssertTrue(TranscriptBuilder.isPhantom("www.amara.org"))
        XCTAssertFalse(TranscriptBuilder.isPhantom("Pošlu vám titulní stránku."))
    }

    func testEchoFromSpeakersIsDroppedButRealRepliesStay() {
        let other = [WhisperSegment(start: 2.0, end: 6.0, text: "Potřebovali bychom nový e-shop do Vánoc, jestli to stihnete.")]
        let mine = [
            // The client's voice coming back from the speakers, a little garbled.
            WhisperSegment(start: 2.1, end: 5.9, text: "potřebovali bychom nový e-shop do vánoc jestli to"),
            // The user answering right after.
            WhisperSegment(start: 6.3, end: 8.0, text: "Jasně, do Vánoc to stihneme."),
            // A short reply while the client talks, with a word the client didn't say.
            WhisperSegment(start: 3.0, end: 3.4, text: "Ano.")
        ]
        let kept = TranscriptBuilder.removeEcho(from: mine, other: other)
        XCTAssertEqual(kept.map(\.text), ["Jasně, do Vánoc to stihneme.", "Ano."])
    }

    func testShortEchoInsideTheOtherSideIsDropped() {
        let other = [WhisperSegment(start: 1.0, end: 3.0, text: "Ano, přesně tak.")]
        let mine = [WhisperSegment(start: 1.2, end: 1.6, text: "Ano")]
        XCTAssertTrue(TranscriptBuilder.removeEcho(from: mine, other: other).isEmpty)
    }

    func testMergeOrdersByTime() {
        let merged = TranscriptBuilder.merge(
            mine: [
                WhisperSegment(start: 0.5, end: 2, text: " Dobrý den, tady Novák. "),
                WhisperSegment(start: 6, end: 7, text: "Dobře.")
            ],
            other: [
                WhisperSegment(start: 2.5, end: 5, text: "Dobrý den, volám kvůli nabídce."),
                WhisperSegment(start: 8, end: 9, text: "Thanks for watching!")
            ]
        )
        XCTAssertEqual(merged.map(\.speaker), [.me, .other, .me])
        XCTAssertEqual(merged.first?.text, "Dobrý den, tady Novák.")
    }

    func testTurnsAndLabelledText() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, speaker: .me, text: "Dobrý den."),
            TranscriptSegment(start: 2.2, end: 3, speaker: .me, text: "Tady Novák."),
            TranscriptSegment(start: 3.5, end: 6, speaker: .other, text: "Dobrý den, volám kvůli nabídce."),
            TranscriptSegment(start: 65, end: 70, speaker: .me, text: "Pošlu ji do pátku.")
        ]
        XCTAssertEqual(TranscriptBuilder.turns(segments).map(\.indices), [0..<2, 2..<3, 3..<4])
        let text = TranscriptBuilder.labelledText(segments, withTimes: true) { $0 == .me ? "Vy" : "Jan" }
        XCTAssertEqual(text, "[0:00] Vy: Dobrý den. Tady Novák.\n[0:03] Jan: Dobrý den, volám kvůli nabídce.\n[1:05] Vy: Pošlu ji do pátku.")
        XCTAssertEqual(TranscriptBuilder.clock(3725), "1:02:05")
    }

    func testPlaybackHighlightsTheSentenceBeingPlayed() {
        let segments = [
            TranscriptSegment(start: 0.5, end: 2, speaker: .me, text: "Dobrý den."),
            TranscriptSegment(start: 3, end: 6, speaker: .other, text: "Volám kvůli nabídce."),
            TranscriptSegment(start: 60, end: 62, speaker: .me, text: "Dobře.")
        ]
        XCTAssertNil(TranscriptTurnsView.activeIndex(in: segments, at: 0.1))
        XCTAssertEqual(TranscriptTurnsView.activeIndex(in: segments, at: 1), 0)
        XCTAssertEqual(TranscriptTurnsView.activeIndex(in: segments, at: 2.5), 0, "a short pause keeps the last sentence")
        XCTAssertEqual(TranscriptTurnsView.activeIndex(in: segments, at: 4), 1)
        XCTAssertNil(TranscriptTurnsView.activeIndex(in: segments, at: 45), "a long silence highlights nothing")
        XCTAssertEqual(TranscriptTurnsView.activeIndex(in: segments, at: 61), 2)
    }

    func testLongMonologueIsSplitIntoBlocks() {
        let segments = (0..<30).map {
            TranscriptSegment(start: Double($0) * 10, end: Double($0) * 10 + 9, speaker: .other, text: "Věta \($0).")
        }
        let turns = TranscriptBuilder.turns(segments)
        XCTAssertGreaterThan(turns.count, 1)
        XCTAssertEqual(turns.flatMap { Array($0.indices) }, Array(0..<30))
    }

    func testTheSummaryKnowsWhoSpoke() {
        var recording = Recording(audioURL: URL(fileURLWithPath: "/tmp/call.m4a"))
        recording.transcript = "Dobrý den. Dobrý den, volám."
        XCTAssertFalse(recording.hasSpeakers)
        XCTAssertEqual(recording.transcriptForAI, "Dobrý den. Dobrý den, volám.")
        recording.segments = [
            TranscriptSegment(start: 0, end: 1, speaker: .me, text: "Dobrý den."),
            TranscriptSegment(start: 1.5, end: 3, speaker: .other, text: "Dobrý den, volám.")
        ]
        XCTAssertTrue(recording.hasSpeakers)
        XCTAssertEqual(recording.transcriptForAI, "USER: Dobrý den.\nCLIENT: Dobrý den, volám.")
    }

    func testCallsSavedByOlderVersionsStillLoad() throws {
        // An older version wrote the same keys minus the new ones.
        let old = Recording(audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), transcript: "Ahoj", status: .completed)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["segments"] = nil
        object["emailDraft"] = nil
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.segments)
        XCTAssertNil(decoded.emailDraft)
        XCTAssertEqual(decoded.transcriptForAI, "Ahoj")

        var new = old
        new.segments = [TranscriptSegment(start: 1, end: 2, speaker: .other, text: "Dobrý den.")]
        new.emailDraft = EmailDraft(to: "a@b.cz", subject: "S", body: "B", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(new)), new)
    }

    func testWhisperResponseKeepsTimes() throws {
        let json = #"""
        {"text":" Dobrý den. Volám.","segments":[{"id":0,"start":0.0,"end":1.4,"text":" Dobrý den."},
        {"id":1,"start":1.6,"end":2.9,"text":" Volám."}],"language":"cs"}
        """#
        XCTAssertEqual(try DeepInfraClient.parseWhisperResponse(Data(json.utf8)), [
            WhisperSegment(start: 0, end: 1.4, text: " Dobrý den."),
            WhisperSegment(start: 1.6, end: 2.9, text: " Volám.")
        ])
        XCTAssertEqual(try DeepInfraClient.parseWhisperResponse(Data(#"{"text":"Ahoj"}"#.utf8)).map(\.text), ["Ahoj"])
        XCTAssertEqual(try DeepInfraClient.parseWhisperResponse(Data(#"{"text":"  ","segments":[]}"#.utf8)), [])
        XCTAssertThrowsError(try DeepInfraClient.parseWhisperResponse(Data("nope".utf8)))
    }

    func testSummaryHeadlineIsOptional() throws {
        let old = try JSONDecoder().decode(CallSummary.self, from: Data(#"{"humanSummary":"S","aiPrompt":"","requests":[]}"#.utf8))
        XCTAssertNil(old.headline)
        let new = try JSONDecoder().decode(
            CallSummary.self,
            from: Data(#"{"headline":"  Nabídka na e-shop. ","humanSummary":"S","aiPrompt":"","requests":[]}"#.utf8)
        )
        XCTAssertEqual(new.headline, "Nabídka na e-shop.")
    }

    // MARK: - Audio

    func testSpeechCopyIsSmallAndKeepsTheLoudness() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let part = store.directory.appendingPathComponent("part.caf")
        try TestAudio.write(to: part, duration: 4, loud: [1.0...2.0], channels: 2)
        let speech = store.directory.appendingPathComponent("speech.m4a")
        try await AudioLevels.exportSpeech(from: part, to: speech)

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: speech.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 1_000)
        XCTAssertLessThan(size, 60_000, "4 s at 32 kbps should be about 16 KB")

        let levels = try await AudioLevels.envelope(of: speech)
        XCTAssertEqual(Double(levels.count), 40, accuracy: 3)
        let threshold = try XCTUnwrap(TranscriptBuilder.speechThreshold(for: levels))
        XCTAssertTrue(TranscriptBuilder.hasSpeech(levels, threshold: threshold, from: 1.1, to: 1.9))
        XCTAssertFalse(TranscriptBuilder.hasSpeech(levels, threshold: threshold, from: 2.6, to: 3.8))
    }

    func testTranscriberTellsTheSpeakersApart() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let id = UUID()
        let mic = store.directory.appendingPathComponent("mic.caf")
        let system = store.directory.appendingPathComponent("system.caf")
        try TestAudio.write(to: mic, duration: 6, loud: [0.5...2.0, 5.0...5.8])
        try TestAudio.write(to: system, duration: 6, loud: [2.5...4.5], channels: 2)
        let mine = RecordingStore.myTrackURL(for: id)
        let other = RecordingStore.otherTrackURL(for: id)
        try await AudioLevels.exportSpeech(from: mic, to: mine)
        try await AudioLevels.exportSpeech(from: system, to: other)

        let speech = FakeSpeech()
        speech.segmentsByName = [
            ".me.": [
                WhisperSegment(start: 0.5, end: 2.0, text: "Dobrý den, tady Novák."),
                // The client's words, "heard" while the microphone was silent: dropped.
                WhisperSegment(start: 2.6, end: 4.4, text: "Volám kvůli té nabídce na e-shop."),
                WhisperSegment(start: 5.0, end: 5.8, text: "Dobře, pošlu ji.")
            ],
            ".other.": [
                // Invented over silence: dropped.
                WhisperSegment(start: 0.6, end: 1.8, text: "Titulky vytvořil JohnyX"),
                WhisperSegment(start: 2.5, end: 4.5, text: "Volám kvůli té nabídce na e-shop.")
            ]
        ]
        let output = try await CallTranscriber(engine: speech).transcribe(
            CallTranscriber.Tracks(mixed: mic, mine: mine, other: other),
            language: "cs"
        )
        XCTAssertEqual(output.segments.map(\.speaker), [.me, .other, .me])
        XCTAssertEqual(output.segments.map(\.text), ["Dobrý den, tady Novák.", "Volám kvůli té nabídce na e-shop.", "Dobře, pošlu ji."])
        XCTAssertEqual(output.text, "Dobrý den, tady Novák. Volám kvůli té nabídce na e-shop. Dobře, pošlu ji.")
        XCTAssertEqual(Set(speech.transcribedFiles), [mine.lastPathComponent, other.lastPathComponent])
    }

    func testWithoutSeparateSidesTheMixIsTranscribedAsOne() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let mixed = store.directory.appendingPathComponent("mixed.caf")
        try TestAudio.write(to: mixed, duration: 3, loud: [0.5...2.5])
        let speech = FakeSpeech()
        speech.segmentsByName = ["mixed": [WhisperSegment(start: 0.5, end: 2.5, text: "Dobrý den.")]]
        let output = try await CallTranscriber(engine: speech).transcribe(
            CallTranscriber.Tracks(mixed: mixed, mine: nil, other: nil),
            language: nil
        )
        XCTAssertEqual(output.segments, [TranscriptSegment(start: 0.5, end: 2.5, speaker: .unknown, text: "Dobrý den.")])
    }

    func testSilentCallUploadsNothing() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let id = UUID()
        for url in [RecordingStore.myTrackURL(for: id), RecordingStore.otherTrackURL(for: id)] {
            let part = url.deletingPathExtension().appendingPathExtension("caf")
            try TestAudio.write(to: part, duration: 3, loud: [])
            try await AudioLevels.exportSpeech(from: part, to: url)
        }
        let speech = FakeSpeech()
        let output = try await CallTranscriber(engine: speech).transcribe(
            CallTranscriber.Tracks(
                mixed: RecordingStore.mixedURL(for: id),
                mine: RecordingStore.myTrackURL(for: id),
                other: RecordingStore.otherTrackURL(for: id)
            ),
            language: nil
        )
        XCTAssertEqual(output.text, "")
        XCTAssertTrue(speech.transcribedFiles.isEmpty)
    }

    // MARK: - Pipeline

    /// A real recording through the pipeline: mixing, the separate sides, the transcript and the clean-up.
    @MainActor
    func testRecordedCallGetsSpeakersAndTheSidesAreRemoved() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let appState = AppState()
        let speech = FakeSpeech()
        speech.segmentsByName = [
            ".me.": [WhisperSegment(start: 0.5, end: 2.0, text: "Dobrý den, tady Novák.")],
            ".other.": [WhisperSegment(start: 2.5, end: 4.5, text: "Dobrý den, volám kvůli nabídce.")]
        ]
        // No token: summarising stops before anything is sent anywhere.
        let coordinator = RecordingCoordinator(
            appState: appState,
            recorder: AudioWritingRecorder(),
            contacts: NoContacts(),
            speech: speech,
            deepInfraToken: { nil }
        )
        coordinator.notificationsEnabled = false

        await coordinator.startRecording(callerHint: nil, auto: false)
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        await coordinator.stopRecording()

        let recording = try XCTUnwrap(appState.recording(id))
        XCTAssertEqual(recording.segments?.map(\.speaker), [.me, .other])
        XCTAssertEqual(recording.transcript, "Dobrý den, tady Novák. Dobrý den, volám kvůli nabídce.")
        XCTAssertEqual(recording.status, .failed, "summarising needs the API token")
        XCTAssertEqual(recording.errorMessage, DeepInfraError.missingToken.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.mixedURL(for: id).path), "kept for playback")
        for url in [RecordingStore.myTrackURL(for: id), RecordingStore.otherTrackURL(for: id),
                    RecordingStore.micPartURL(for: id), RecordingStore.systemPartURL(for: id)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }
}
