import Foundation
import AVFoundation

/// A piece of a recording and where it lies in the whole, in seconds.
struct AudioChunk: Equatable {
    let url: URL
    let start: Double
    /// `.greatestFiniteMagnitude` when the file wasn't split.
    let end: Double
}

/// Splits an audio file into time slices for the Whisper API, which takes files up to about 25 MB.
/// The slices are M4A files next to the original; the caller removes them with `cleanup`.
enum AudioChunker {
    /// Files up to `maxFileBytes` come back whole; longer ones are cut into equal slices of at most `maxChunkSeconds`.
    static func split(
        url: URL,
        maxChunkSeconds: Double = 15 * 60,
        maxFileBytes: Int = 20 * 1024 * 1024
    ) async throws -> [AudioChunk] {
        let whole = [AudioChunk(url: url, start: 0, end: .greatestFiniteMagnitude)]
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if fileSize <= maxFileBytes { return whole }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return whole }

        let chunkCount = max(1, Int(ceil(duration / maxChunkSeconds)))
        let chunkLength = duration / Double(chunkCount)

        var chunks: [AudioChunk] = []
        for index in 0..<chunkCount {
            let start = Double(index) * chunkLength
            let end = min(duration, start + chunkLength)
            let chunk = try await exportTimeRange(of: asset, from: start, to: end, base: url, index: index)
            chunks.append(AudioChunk(url: chunk, start: start, end: end))
        }
        return chunks
    }

    private static func exportTimeRange(
        of asset: AVURLAsset,
        from start: Double,
        to end: Double,
        base: URL,
        index: Int
    ) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioChunker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export session failed"])
        }
        let out = base
            .deletingPathExtension()
            .appendingPathExtension("chunk\(index).m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let exportRef = export
            exportRef.exportAsynchronously {
                switch exportRef.status {
                case .completed: cont.resume()
                case .failed, .cancelled:
                    cont.resume(throwing: exportRef.error ?? NSError(domain: "AudioChunker", code: 2))
                default: cont.resume()
                }
            }
        }
        return out
    }

    static func cleanup(_ chunks: [AudioChunk], except keep: URL) {
        for chunk in chunks where chunk.url != keep {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
}
