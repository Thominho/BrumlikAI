import Foundation

/// What Core Audio reports about calls right now.
struct CallAudioActivity: Equatable {
    /// A call process (FaceTime, iPhone calls, Phone) is capturing the microphone.
    var phoneCall = false
    var chrome = CoreAudioProcesses.AppAudio()
    var whatsApp = CoreAudioProcesses.AppAudio()

    static func current() -> CallAudioActivity {
        let processes = CoreAudioProcesses.list().filter { !$0.isCurrentProcess }
        return CallAudioActivity(
            phoneCall: processes.contains { $0.isRunningInput && $0.isCallProcess },
            chrome: CoreAudioProcesses.audio(of: processes, bundlePrefix: OnlineCallApps.chrome),
            whatsApp: CoreAudioProcesses.audio(of: processes, bundlePrefix: OnlineCallApps.whatsApp)
        )
    }
}

/// Detects a call by watching Core Audio:
/// - a call process (FaceTime, iPhone calls, Phone) capturing the microphone, or
/// - Chrome or the WhatsApp app capturing the microphone while playing sound: a Google Meet or WhatsApp call.
///   In Chrome, the window titles tell Meet from WhatsApp; without the Screen Recording permission
///   they're hidden and calls in Chrome aren't recognised.
@MainActor
final class CallDetector {
    private enum Call: Equatable {
        case phone
        case online(OnlineCall)

        func isSameKind(as other: Call) -> Bool {
            switch (self, other) {
            case (.phone, .phone): return true
            case let (.online(first), .online(second)): return first.service == second.service && first.app == second.app
            default: return false
            }
        }
    }

    private let onEvent: (CallEvent) -> Void
    private let detectsOnlineCalls: () -> Bool
    private let probe: () -> CallAudioActivity
    private let recognizeChromeCall: () -> OnlineCall?
    private let callerHint: () -> String?

    private var timer: Timer?
    private var activeCall: Call?
    /// What the last polls saw before it lasted long enough to count as a call.
    private var candidate: Call?
    private var activeStreak = 0
    private var inactiveStreak = 0

    // Start after ~2–4 s of a connected call; end only after ~6 s without the mic, so a short mute doesn't split the recording.
    private let pollInterval: TimeInterval = 2
    private let pollsToStart = 2
    private let pollsToEnd = 3

    /// Tests pass what Core Audio, the Chrome windows and the call window would report.
    init(
        detectsOnlineCalls: @escaping () -> Bool = { true },
        probe: @escaping () -> CallAudioActivity = { CallAudioActivity.current() },
        recognizeChromeCall: @escaping () -> OnlineCall? = {
            OnlineCallRecognizer.recognize(chromeTitles: AppWindows.titles(bundlePrefix: OnlineCallApps.chrome))
        },
        callerHint: @escaping () -> String? = { CallerDetector.detectCallerHint() },
        onEvent: @escaping (CallEvent) -> Void
    ) {
        self.detectsOnlineCalls = detectsOnlineCalls
        self.probe = probe
        self.recognizeChromeCall = recognizeChromeCall
        self.callerHint = callerHint
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
        activeCall = nil
        candidate = nil
        activeStreak = 0
        inactiveStreak = 0
    }

    /// One look at Core Audio; the timer does it every two seconds.
    func poll() {
        let activity = probe()

        if let call = activeCall {
            inactiveStreak = isOngoing(call, activity) ? 0 : inactiveStreak + 1
            guard inactiveStreak >= pollsToEnd else { return }
            activeCall = nil
            inactiveStreak = 0
            onEvent(.ended)
            return
        }

        guard let seen = detect(activity) else {
            candidate = nil
            activeStreak = 0
            return
        }
        activeStreak = candidate?.isSameKind(as: seen) == true ? activeStreak + 1 : 1
        candidate = seen
        guard activeStreak >= pollsToStart else { return }

        activeCall = seen
        candidate = nil
        activeStreak = 0
        switch seen {
        case .phone:
            onEvent(.started(callerHint: callerHint()))
        case .online(let call):
            onEvent(.started(callerHint: nil, online: call))
        }
    }

    private func detect(_ activity: CallAudioActivity) -> Call? {
        if activity.phoneCall { return .phone }
        guard detectsOnlineCalls() else { return nil }
        if activity.whatsApp.inCall { return .online(OnlineCall(service: .whatsapp, app: .whatsapp)) }
        if activity.chrome.inCall, let call = recognizeChromeCall() { return .online(call) }
        return nil
    }

    /// A call in Chrome lasts while Chrome keeps the microphone — Meet keeps it even when you're muted, and other tabs
    /// may go on playing sound after the call. The WhatsApp app's call lasts while it captures or plays call audio.
    private func isOngoing(_ call: Call, _ activity: CallAudioActivity) -> Bool {
        switch call {
        case .phone:
            return activity.phoneCall
        case .online(let online):
            switch online.app {
            case .chrome: return activity.chrome.input
            case .whatsapp: return activity.whatsApp.input || activity.whatsApp.output
            }
        }
    }
}
