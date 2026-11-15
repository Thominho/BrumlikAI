import Foundation

/// Who said a stretch of the call.
enum Speaker: String, Codable, Equatable {
    /// The app's user — recorded from the microphone.
    case me
    /// The other party — recorded from the call audio.
    case other
    /// Transcribed from one track, so the speaker isn't known (older calls, or only one side had sound).
    case unknown
}

/// A stretch of speech and where it is in the recording (seconds from the start).
struct TranscriptSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var speaker: Speaker
    var text: String
}

/// What Whisper returns for a piece of audio; times are seconds from the start of that piece.
struct WhisperSegment: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// Consecutive segments of one speaker, shown and copied as one block.
struct TranscriptTurn: Equatable, Identifiable {
    /// Index of the turn's first segment.
    var id: Int { indices.lowerBound }
    let speaker: Speaker
    let indices: Range<Int>
}

/// Builds the call transcript from the two sides, which are recorded and transcribed separately.
enum TranscriptBuilder {
    /// Length of one loudness frame, in seconds.
    static let frameSeconds: Double = 0.1
    /// A track whose speech never gets louder than this (about −50 dBFS) has nobody talking on it.
    static let silentTrackLevel: Float = 0.003

    // MARK: Loudness

    /// The loudness from which a frame counts as speech on this track, or nil when nobody talks on it at all.
    static func speechThreshold(for envelope: [Float]) -> Float? {
        guard !envelope.isEmpty else { return nil }
        let sorted = envelope.sorted()
        func percentile(_ fraction: Double) -> Float {
            sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let speech = percentile(0.95)
        guard speech >= silentTrackLevel else { return nil }
        // About 10 dB over the noise floor, but never more than 20 dB under the speech.
        return max(percentile(0.2) * 3, speech * 0.1)
    }

    /// Whether the track has at least `minFrames` loud frames between `start` and `end`.
    static func hasSpeech(_ envelope: [Float], threshold: Float, from start: Double, to end: Double, minFrames: Int = 3) -> Bool {
        guard !envelope.isEmpty, end > start else { return false }
        let first = max(0, (start / frameSeconds).rounded(.down))
        let last = min(Double(envelope.count - 1), (end / frameSeconds).rounded(.up))
        guard first <= last else { return false }
        var loud = 0
        for index in Int(first)...Int(last) where envelope[index] >= threshold {
            loud += 1
            if loud >= minFrames { return true }
        }
        return false
    }

    /// Drops what Whisper wrote over silence on this track — it tends to invent text there.
    static func keepAudible(_ segments: [WhisperSegment], envelope: [Float], threshold: Float) -> [WhisperSegment] {
        segments.filter { hasSpeech(envelope, threshold: threshold, from: $0.start - 0.3, to: $0.end + 0.3) }
    }

    // MARK: Text

    /// Phrases Whisper is known to invent over silence (subtitle credits and the like), without diacritics.
    private static let phantomPhrases = [
        "titulky vytvoril", "titulky pripravil", "amara org", "dekuji za sledovani",
        "thanks for watching", "thank you for watching", "subtitles by"
    ]

    static func isPhantom(_ text: String) -> Bool {
        let normalized = normalizedWords(text).joined(separator: " ")
        return phantomPhrases.contains { normalized.contains($0) }
    }

    /// Lower-case words without diacritics or punctuation, for comparing texts.
    static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Drops microphone segments that are only the other side's voice coming back from the speakers:
    /// said at the same moment and with mostly the same words. With headphones there's nothing to drop.
    /// A reply right after the client that repeats some of their words stays — echo is simultaneous.
    static func removeEcho(from mine: [WhisperSegment], other: [WhisperSegment]) -> [WhisperSegment] {
        guard !other.isEmpty else { return mine }
        let tolerance = 0.3
        return mine.filter { segment in
            let words = contentWords(segment.text)
            guard !words.isEmpty else { return false }
            let overlapping = other.filter { $0.start - tolerance < segment.end && $0.end + tolerance > segment.start }
            let covered = overlapping.reduce(0.0) { total, heard in
                total + max(0, min(heard.end + tolerance, segment.end) - max(heard.start - tolerance, segment.start))
            }
            // Most of the segment has to fall where the other side was speaking.
            guard covered >= max(segment.end - segment.start, 0.1) * 0.5 else { return true }

            let heard = Set(overlapping.flatMap { normalizedWords($0.text) })
            let ratio = Double(words.filter(heard.contains).count) / Double(words.count)
            if words.count >= 3 { return ratio < 0.6 }
            // A short reply ("ano", "jasně") is echo only when the other side said it at that very moment.
            let inside = overlapping.contains { $0.start - tolerance <= segment.start && segment.end <= $0.end + tolerance }
            return !(inside && ratio == 1)
        }
    }

    /// The words that carry meaning — "do", "to", "a" are left out when there are enough others.
    static func contentWords(_ text: String) -> [String] {
        let words = normalizedWords(text)
        let long = words.filter { $0.count >= 3 }
        return long.count >= 2 ? long : words
    }

    // MARK: Assembling

    /// Both sides in time order. Echo, empty text and text invented over silence must be removed beforehand.
    static func merge(mine: [WhisperSegment], other: [WhisperSegment]) -> [TranscriptSegment] {
        let all = segments(mine, speaker: .me) + segments(other, speaker: .other)
        return all.sorted { $0.start < $1.start || ($0.start == $1.start && $0.speaker == .other) }
    }

    /// Segments of one track whose speaker isn't known.
    static func single(_ segments: [WhisperSegment]) -> [TranscriptSegment] {
        self.segments(segments, speaker: .unknown).sorted { $0.start < $1.start }
    }

    private static func segments(_ raw: [WhisperSegment], speaker: Speaker) -> [TranscriptSegment] {
        raw.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isPhantom(text) else { return nil }
            return TranscriptSegment(start: max(0, segment.start), end: max(segment.start, segment.end), speaker: speaker, text: text)
        }
    }

    /// The transcript as one plain text, for search and for older views.
    static func plainText(_ segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Groups consecutive segments of one speaker. A long stretch is split so every block stays easy to find.
    static func turns(_ segments: [TranscriptSegment], maxGap: Double = 8, maxLength: Double = 120) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var start = 0
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1]
            let current = segments[index]
            let sameBlock = current.speaker == previous.speaker
                && current.start - previous.end < maxGap
                && current.end - segments[start].start <= maxLength
            if !sameBlock {
                turns.append(TranscriptTurn(speaker: segments[start].speaker, indices: start..<index))
                start = index
            }
        }
        if !segments.isEmpty {
            turns.append(TranscriptTurn(speaker: segments[start].speaker, indices: start..<segments.count))
        }
        return turns
    }

    /// One line per turn: "label: text", optionally with the time. Turns without a label come out as plain lines.
    static func labelledText(_ segments: [TranscriptSegment], withTimes: Bool = false, label: (Speaker) -> String?) -> String {
        turns(segments).map { turn in
            let text = segments[turn.indices].map(\.text).joined(separator: " ")
            var line = ""
            if withTimes { line += "[\(clock(segments[turn.indices.lowerBound].start))] " }
            if let name = label(turn.speaker) { line += "\(name): " }
            return line + text
        }
        .joined(separator: "\n")
    }

    /// "1:05", or "1:02:05" for long calls.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Recording {
    /// Whether the transcript knows who said what.
    var hasSpeakers: Bool {
        segments?.contains { $0.speaker != .unknown } == true
    }

    /// The transcript as the LLM reads it: "USER:" and "CLIENT:" lines when the speakers are known.
    var transcriptForAI: String? {
        if let segments, hasSpeakers {
            return TranscriptBuilder.labelledText(segments) { speaker in
                switch speaker {
                case .me: return "USER"
                case .other: return "CLIENT"
                case .unknown: return nil
                }
            }
        }
        return transcript
    }
}
