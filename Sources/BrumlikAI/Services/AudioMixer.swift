import Foundation
import AVFoundation

enum MixError: LocalizedError {
    case noAudio
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return L10n.t(.errNoAudio)
        case .failed(let message): return L10n.f(.errMixFailed, message)
        }
    }
}

enum AudioMixer {
    /// Mixes the recorded parts (system audio and microphone) into one M4A file. Empty parts are skipped.
    static func mix(_ parts: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        var addedTracks = 0

        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  duration.seconds > 0.1,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            addedTracks += 1
        }
        guard addedTracks > 0 else { throw MixError.noAudio }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.failed("AVAssetExportSession")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let session = export
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    let reason = session.error?.localizedDescription ?? "status \(session.status.rawValue)"
                    continuation.resume(throwing: MixError.failed(reason))
                }
            }
        }
    }
}
