import AVFoundation
import Foundation
@testable import BrumlikAI

/// Writes real audio files for tests: a 440 Hz tone in the "loud" ranges, a faint hum elsewhere.
enum TestAudio {
    static func write(
        to url: URL,
        duration: Double,
        loud ranges: [ClosedRange<Double>],
        channels: AVAudioChannelCount = 1,
        sampleRate: Double = 48_000
    ) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: SystemAudioTap.fileSettings(for: format),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                let time = Double(index) / sampleRate
                let loud = ranges.contains { $0.contains(time) }
                samples[index] = loud
                    ? Float(0.3 * sin(2 * .pi * 440 * time))
                    : Float(0.0005 * sin(2 * .pi * 97 * time))
            }
        }
        try file.write(from: buffer)
    }
}

/// Speech-to-text stand-in: returns fixed segments for each file, picked by a part of its name.
final class FakeSpeech: SpeechTranscribing, @unchecked Sendable {
    var segmentsByName: [String: [WhisperSegment]] = [:]
    private(set) var transcribedFiles: [String] = []

    func transcribeSegments(of url: URL, language: String?) async throws -> [WhisperSegment] {
        transcribedFiles.append(url.lastPathComponent)
        return segmentsByName.first { url.lastPathComponent.contains($0.key) }?.value ?? []
    }
}

/// Contacts that know nobody, so tests never reach the real address book.
@MainActor
final class NoContacts: CallerDirectory {
    func name(for phoneNumber: String) async -> String? { nil }
    func numbers(forName name: String) async -> [String] { [] }
}

/// Records nothing and writes no files.
@MainActor
final class SilentRecorder: CallAudioRecorder {
    func requestAccessIfNeeded() async {}
    func start(recordingId id: UUID, mode: SystemTapMode) throws {}
    func stop() throws -> AudioRecorder.Result { AudioRecorder.Result(systemPeak: nil, micPeak: nil, warnings: []) }
}

/// Writes real audio for both sides: you talk at 0.5–2 s, the client at 2.5–4.5 s.
@MainActor
final class AudioWritingRecorder: CallAudioRecorder {
    func requestAccessIfNeeded() async {}

    func start(recordingId id: UUID, mode: SystemTapMode) throws {
        try TestAudio.write(to: RecordingStore.micPartURL(for: id), duration: 6, loud: [0.5...2.0])
        try TestAudio.write(to: RecordingStore.systemPartURL(for: id), duration: 6, loud: [2.5...4.5], channels: 2)
    }

    func stop() throws -> AudioRecorder.Result { AudioRecorder.Result(systemPeak: nil, micPeak: nil, warnings: []) }
}

/// A temporary data folder for one test; nothing touches the user's recordings.
final class TemporaryStore {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("brumlik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RecordingStore.directoryOverride = directory
    }

    func remove() {
        RecordingStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
