import Foundation
import AVFoundation
import Accelerate

/// Speech-sized copies of a call side and their loudness over time, for telling the speakers apart.
enum AudioLevels {
    /// Whisper works at 16 kHz, so nothing above that helps the transcript.
    static let sampleRate: Double = 16_000

    /// A small mono 16 kHz AAC copy of a recorded part, for uploading one side of the call on its own.
    static func exportSpeech(from input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MixError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(float: false))
        source.alwaysCopiesSampleData = false
        guard reader.canAdd(source) else { throw MixError.failed("AVAssetReader") }
        reader.add(source)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let target = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ])
        target.expectsMediaDataInRealTime = false
        guard writer.canAdd(target) else { throw MixError.failed("AVAssetWriter") }
        writer.add(target)

        guard reader.startReading() else { throw reader.error ?? MixError.failed("AVAssetReader") }
        guard writer.startWriting() else { throw writer.error ?? MixError.failed("AVAssetWriter") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "cz.brumlik.BrumlikAI.speech-export")
        let pump = Pump(reader: reader, source: source, target: target)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pump.run(on: queue) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MixError.failed("AVAssetWriter status \(writer.status.rawValue)")
        }
    }

    /// Loudness (RMS, 0…1) of every `TranscriptBuilder.frameSeconds` slice of an audio file.
    static func envelope(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(float: true))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MixError.failed("AVAssetReader") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MixError.failed("AVAssetReader") }

        let frameLength = Int(sampleRate * TranscriptBuilder.frameSeconds)
        var levels: [Float] = []
        var pending: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            pending.append(contentsOf: samples)
            var offset = 0
            pending.withUnsafeBufferPointer { pointer in
                while pointer.count - offset >= frameLength {
                    var meanSquare: Float = 0
                    vDSP_measqv(pointer.baseAddress! + offset, 1, &meanSquare, vDSP_Length(frameLength))
                    levels.append(meanSquare.squareRoot())
                    offset += frameLength
                }
            }
            pending.removeFirst(offset)
        }
        if pending.count >= frameLength / 2 {
            var meanSquare: Float = 0
            vDSP_measqv(pending, 1, &meanSquare, vDSP_Length(pending.count))
            levels.append(meanSquare.squareRoot())
        }
        if reader.status == .failed { throw reader.error ?? MixError.failed("AVAssetReader") }
        return levels
    }

    private static func pcmSettings(float: Bool) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: float ? 32 : 16,
            AVLinearPCMIsFloatKey: float,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }
}

/// Feeds decoded audio into the encoder as fast as it takes it; reports once when done.
private final class Pump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let source: AVAssetReaderTrackOutput
    private let target: AVAssetWriterInput
    private var finished = false

    init(reader: AVAssetReader, source: AVAssetReaderTrackOutput, target: AVAssetWriterInput) {
        self.reader = reader
        self.source = source
        self.target = target
    }

    /// `done` runs once, on `queue`.
    func run(on queue: DispatchQueue, done: @escaping @Sendable (Error?) -> Void) {
        target.requestMediaDataWhenReady(on: queue) { [self] in
            guard !finished else { return }
            while target.isReadyForMoreMediaData {
                guard let buffer = source.copyNextSampleBuffer() else {
                    finish(reader.status == .failed ? (reader.error ?? MixError.failed("AVAssetReader")) : nil, done)
                    return
                }
                if !target.append(buffer) {
                    finish(MixError.failed("AVAssetWriterInput"), done)
                    return
                }
            }
        }
    }

    private func finish(_ error: Error?, _ done: @Sendable (Error?) -> Void) {
        finished = true
        target.markAsFinished()
        if error != nil { reader.cancelReading() }
        done(error)
    }
}
