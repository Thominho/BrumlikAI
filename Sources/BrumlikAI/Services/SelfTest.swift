import Foundation
import AVFoundation

/// Diagnostics: the short test recording in Settings, and the `--self-test <seconds> [--process] [--report <path>]`
/// launch mode that records, optionally runs the whole pipeline, writes a JSON report and quits.
@MainActor
enum SelfTest {
    struct AudioCheck {
        let systemPeak: Float?
        let micPeak: Float?
        let warnings: [String]
    }

    static func audioCheck(seconds: Double) async -> AudioCheck {
        let id = UUID()
        let recorder = AudioRecorder()
        do {
            try recorder.start(recordingId: id, mode: .allExceptSelf)
        } catch {
            return AudioCheck(systemPeak: nil, micPeak: nil, warnings: [error.localizedDescription])
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let result = try? recorder.stop()
        RecordingStore.removeFiles(for: id)
        if let peak = result?.systemPeak, peak > SystemAudioTap.silenceThreshold {
            SetupChecklist.shared.markSystemAudioWorking()
        }
        return AudioCheck(systemPeak: result?.systemPeak, micPeak: result?.micPeak, warnings: result?.warnings ?? [])
    }

    struct Options {
        let seconds: Double
        let process: Bool
        let reportURL: URL

        init?(arguments: [String]) {
            guard let index = arguments.firstIndex(of: "--self-test") else { return nil }
            seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 5 : 5
            process = arguments.contains("--process")
            if let reportIndex = arguments.firstIndex(of: "--report"), arguments.indices.contains(reportIndex + 1) {
                reportURL = URL(fileURLWithPath: arguments[reportIndex + 1])
            } else {
                reportURL = RecordingStore.storageDirectory.appendingPathComponent("selftest.json")
            }
        }
    }

    struct Report: Encodable {
        var finishedAt = Date()
        var seconds: Double
        var appLanguage: String
        var callLanguage: String
        var inputDevice = CoreAudioUtils.defaultInputDeviceName()
        var micAccess = SelfTest.describe(AVCaptureDevice.authorizationStatus(for: .audio))
        var error: String?
        var systemPeak: Float?
        var micPeak: Float?
        var warnings: [String] = []
        var audioProcesses: [ProcessRow] = []
        var callDetected = false
        var mixedFileBytes: Int?
        var status: String?
        var processingError: String?
        var transcript: String?
        var summary: CallSummary?
    }

    struct ProcessRow: Encodable {
        let name: String
        let bundleID: String
        let input: Bool
        let output: Bool
        let isCall: Bool
    }

    static func run(_ options: Options, coordinator: RecordingCoordinator, appState: AppState) async {
        var report = Report(seconds: options.seconds, appLanguage: AppLanguage.current.rawValue, callLanguage: appState.callLanguage)
        coordinator.notificationsEnabled = false

        await coordinator.startRecording(callerHint: nil, auto: false)
        guard let id = coordinator.activeRecordingId else {
            report.error = appState.lastError ?? "Recording did not start"
            write(report, to: options.reportURL)
            return
        }

        let half = UInt64(options.seconds / 2 * 1_000_000_000)
        try? await Task.sleep(nanoseconds: half)
        report.audioProcesses = CoreAudioProcesses.list().map {
            ProcessRow(name: $0.displayName, bundleID: $0.bundleID, input: $0.isRunningInput, output: $0.isRunningOutput, isCall: $0.isCallProcess)
        }
        report.callDetected = !CoreAudioProcesses.activeCallProcesses().isEmpty
        try? await Task.sleep(nanoseconds: half)

        await coordinator.stopRecording(process: false)
        report.systemPeak = coordinator.lastCapture?.systemPeak
        report.micPeak = coordinator.lastCapture?.micPeak
        report.warnings = coordinator.lastCapture?.warnings ?? []

        if options.process {
            await coordinator.process(recordingId: id)
        } else {
            do {
                _ = try await coordinator.prepareAudio(for: id)
            } catch {
                report.processingError = error.localizedDescription
            }
        }

        let mixed = RecordingStore.mixedURL(for: id)
        report.mixedFileBytes = (try? FileManager.default.attributesOfItem(atPath: mixed.path))?[.size] as? Int
        if let recording = appState.recording(id) {
            report.status = recording.status.rawValue
            report.processingError = report.processingError ?? recording.errorMessage
            report.transcript = recording.transcript
            report.summary = recording.summary
            appState.deleteRecording(recording)
        }
        write(report, to: options.reportURL)
    }

    nonisolated static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func write(_ report: Report, to url: URL) {
        if let data = try? JSONEncoder.brumlik.encode(report) {
            try? data.write(to: url)
        }
    }
}
