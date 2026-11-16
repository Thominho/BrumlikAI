import XCTest
@testable import BrumlikAI

/// Google Meet and WhatsApp calls: telling them from Chrome's window titles.
final class OnlineCallRecognitionTests: XCTestCase {
    func testMeetMeetingCode() {
        XCTAssertEqual(
            OnlineCallRecognizer.meet(from: "Meet - abc-defg-hij"),
            OnlineCall(service: .meet, app: .chrome, meetingCode: "abc-defg-hij")
        )
        XCTAssertEqual(OnlineCallRecognizer.meet(from: "Meet – abc-defg-hij - Google Chrome - Work")?.meetingCode, "abc-defg-hij")
        XCTAssertNil(OnlineCallRecognizer.meet(from: "Meet - abc-defg-hij")?.title)
    }

    func testMeetWithTheMeetingsName() {
        XCTAssertEqual(OnlineCallRecognizer.meet(from: "Meet – Týdenní porada")?.title, "Týdenní porada")
        XCTAssertEqual(OnlineCallRecognizer.meet(from: "Weekly sync - Google Meet")?.title, "Weekly sync")
        let both = OnlineCallRecognizer.meet(from: "Meet - Weekly sync (abc-defg-hij)")
        XCTAssertEqual(both?.title, "Weekly sync (abc-defg-hij)")
        XCTAssertEqual(both?.meetingCode, "abc-defg-hij")
    }

    func testMeetStartPage() {
        XCTAssertEqual(OnlineCallRecognizer.meet(from: "Google Meet"), OnlineCall(service: .meet, app: .chrome))
    }

    func testOtherPagesAreNotMeet() {
        XCTAssertNil(OnlineCallRecognizer.meet(from: "Meet the team – Acme"))
        XCTAssertNil(OnlineCallRecognizer.meet(from: "Meeting notes - Google Docs"))
        XCTAssertNil(OnlineCallRecognizer.meet(from: "Inbox (3) - Gmail"))
    }

    func testWhatsApp() {
        XCTAssertTrue(OnlineCallRecognizer.isWhatsApp("WhatsApp"))
        XCTAssertTrue(OnlineCallRecognizer.isWhatsApp("(3) WhatsApp"))
        XCTAssertTrue(OnlineCallRecognizer.isWhatsApp("WhatsApp Business - Google Chrome"))
        XCTAssertFalse(OnlineCallRecognizer.isWhatsApp("How to make WhatsApp calls - The Verge"))
    }

    func testAMeetingWinsOverWhatsAppLeftOpenInATab() {
        XCTAssertEqual(OnlineCallRecognizer.recognize(chromeTitles: ["(2) WhatsApp", "Meet - abc-defg-hij"])?.service, .meet)
        XCTAssertEqual(OnlineCallRecognizer.recognize(chromeTitles: ["Google Meet", "(2) WhatsApp"]), OnlineCall(service: .whatsapp, app: .chrome))
        XCTAssertEqual(OnlineCallRecognizer.recognize(chromeTitles: ["Google Meet"])?.service, .meet)
        XCTAssertNil(OnlineCallRecognizer.recognize(chromeTitles: ["GitHub", "YouTube"]))
        XCTAssertNil(OnlineCallRecognizer.recognize(chromeTitles: []))
    }

    func testLabels() {
        let meet = OnlineCall(service: .meet, app: .chrome, meetingCode: "ABC-defg-hij")
        XCTAssertEqual(meet.meetingCode, "abc-defg-hij")
        XCTAssertEqual(CallerLabel(online: meet).title, "Google Meet")
        XCTAssertEqual(CallerLabel(online: meet).subtitle, "abc-defg-hij")
        XCTAssertEqual(meet.detail, "Google Meet · abc-defg-hij")

        let named = CallerLabel(online: OnlineCall(service: .meet, app: .chrome, title: "Weekly sync"))
        XCTAssertEqual(named.title, "Weekly sync")
        XCTAssertEqual(named.subtitle, "Google Meet")
        XCTAssertFalse(named.isEmpty)
        XCTAssertFalse(named.canBePrivate, "A meeting can't go on the private list of numbers and names")
        XCTAssertTrue(CallerLabel(number: "+420 777 123 456").canBePrivate)
    }

    func testOlderRecordingsLoadWithoutOnlineCall() throws {
        let recording = Recording(audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), status: .completed)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recording)) as? [String: Any])
        json["onlineCall"] = nil
        let old = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.onlineCall)

        var meet = recording
        meet.onlineCall = OnlineCall(service: .meet, app: .chrome, meetingCode: "abc-defg-hij")
        XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(meet)).onlineCall, meet.onlineCall)
    }

    func testSummaryPromptSaysWhatKindOfCallItWas() {
        XCTAssertEqual(
            DeepInfraClient.callDescription(nil, hasSpeakers: true),
            "a recorded phone call between the app's user and a client. Every line of the transcript starts with who is speaking: USER (the app's user) or CLIENT (the other party)."
        )
        let meet = DeepInfraClient.callDescription(OnlineCall(service: .meet, app: .chrome), hasSpeakers: true)
        XCTAssertTrue(meet.contains("Google Meet video call"))
        XCTAssertTrue(meet.contains("it may be several people"))
        XCTAssertTrue(DeepInfraClient.callDescription(OnlineCall(service: .whatsapp, app: .whatsapp), hasSpeakers: false).contains("WhatsApp call"))
    }
}

/// When the detector starts and ends a call — with what Core Audio and Chrome's windows would report.
final class CallDetectorTests: XCTestCase {
    private var activity = CallAudioActivity()
    private var chromeCall: OnlineCall? = OnlineCall(service: .meet, app: .chrome, meetingCode: "abc-defg-hij")
    private var onlineCallsEnabled = true
    private var events: [String] = []
    private var startedOnline: OnlineCall?

    @MainActor
    private func makeDetector() -> CallDetector {
        CallDetector(
            detectsOnlineCalls: { [unowned self] in self.onlineCallsEnabled },
            probe: { [unowned self] in self.activity },
            recognizeChromeCall: { [unowned self] in self.chromeCall },
            callerHint: { "+420 777 123 456" }
        ) { [unowned self] event in
            switch event {
            case .started(let hint, let online):
                self.startedOnline = online
                self.events.append("started \(online?.serviceName ?? hint ?? "-")")
            case .ended:
                self.events.append("ended")
            }
        }
    }

    @MainActor
    private func poll(_ detector: CallDetector, times: Int) {
        for _ in 0..<times { detector.poll() }
    }

    @MainActor
    func testMeetInChromeLastsWhileChromeKeepsTheMicrophone() {
        let detector = makeDetector()
        activity.chrome = .init(input: true, output: true)
        detector.poll()
        XCTAssertEqual(events, [], "One look isn't a call yet")
        detector.poll()
        XCTAssertEqual(events, ["started Google Meet"])
        XCTAssertEqual(startedOnline, chromeCall)

        // Nobody speaking (or you're muted): Chrome still holds the microphone.
        activity.chrome = .init(input: true, output: false)
        poll(detector, times: 5)
        XCTAssertEqual(events, ["started Google Meet"])

        // Left the meeting; another tab goes on playing.
        activity.chrome = .init(input: false, output: true)
        poll(detector, times: 2)
        XCTAssertEqual(events, ["started Google Meet"])
        detector.poll()
        XCTAssertEqual(events, ["started Google Meet", "ended"])
    }

    @MainActor
    func testMeetWaitingRoomIsNotACall() {
        let detector = makeDetector()
        activity.chrome = .init(input: true, output: false)
        poll(detector, times: 4)
        XCTAssertEqual(events, [])
    }

    @MainActor
    func testChromeCallNeedsARecognisedWindow() {
        let detector = makeDetector()
        chromeCall = nil
        activity.chrome = .init(input: true, output: true)
        poll(detector, times: 4)
        XCTAssertEqual(events, [])
    }

    @MainActor
    func testWhatsAppAppCall() {
        let detector = makeDetector()
        activity.whatsApp = .init(input: true, output: true)
        poll(detector, times: 2)
        XCTAssertEqual(events, ["started WhatsApp"])
        XCTAssertEqual(startedOnline, OnlineCall(service: .whatsapp, app: .whatsapp))

        activity.whatsApp = .init(input: false, output: true)
        poll(detector, times: 4)
        XCTAssertEqual(events, ["started WhatsApp"])
        activity.whatsApp = .init()
        poll(detector, times: 3)
        XCTAssertEqual(events, ["started WhatsApp", "ended"])
    }

    @MainActor
    func testWhatsAppVoiceMessageIsNotACall() {
        let detector = makeDetector()
        activity.whatsApp = .init(input: true, output: false)
        poll(detector, times: 4)
        XCTAssertEqual(events, [])
    }

    @MainActor
    func testOnlineCallsCanBeTurnedOff() {
        let detector = makeDetector()
        onlineCallsEnabled = false
        activity.chrome = .init(input: true, output: true)
        activity.whatsApp = .init(input: true, output: true)
        poll(detector, times: 3)
        XCTAssertEqual(events, [])

        activity.phoneCall = true
        poll(detector, times: 2)
        XCTAssertEqual(events, ["started +420 777 123 456"])
        XCTAssertNil(startedOnline)
    }

    @MainActor
    func testAPhoneCallWinsAndMustLastOnItsOwn() {
        let detector = makeDetector()
        activity.chrome = .init(input: true, output: true)
        detector.poll()
        activity.phoneCall = true
        detector.poll()
        XCTAssertEqual(events, [], "A different kind of call starts counting again")
        detector.poll()
        XCTAssertEqual(events, ["started +420 777 123 456"])
    }
}

/// Records nothing; remembers how the system audio would have been tapped.
@MainActor
private final class TapModeRecorder: CallAudioRecorder {
    private(set) var modes: [SystemTapMode] = []
    func requestAccessIfNeeded() async {}
    func start(recordingId id: UUID, mode: SystemTapMode) throws { modes.append(mode) }
    func stop() throws -> AudioRecorder.Result { AudioRecorder.Result(systemPeak: nil, micPeak: nil, warnings: []) }
}

/// Recording a Meet call end to end, with a fake recorder and a temporary data folder.
final class OnlineCallFlowTests: XCTestCase {
    private var store: TemporaryStore?

    override func tearDown() {
        store?.remove()
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "consentAcknowledged")
        super.tearDown()
    }

    @MainActor
    private func makeCoordinator(with recordings: [Recording] = []) throws -> (AppState, RecordingCoordinator, TapModeRecorder) {
        store = try TemporaryStore()
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        let appState = AppState()
        appState.consentAcknowledged = true
        recordings.forEach { appState.appendRecording($0) }
        let recorder = TapModeRecorder()
        // No token, so nothing ever reaches the network or the Keychain.
        let coordinator = RecordingCoordinator(appState: appState, recorder: recorder, contacts: NoContacts(), deepInfraToken: { nil })
        coordinator.notificationsEnabled = false
        return (appState, coordinator, recorder)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
    }

    private func meeting(daysAgo: Double, code: String, clientId: UUID?, headline: String) -> Recording {
        let start = Date().addingTimeInterval(-daysAgo * 86_400)
        return Recording(
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            audioURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a"),
            summary: CallSummary(headline: headline, humanSummary: headline, aiPrompt: "", requests: [], meeting: nil, tasks: [TaskProposal(title: "Poslat zápis")]),
            status: .completed,
            clientId: clientId,
            onlineCall: OnlineCall(service: .meet, app: .chrome, meetingCode: code)
        )
    }

    @MainActor
    func testMeetCallIsRecordedWithChromeKeptInTheTap() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator()
        let meet = OnlineCall(service: .meet, app: .chrome, meetingCode: "abc-defg-hij")
        coordinator.handleCallEvent(.started(callerHint: nil, online: meet))
        try await waitUntil { coordinator.isRecording }

        XCTAssertEqual(recorder.modes, [.callFocused(keeping: "com.google.Chrome")])
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        XCTAssertEqual(appState.recording(id)?.onlineCall, meet)
        XCTAssertNil(appState.recording(id)?.phoneNumber)
        XCTAssertEqual(coordinator.overlay, .recording(CallerLabel(online: meet), briefing: nil))

        // "Private – don't record" works; a meeting isn't offered for the list of private numbers.
        await coordinator.discardRecording()
        XCTAssertNil(appState.recording(id))
        XCTAssertEqual(coordinator.overlay, .discarded(CallerLabel(online: meet), canRemember: false))
    }

    @MainActor
    func testRecurringMeetingRecallsTheLastOneAndKeepsItsClient() async throws {
        let client = UUID()
        let older = meeting(daysAgo: 14, code: "abc-defg-hij", clientId: client, headline: "Spuštění e-shopu.")
        let last = meeting(daysAgo: 7, code: "abc-defg-hij", clientId: nil, headline: "Termín spuštění posunut.")
        let other = meeting(daysAgo: 1, code: "xyz-wxyz-xyz", clientId: UUID(), headline: "Jiná porada.")
        let (appState, coordinator, _) = try makeCoordinator(with: [older, last, other])

        coordinator.handleCallEvent(.started(callerHint: nil, online: OnlineCall(service: .meet, app: .chrome, meetingCode: "abc-defg-hij")))
        try await waitUntil { coordinator.isRecording }
        guard case .recording(_, let briefing) = coordinator.overlay else {
            return XCTFail("The panel should show the recording")
        }
        XCTAssertEqual(briefing?.recordingId, last.id)
        XCTAssertEqual(briefing?.headline, "Termín spuštění posunut.")
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        XCTAssertEqual(appState.recording(id)?.clientId, client)
        await coordinator.discardRecording()
    }

    @MainActor
    func testWhatsAppCallHasNoRecapOrClient() async throws {
        let (appState, coordinator, recorder) = try makeCoordinator(with: [meeting(daysAgo: 2, code: "abc-defg-hij", clientId: UUID(), headline: "Porada.")])
        coordinator.handleCallEvent(.started(callerHint: nil, online: OnlineCall(service: .whatsapp, app: .whatsapp)))
        try await waitUntil { coordinator.isRecording }

        XCTAssertEqual(recorder.modes, [.callFocused(keeping: "net.whatsapp.")])
        XCTAssertEqual(coordinator.overlay, .recording(CallerLabel(online: OnlineCall(service: .whatsapp, app: .whatsapp)), briefing: nil))
        let id = try XCTUnwrap(coordinator.activeRecordingId)
        XCTAssertNil(appState.recording(id)?.clientId)

        coordinator.handleCallEvent(.ended)
        try await waitUntil { !coordinator.isRecording && coordinator.processingIds.isEmpty }
        // Still in the history (processing fails here only because the fake wrote no audio).
        XCTAssertEqual(appState.recording(id)?.onlineCall?.service, .whatsapp)
    }

    @MainActor
    func testPhoneCallsStillKeepNothingButCallApps() async throws {
        let (_, coordinator, recorder) = try makeCoordinator()
        coordinator.handleCallEvent(.started(callerHint: "+420 602 000 111"))
        try await waitUntil { coordinator.isRecording }
        XCTAssertEqual(recorder.modes, [.callFocused(keeping: nil)])
        await coordinator.discardRecording()
    }
}
