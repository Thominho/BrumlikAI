import Foundation
import AVFoundation
import Accelerate

/// Records the microphone — your side of the call — as mono.
final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var monoFormat: AVAudioFormat?
    private var peak: Float = 0
    private var running = false

    func start(writingTo url: URL?) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
        else { throw RecorderError.micUnavailable }
        monoFormat = mono

        if let url {
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: SystemAudioTap.fileSettings(for: mono),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw RecorderError.fileCreation(error.localizedDescription)
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.micUnavailable
        }
        running = true
    }

    /// Stops recording and returns the loudest sample seen (0…1).
    func stop() -> Float {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return peak
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride

        lock.lock()
        defer { lock.unlock() }

        var bufferPeak: Float = 0
        vDSP_maxmgv(channels[0], vDSP_Stride(stride), &bufferPeak, vDSP_Length(frames))
        peak = max(peak, bufferPeak)

        guard let file, let monoFormat else { return }
        if buffer.format.channelCount == 1 && !buffer.format.isInterleaved {
            try? file.write(from: buffer)
            return
        }
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let target = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        for frame in 0..<frames {
            target[frame] = channels[0][frame * stride]
        }
        try? file.write(from: mono)
    }
}
