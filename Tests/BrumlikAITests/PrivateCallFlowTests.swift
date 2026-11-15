import XCTest
@testable import BrumlikAI

/// Records nothing; writes placeholder part files so deletions can be checked.
@MainActor
private final class FakeRecorder: CallAudioRecorder {
    var writesParts = true
    private(set) var started: [UUID] = []
    private(set) var stopCount = 0

    func requestAccessIfNeeded() async {}

    func start(recordingId id: UUID, mode: SystemTapMode) throws {
        started.append(id)
        guard writesParts else { return }
        for url in [RecordingStore.micPartURL(for: id), RecordingStore.systemPartURL(for: id)] {
            FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        }
    }

    func stop() throws -> AudioRecorder.Result {
        stopCount += 1
        return AudioRecorder.Result(systemPeak: nil, micPeak: nil, warnings: [])
    }
}

/// Stands in for macOS Contacts: name → numbers.
@MainActor
private final class FakeDirectory: CallerDirectory {
    var people: [String: [String]] = [:]

    func name(for phoneNumber: String) async -> String? {
        people.first { $0.value.contains { PhonebookEntry.sameNumber($0, phoneNumber) } }?.key
    }

    func numbers(forName name: String) async -> [String] {
        people.first { PhonebookEntry.sameName($0.key, name) }?.value ?? []
    }
}

/// The call flow end to end with a fake recorder, fake contacts and a temporary data folder —
/// no audio, network or user data is touched.
final class PrivateCallFlowTests: XCTestCase {
    private var directory: URL!

    @MainActor
    private func makeCoordinator(
        writesParts: Bool = true,
        people: [String: [String]] = [:]
    ) throws -> (AppState, RecordingCoordinator, FakeRecorder) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("brumlik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RecordingStore.directoryOverride = directory
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")

        let appState = AppState()
        appState.consentAcknowledged = true
        let recorder = FakeRecorder()
        recorder.writesParts = writesParts
        let contacts = FakeDirectory()
        contacts.people = people
        // No token, so nothing ever reaches the network or the Keychain.
        let coordinator = RecordingCoordinator(appState: appState, recorder: recorder, contacts: contacts, deepInfraToken: { nil })
        coordinator.notificationsEnabled = false
        return (appState, coordinator, recorder)
    }

    override func tearDown() {
        RecordingStore.directoryOverride = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "consentAcknowledged")
        super.tearDown()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
    }

    @MainActor
    func testDoingNothingKeepsTheCall() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator(writesParts: false)
        coordinator.handleCallEvent(.started(callerHint: "+420 602 000 111"))
        try await waitUntil { coordinator.isRecording }
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        XCTAssertEqual(coordinator.overlay?.isRecording, true)

        coordinator.handleCallEvent(.ended)
        try await waitUntil { !coordinator.isRecording && coordinator.processingIds.isEmpty }
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertNil(coordinator.overlay)
        // Still in the history (processing fails here only because the fake wrote no audio).
        XCTAssertEqual(appState.recording(id)?.phoneNumber, "+420602000111")
    }

    @MainActor
    func testPrivateDuringCallDeletesEverythingAndOffersToRemember() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator()
        coordinator.handleCallEvent(.started(callerHint: "+420 777 123 456"))
        try await waitUntil { coordinator.isRecording }
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.micPartURL(for: id).path))

        await coordinator.discardRecording()
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertNil(appState.recording(id))
        XCTAssertTrue(RecordingStore.load().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: RecordingStore.recordingsDirectory.path)
        XCTAssertTrue(leftovers.isEmpty, "Left behind: \(leftovers)")
        XCTAssertEqual(coordinator.overlay, .discarded(CallerLabel(number: "+420 777 123 456"), canRemember: true))

        coordinator.rememberDiscardedCaller()
        XCTAssertEqual(coordinator.overlay, .remembered(CallerLabel(number: "+420 777 123 456")))
        XCTAssertNotNil(appState.privateRule(number: "777123456", name: nil))
        XCTAssertEqual(PhonebookStore.load().filter(\.doNotRecord).map(\.number), ["+420777123456"])

        // Hanging up afterwards records nothing more.
        coordinator.handleCallEvent(.ended)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertTrue(appState.recordings.isEmpty)
    }

    @MainActor
    func testPrivateCallerIsSkippedByNumberOrNameUntilRecordAnyway() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator()
        appState.setDoNotRecord(true, number: "+420 777 123 456", name: "Máma")

        coordinator.handleCallEvent(.started(callerHint: "777 123 456"))
        try await waitUntil { coordinator.overlay != nil }
        XCTAssertEqual(coordinator.overlay, .skipped(CallerLabel(name: "Máma", number: "+420777123456")))
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(recorder.started.isEmpty)

        coordinator.handleCallEvent(.ended)
        XCTAssertNil(coordinator.overlay)

        // macOS showed only the contact's name this time.
        coordinator.handleCallEvent(.started(callerHint: "mama"))
        try await waitUntil { coordinator.overlay != nil }
        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(appState.recordings.isEmpty)

        coordinator.recordAnyway()
        try await waitUntil { coordinator.isRecording }
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(coordinator.overlay?.isRecording, true)
        await coordinator.discardRecording()
    }

    @MainActor
    func testContactsConnectNamesAndNumbers() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator(people: [
            "Petr Soukup": ["+420 608 111 222"],
            "Babička": ["+420 603 333 444"]
        ])
        appState.setDoNotRecord(true, number: "+420608111222", name: nil)
        appState.setDoNotRecord(true, number: nil, name: "Babička")

        // The window shows a name whose number is on the private list…
        coordinator.handleCallEvent(.started(callerHint: "Petr Soukup"))
        try await waitUntil { coordinator.overlay != nil }
        XCTAssertEqual(coordinator.overlay, .skipped(CallerLabel(name: "Petr Soukup", number: "+420608111222")))
        coordinator.handleCallEvent(.ended)

        // …or a number whose contact is on the list by name.
        coordinator.handleCallEvent(.started(callerHint: "+420 603 333 444"))
        try await waitUntil { coordinator.overlay != nil }
        XCTAssertEqual(coordinator.overlay, .skipped(CallerLabel(name: "Babička", number: "+420 603 333 444")))
        coordinator.handleCallEvent(.ended)
        XCTAssertTrue(recorder.started.isEmpty)
    }

    @MainActor
    func testDiscardingAManualRecordingAsksNothing() async throws {
        let (appState, coordinator, _) = try makeCoordinator()
        await coordinator.startRecording(callerHint: nil, auto: false)
        XCTAssertNil(coordinator.overlay, "Manual recordings don't show the call panel")
        await coordinator.discardRecording()
        XCTAssertEqual(coordinator.overlay, .discarded(CallerLabel(), canRemember: false))
        XCTAssertTrue(appState.recordings.isEmpty)
    }

    @MainActor
    func testDeletingAFinishedCallRemovesItsFiles() async throws {
        let (appState, coordinator, _) = try makeCoordinator()
        await coordinator.startRecording(callerHint: nil, auto: false)
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        await coordinator.stopRecording(process: false)
        XCTAssertNotNil(appState.recording(id))

        await coordinator.deleteRecording(id)
        XCTAssertNil(appState.recording(id))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: RecordingStore.recordingsDirectory.path)
        XCTAssertTrue(leftovers.isEmpty, "Left behind: \(leftovers)")
    }
}
