import SwiftUI
import AVFoundation

/// Plays a call's recording; the transcript jumps around in it.
@MainActor
final class AudioPlayback: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isReady = false
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    static let rates: [Float] = [1, 1.25, 1.5, 2]

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    /// Loads a recording once it exists; calling again with the same file keeps the position.
    func load(_ url: URL) {
        guard url != loadedURL, FileManager.default.fileExists(atPath: url.path) else { return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        loadedURL = url
        player.enableRate = true
        player.rate = rate
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
        isReady = player.duration > 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        sync()
    }

    func play(from time: TimeInterval) {
        seek(to: time)
        play()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        isReady = false
        stopTimer()
        currentTime = 0
        duration = 0
    }

    private func sync() {
        guard let player else { return }
        currentTime = player.currentTime
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        // .common keeps it ticking while the window scrolls or the slider is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlayback: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = self.duration
        }
    }
}

/// Play/pause, ±15 s, a scrubber and the speed.
struct AudioPlayerBar: View {
    @ObservedObject var player: AudioPlayback
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.borderless)
                .help(loc.t(.playerBack))
                .accessibilityLabel(loc.t(.playerBack))

            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help(loc.t(player.isPlaying ? .playerPause : .playerPlay))
            .accessibilityLabel(loc.t(player.isPlaying ? .playerPause : .playerPlay))

            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.borderless)
                .help(loc.t(.playerForward))
                .accessibilityLabel(loc.t(.playerForward))

            Text(TranscriptBuilder.clock(player.currentTime))
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.small)

            Text(TranscriptBuilder.clock(player.duration))
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 38, alignment: .leading)

            Menu {
                ForEach(AudioPlayback.rates, id: \.self) { rate in
                    Button {
                        player.rate = rate
                    } label: {
                        if rate == player.rate {
                            Label(Self.rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(Self.rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(Self.rateLabel(player.rate))
                    .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(loc.t(.playerSpeed))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    static func rateLabel(_ rate: Float) -> String {
        let text = rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%.2g", rate)
        return text + "×"
    }
}

/// The transcript as turns of "who" and "what". Every sentence plays the recording from where it was said.
struct TranscriptTurnsView: View {
    let segments: [TranscriptSegment]
    let turns: [TranscriptTurn]
    let otherName: String
    let activeIndex: Int?
    let canPlay: Bool
    let onSelect: (TranscriptSegment) -> Void

    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(turns) { turn in
                TurnView(
                    label: label(for: turn.speaker),
                    tint: tint(for: turn.speaker),
                    start: segments[turn.indices.lowerBound].start,
                    segments: Array(segments[turn.indices]),
                    firstIndex: turn.indices.lowerBound,
                    activeIndex: activeIndex.flatMap { turn.indices.contains($0) ? $0 : nil },
                    canPlay: canPlay
                )
                .equatable()
                .environment(\.openURL, OpenURLAction { url in
                    guard let index = Int(url.host ?? ""), segments.indices.contains(index) else { return .discarded }
                    onSelect(segments[index])
                    return .handled
                })
            }
        }
    }

    private func label(for speaker: Speaker) -> String? {
        switch speaker {
        case .me: return loc.t(.transcriptMe)
        case .other: return otherName
        case .unknown: return nil
        }
    }

    private func tint(for speaker: Speaker) -> Color {
        speaker == .me ? .accentColor : .purple
    }

    /// The index of the segment being played at `time`, if any.
    static func activeIndex(in segments: [TranscriptSegment], at time: TimeInterval) -> Int? {
        guard let index = segments.lastIndex(where: { $0.start <= time + 0.05 }) else { return nil }
        let segment = segments[index]
        let next = segments.indices.contains(index + 1) ? segments[index + 1].start : .greatestFiniteMagnitude
        return time <= max(segment.end, min(next, segment.start + 30)) ? index : nil
    }
}

/// One block of the transcript. Equatable, so playback ticks redraw only the block being played.
private struct TurnView: View, Equatable {
    let label: String?
    let tint: Color
    let start: Double
    let segments: [TranscriptSegment]
    let firstIndex: Int
    let activeIndex: Int?
    let canPlay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let label {
                    Text(label)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundColor(tint)
                }
                Text(TranscriptBuilder.clock(start))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(attributed)
                .font(.system(.callout, design: .rounded))
                .lineSpacing(3)
                .tint(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(label == nil ? Color.secondary.opacity(0.25) : tint.opacity(0.55))
                .frame(width: 3)
        }
    }

    /// Each sentence is a link to its place in the recording; the one playing is highlighted.
    private var attributed: AttributedString {
        var result = AttributedString()
        for (offset, segment) in segments.enumerated() {
            let index = firstIndex + offset
            var part = AttributedString(segment.text)
            if canPlay { part.link = URL(string: "brumlik-seek://\(index)") }
            if index == activeIndex {
                part.backgroundColor = Color.accentColor.opacity(0.22)
            }
            if offset > 0 { result += AttributedString(" ") }
            result += part
        }
        return result
    }

    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.label == rhs.label && lhs.start == rhs.start && lhs.segments == rhs.segments
            && lhs.firstIndex == rhs.firstIndex && lhs.activeIndex == rhs.activeIndex && lhs.canPlay == rhs.canPlay
    }
}
