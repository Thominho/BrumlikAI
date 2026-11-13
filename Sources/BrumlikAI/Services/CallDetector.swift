import Foundation

/// Detects a call by watching Core Audio for a call process (FaceTime, iPhone calls, Phone) capturing the microphone.
@MainActor
final class CallDetector {
    private let onEvent: (CallEvent) -> Void
    private var timer: Timer?
    private var isCallActive = false
    private var activeStreak = 0
    private var inactiveStreak = 0

    // Start after ~2–4 s of a connected call; end only after ~6 s without the mic, so a short mute doesn't split the recording.
    private let pollInterval: TimeInterval = 2
    private let pollsToStart = 2
    private let pollsToEnd = 3

    init(onEvent: @escaping (CallEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isCallActive = false
        activeStreak = 0
        inactiveStreak = 0
    }

    private func poll() {
        if CoreAudioProcesses.activeCallProcesses().isEmpty {
            inactiveStreak += 1
            activeStreak = 0
        } else {
            activeStreak += 1
            inactiveStreak = 0
        }

        if !isCallActive && activeStreak >= pollsToStart {
            isCallActive = true
            onEvent(.started(callerHint: CallerDetector.detectCallerHint()))
        } else if isCallActive && inactiveStreak >= pollsToEnd {
            isCallActive = false
            onEvent(.ended)
        }
    }
}
