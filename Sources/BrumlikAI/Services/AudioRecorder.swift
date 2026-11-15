import Foundation
import CoreAudio
import AVFoundation

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case micUnavailable
    case systemAudio(OSStatus)
    case fileCreation(String)
    case nothingToRecord(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return L10n.t(.errAlreadyRecording)
        case .notRecording: return L10n.t(.errNotRecording)
        case .micUnavailable: return L10n.t(.errMicUnavailable)
        case .systemAudio(let status): return L10n.f(.errSystemAudioFailed, status)
        case .fileCreation(let message): return L10n.f(.errFileCreation, message)
        case .nothingToRecord(let message): return L10n.f(.errNothingToRecord, message)
        }
    }
}

/// Records both sides of a call into two part files: the microphone and the system audio.
/// What the coordinator needs from a recorder; tests use a fake that touches no audio hardware.
@MainActor
protocol CallAudioRecorder: AnyObject {
    func requestAccessIfNeeded() async
    func start(recordingId id: UUID, mode: SystemTapMode) throws
    func stop() throws -> AudioRecorder.Result
}

/// If one source fails, the other keeps recording and the failure becomes a warning on the recording.
@MainActor
final class AudioRecorder: CallAudioRecorder {
    /// Until access is decided, macOS hands the app only silence, so ask before the recording starts.
    func requestAccessIfNeeded() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    struct Result {
        let systemPeak: Float?
        let micPeak: Float?
        let warnings: [String]
    }

    private var tap: SystemAudioTap?
    private var mic: MicRecorder?
    private var startWarnings: [String] = []
    private(set) var isRecording = false

    func start(recordingId id: UUID, mode: SystemTapMode) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        var warnings: [String] = []

        let mic = MicRecorder()
        do {
            try mic.start(writingTo: RecordingStore.micPartURL(for: id))
            self.mic = mic
        } catch {
            warnings.append(error.localizedDescription)
        }

        let tap = SystemAudioTap()
        do {
            try tap.start(mode: mode, writingTo: RecordingStore.systemPartURL(for: id))
            self.tap = tap
        } catch {
            warnings.append(error.localizedDescription)
        }

        guard self.mic != nil || self.tap != nil else {
            RecordingStore.removeFiles(for: id)
            throw RecorderError.nothingToRecord(warnings.joined(separator: " "))
        }
        startWarnings = warnings
        isRecording = true
    }

    func stop() throws -> Result {
        guard isRecording else { throw RecorderError.notRecording }
        isRecording = false

        let systemPeak = tap?.stop()
        let micPeak = mic?.stop()
        var warnings = startWarnings
        if let systemPeak, systemPeak <= SystemAudioTap.silenceThreshold {
            warnings.append(L10n.t(.warnCallerSilent))
        }
        if let micPeak, micPeak <= SystemAudioTap.silenceThreshold {
            warnings.append(L10n.f(.warnMicSilent, CoreAudioUtils.defaultInputDeviceName() ?? "—"))
        }

        tap = nil
        mic = nil
        startWarnings = []
        return Result(systemPeak: systemPeak, micPeak: micPeak, warnings: warnings)
    }
}
