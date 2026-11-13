import Foundation
import AVFoundation

/// Rozdělí audio soubor na časové úseky pro Whisper API, který má limit okolo 25 MB.
/// Vrací URLs m4a souborů ve scratch adresáři a je odpovědnost volajícího je smazat.
enum AudioChunker {
    /// Rozdělí nahrávku na úseky dané maximální délkou (v sekundách).
    /// Pokud je soubor kratší než threshold, vrátí [original].
    static func split(
        url: URL,
        maxChunkSeconds: Double = 15 * 60,
        maxFileBytes: Int = 20 * 1024 * 1024
    ) async throws -> [URL] {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if fileSize <= maxFileBytes { return [url] }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [url] }

        let chunkCount = max(1, Int(ceil(duration / maxChunkSeconds)))
        let chunkLen = duration / Double(chunkCount)

        var outputs: [URL] = []
        for i in 0..<chunkCount {
            let start = Double(i) * chunkLen
            let end = min(duration, start + chunkLen)
            let chunk = try await exportTimeRange(
                of: asset,
                from: start,
                to: end,
                base: url,
                index: i
            )
            outputs.append(chunk)
        }
        return outputs
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

    static func cleanup(_ urls: [URL], except keep: URL) {
        for u in urls where u != keep {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
