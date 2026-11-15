import Foundation

/// What the transcriber needs from a speech-to-text service: DeepInfra's Whisper in the app, a fake in tests.
protocol SpeechTranscribing {
    /// Transcribes one audio file; segment times are seconds from the start of that file.
    func transcribeSegments(of url: URL, language: String?) async throws -> [WhisperSegment]
}

/// Transcribes a call and tells the speakers apart. Each side of the call is recorded on its own track,
/// so each is transcribed on its own and the two are merged by time — no guessing who spoke.
struct CallTranscriber {
    struct Tracks {
        /// Both sides together; used when the sides can't be told apart.
        var mixed: URL
        /// The microphone alone.
        var mine: URL?
        /// The call audio alone.
        var other: URL?
    }

    struct Output: Equatable {
        var text: String
        var segments: [TranscriptSegment]
    }

    let engine: SpeechTranscribing

    /// `progress` gets (part, parts) before each upload; it's only called when a side is long enough to be split.
    func transcribe(
        _ tracks: Tracks,
        language: String?,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Output {
        var sides: [Side] = []
        for (speaker, url) in [(Speaker.me, tracks.mine), (Speaker.other, tracks.other)] {
            guard let url, FileManager.default.fileExists(atPath: url.path),
                  let levels = try? await AudioLevels.envelope(of: url), !levels.isEmpty else { continue }
            sides.append(Side(speaker: speaker, url: url, levels: levels, threshold: TranscriptBuilder.speechThreshold(for: levels)))
        }

        // Without both sides there's nothing to tell apart: transcribe everything as one.
        guard sides.count == 2 else {
            let segments = try await run([Job(url: tracks.mixed, side: nil)], language: language, progress: progress)
            return output(TranscriptBuilder.single(segments[0]))
        }

        let speaking = sides.filter { $0.threshold != nil }
        switch speaking.count {
        case 0:
            // Silence on both sides — an empty transcript, which the pipeline reports.
            return Output(text: "", segments: [])
        case 1:
            // Only one side has sound (the other wasn't captured), so it may hold both voices.
            let side = speaking[0]
            let segments = try await run([Job(url: side.url, side: side)], language: language, progress: progress)
            return output(TranscriptBuilder.single(side.keepAudible(segments[0])))
        default:
            let segments = try await run(sides.map { Job(url: $0.url, side: $0) }, language: language, progress: progress)
            let other = sides[1].keepAudible(segments[1])
            let mine = TranscriptBuilder.removeEcho(from: sides[0].keepAudible(segments[0]), other: other)
            return output(TranscriptBuilder.merge(mine: mine, other: other))
        }
    }

    // MARK: - Private

    private struct Side {
        let speaker: Speaker
        let url: URL
        let levels: [Float]
        /// nil: nobody talks on this side.
        let threshold: Float?

        func keepAudible(_ segments: [WhisperSegment]) -> [WhisperSegment] {
            guard let threshold else { return [] }
            return TranscriptBuilder.keepAudible(segments, envelope: levels, threshold: threshold)
        }

        func hasSpeech(in chunk: AudioChunk) -> Bool {
            guard let threshold else { return false }
            return TranscriptBuilder.hasSpeech(levels, threshold: threshold, from: chunk.start, to: chunk.end, minFrames: 1)
        }
    }

    private struct Job {
        let url: URL
        let side: Side?
    }

    /// Splits every file, skips silent pieces, uploads the rest and returns each file's segments in recording time.
    private func run(_ jobs: [Job], language: String?, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [[WhisperSegment]] {
        var plans: [[AudioChunk]] = []
        var allChunks: [(chunks: [AudioChunk], keep: URL)] = []
        defer { for entry in allChunks { AudioChunker.cleanup(entry.chunks, except: entry.keep) } }

        for job in jobs {
            let chunks = try await AudioChunker.split(url: job.url)
            allChunks.append((chunks, job.url))
            plans.append(chunks.filter { job.side?.hasSpeech(in: $0) ?? true })
        }

        let total = plans.reduce(0) { $0 + $1.count }
        let reportsProgress = total > jobs.count
        var done = 0
        var results: [[WhisperSegment]] = []
        for chunks in plans {
            var segments: [WhisperSegment] = []
            for chunk in chunks {
                // A call deleted while uploading sends no further parts.
                try Task.checkCancellation()
                done += 1
                if reportsProgress { progress(done, total) }
                let part = try await engine.transcribeSegments(of: chunk.url, language: language)
                segments += part.map { WhisperSegment(start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text) }
            }
            results.append(segments)
        }
        return results
    }

    private func output(_ segments: [TranscriptSegment]) -> Output {
        Output(text: TranscriptBuilder.plainText(segments), segments: segments)
    }
}
