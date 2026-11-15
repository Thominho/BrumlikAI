import AppKit
import AVFoundation
import SwiftUI

/// Diagnostics only (`--preview-call-detail <dir>`): opens a made-up call in the detail window, saves screenshots
/// of its top and bottom, and quits. It runs on a temporary data folder, so the user's calls are never touched.
@MainActor
enum CallDetailPreview {
    static func run(to directory: URL, loc: LocalizationManager) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("brumlik-preview-\(UUID().uuidString)")
        RecordingStore.directoryOverride = store
        defer {
            RecordingStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: store)
        }

        let appState = AppState()
        let coordinator = RecordingCoordinator(appState: appState, deepInfraToken: { nil })
        coordinator.notificationsEnabled = false
        let recording = demoRecording(czech: loc.language == .czech)
        appState.appendRecording(recording)

        let root = RecordingDetailView(recordingId: recording.id)
            .environmentObject(appState)
            .environmentObject(coordinator)
            .environmentObject(loc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 980),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.orderFrontRegardless()

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshot(window, to: directory.appendingPathComponent("detail-top.png"))
        if let scroll = scrollView(in: window.contentView), let document = scroll.documentView {
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        snapshot(window, to: directory.appendingPathComponent("detail-bottom.png"))
        window.orderOut(nil)
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    private static func demoRecording(czech: Bool) -> Recording {
        let id = UUID()
        let audio = RecordingStore.recordingsDirectory.appendingPathComponent("\(id.uuidString).caf")
        let lines: [(Double, Double, Speaker, String)] = czech ? [
            (0.4, 2.6, .me, "Dobrý den, tady Tomáš z ON OFF Studia."),
            (3.0, 7.8, .other, "Dobrý den, volám kvůli tomu novému e-shopu, o kterém jsme se bavili."),
            (8.1, 11.5, .other, "Potřebovali bychom ho spustit ještě před Vánoci."),
            (12.0, 16.4, .me, "To stihneme. Pošlu vám cenovou nabídku do pátku."),
            (16.9, 20.2, .other, "Výborně. A doménu už máme, novak-shop.cz."),
            (20.6, 24.9, .me, "Dobře, ověřím, že je volná i varianta s pomlčkou."),
            (25.4, 29.8, .other, "Můžeme se potkat ve středu ve dvě?"),
            (30.2, 32.0, .me, "Ano, středa ve dvě platí.")
        ] : [
            (0.4, 2.6, .me, "Hello, this is Tom from ON OFF Studio."),
            (3.0, 7.8, .other, "Hi, I'm calling about the new online shop we talked about."),
            (8.1, 11.5, .other, "We'd need it live before Christmas."),
            (12.0, 16.4, .me, "That works. I'll send you a quote by Friday."),
            (16.9, 20.2, .other, "Great. We already have the domain, novak-shop.cz."),
            (20.6, 24.9, .me, "Good, I'll check the hyphenated one is free too."),
            (25.4, 29.8, .other, "Can we meet on Wednesday at two?"),
            (30.2, 32.0, .me, "Yes, Wednesday at two works.")
        ]
        writeTone(to: audio, duration: 33, loud: lines.map { $0.0...$0.1 })
        let segments = lines.map { TranscriptSegment(start: $0.0, end: $0.1, speaker: $0.2, text: $0.3) }
        let meeting = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 14, weekday: 4), matchingPolicy: .nextTime)
        let start = Date().addingTimeInterval(-2 * 3600)
        return Recording(
            id: id,
            startedAt: start,
            endedAt: start.addingTimeInterval(33),
            audioURL: audio,
            transcript: TranscriptBuilder.plainText(segments),
            summary: CallSummary(
                headline: czech ? "E-shop před Vánoci; nabídka do pátku, schůzka ve středu." : "Shop before Christmas; quote by Friday, meeting Wednesday.",
                humanSummary: czech
                    ? "Klient chce spustit nový e-shop ještě před Vánoci. Doménu novak-shop.cz už má. Slíbil jsi poslat cenovou nabídku do pátku a ověřit variantu domény s pomlčkou. Domluvili jste schůzku ve středu ve 14:00."
                    : "The client wants the new shop live before Christmas. They already own novak-shop.cz. You promised a quote by Friday and to check the hyphenated domain. You agreed to meet on Wednesday at 2 PM.",
                aiPrompt: "",
                requests: czech ? ["Spustit e-shop před Vánoci"] : ["Launch the shop before Christmas"],
                meeting: meeting.map {
                    MeetingProposal(title: czech ? "Schůzka – e-shop" : "Meeting – shop", startISO: ISO8601DateFormatter.brumlik.string(from: $0), durationMinutes: 60, location: nil, notes: nil)
                },
                tasks: czech
                    ? [TaskProposal(title: "Poslat cenovou nabídku"), TaskProposal(title: "Ověřit doménu s pomlčkou")]
                    : [TaskProposal(title: "Send the quote"), TaskProposal(title: "Check the hyphenated domain")]
            ),
            status: .completed,
            phoneNumber: "+420 777 123 456",
            contactName: "Jan Novák",
            segments: segments,
            emailDraft: EmailDraft(
                to: "jan.novak@example.com",
                subject: czech ? "Shrnutí našeho telefonátu – nový e-shop" : "Summary of our call – the new shop",
                body: czech
                    ? "Dobrý den, pane Nováku,\n\nděkuji za dnešní telefonát. Shrnuji, na čem jsme se domluvili:\n\n– e-shop spustíme ještě před Vánoci,\n– cenovou nabídku vám pošlu do pátku,\n– ověřím i variantu domény s pomlčkou.\n\nUvidíme se ve středu ve 14:00.\n\nS pozdravem"
                    : "Hello Mr Novák,\n\nthank you for today's call. Here's what we agreed:\n\n– the shop goes live before Christmas,\n– I'll send you the quote by Friday,\n– I'll check the hyphenated domain too.\n\nSee you on Wednesday at 2 PM.\n\nBest regards",
                createdAt: Date()
            )
        )
    }

    private static func writeTone(to url: URL, duration: Double, loud: [ClosedRange<Double>]) {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: SystemAudioTap.fileSettings(for: format), commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * sampleRate)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / sampleRate
            samples[index] = loud.contains { $0.contains(time) } ? Float(0.1 * sin(2 * .pi * 330 * time)) : 0
        }
        try? file.write(from: buffer)
    }
}
