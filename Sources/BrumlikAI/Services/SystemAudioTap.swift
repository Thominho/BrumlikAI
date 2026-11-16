import Foundation
import AppKit
import AVFoundation
import CoreAudio
import Accelerate

enum SystemTapMode: Equatable {
    /// Everything the Mac plays except BrumlikAI itself (manual recordings).
    case allExceptSelf
    /// Like `allExceptSelf`, but also leaves out apps that are only playing audio when the call starts (music, videos).
    /// `keeping` is the app a Meet or WhatsApp call runs in (a bundle ID prefix): none of its processes is left out,
    /// because Chrome may play the call in a different helper process than the one that captures the microphone.
    case callFocused(keeping: String? = nil)
    /// Everything including BrumlikAI — the permission test plays its own sound.
    case all
}

/// Records what the Mac plays — the other side of a call — through a Core Audio process tap (macOS 14.2+).
final class SystemAudioTap: @unchecked Sendable {
    static let silenceThreshold: Float = 0.00001

    private let queue = DispatchQueue(label: "cz.brumlik.BrumlikAI.system-audio", qos: .userInitiated)
    private var tapID = CoreAudioUtils.unknownObject
    private var aggregateID = CoreAudioUtils.unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    // Set up before the IO proc starts; afterwards only touched on `queue`.
    private var format: AVAudioFormat?
    private var file: AVAudioFile?
    private var peak: Float = 0

    func start(mode: SystemTapMode, writingTo url: URL?) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses(for: mode))
        description.uuid = UUID()
        description.name = "BrumlikAI"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw RecorderError.systemAudio(status) }

        var streamDescription: AudioStreamBasicDescription = CoreAudioUtils.read(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()
        )
        guard streamDescription.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            cleanUp()
            throw RecorderError.systemAudio(kAudioHardwareUnspecifiedError)
        }
        self.format = format

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BrumlikAI Tap",
            kAudioAggregateDeviceUIDKey: "cz.brumlik.BrumlikAI.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        if let clockUID = CoreAudioUtils.clockDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            cleanUp()
            throw RecorderError.systemAudio(status)
        }

        if let url {
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: Self.fileSettings(for: format),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: format.isInterleaved
                )
            } catch {
                cleanUp()
                throw RecorderError.fileCreation(error.localizedDescription)
            }
        }

        let bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        let bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input, bufferCount: bufferCount, bytesPerFrame: bytesPerFrame)
        }
        guard status == noErr else {
            cleanUp()
            throw RecorderError.systemAudio(status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanUp()
            throw RecorderError.systemAudio(status)
        }
    }

    /// Stops capturing and returns the loudest sample seen (0…1).
    func stop() -> Float {
        if let ioProcID, aggregateID != CoreAudioUtils.unknownObject {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        let result = queue.sync { () -> Float in
            file = nil
            return peak
        }
        cleanUp()
        return result
    }

    /// Plays a short sound and checks that the tap hears it — the only reliable way to find out
    /// whether macOS lets BrumlikAI record system audio.
    @MainActor
    static func verifyCapture() async -> Bool {
        let tap = SystemAudioTap()
        do {
            try tap.start(mode: .all, writingTo: nil)
        } catch {
            return false
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSSound(named: "Glass")?.play()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return tap.stop() > silenceThreshold
    }

    static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>, bufferCount: Int, bytesPerFrame: Int) {
        guard bytesPerFrame > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count >= bufferCount else { return }
        // The tap's streams come after any streams of the clock device.
        let sources = Array(buffers.suffix(bufferCount))

        for buffer in sources {
            guard let data = buffer.mData else { continue }
            var bufferPeak: Float = 0
            let samples = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, samples)
            peak = max(peak, bufferPeak)
        }

        guard let file, let format else { return }
        let frames = Int(sources[0].mDataByteSize) / bytesPerFrame
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let targets = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (index, source) in sources.enumerated() where index < targets.count {
            guard let from = source.mData, let to = targets[index].mData else { continue }
            memcpy(to, from, min(Int(source.mDataByteSize), Int(targets[index].mDataByteSize)))
        }
        try? file.write(from: pcm)
    }

    private func excludedProcesses(for mode: SystemTapMode) -> [AudioObjectID] {
        guard mode != .all else { return [] }
        var excluded: [AudioObjectID] = []
        if let own = CoreAudioProcesses.objectID(for: ProcessInfo.processInfo.processIdentifier) {
            excluded.append(own)
        }
        if case .callFocused(let callApp) = mode {
            excluded += CoreAudioProcesses.list()
                .filter { !$0.isCurrentProcess && $0.isRunningOutput && !$0.isRunningInput && !$0.isCallProcess }
                .filter { process in callApp.map { !process.bundleID.hasPrefix($0) } ?? true }
                .map(\.objectID)
        }
        return excluded
    }

    private func cleanUp() {
        if aggregateID != CoreAudioUtils.unknownObject {
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = CoreAudioUtils.unknownObject
        if tapID != CoreAudioUtils.unknownObject { AudioHardwareDestroyProcessTap(tapID) }
        tapID = CoreAudioUtils.unknownObject
    }
}
