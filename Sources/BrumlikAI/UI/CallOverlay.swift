import AppKit
import SwiftUI
import Combine

/// What the floating call panel's buttons do.
struct CallOverlayActions {
    var markPrivate: @MainActor () -> Void = {}
    var rememberCaller: @MainActor () -> Void = {}
    var recordAnyway: @MainActor () -> Void = {}
    var dismiss: @MainActor () -> Void = {}
    var openRecording: @MainActor (UUID) -> Void = { _ in }
}

/// The floating panel's content. It takes plain values, so it looks the same in the app and in render tests.
struct CallOverlayCard: View {
    let state: CallOverlay
    let duration: TimeInterval
    let language: AppLanguage
    @Binding var collapsed: Bool
    var actions = CallOverlayActions()

    static let cardWidth: CGFloat = 340

    var body: some View {
        content.environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .recording(let caller, let briefing):
            if collapsed { pill(caller, briefing: briefing) } else { recordingCard(caller, briefing: briefing) }
        case .discarded(let caller, let canRemember):
            discardedCard(caller, canRemember: canRemember)
        case .remembered(let caller):
            card {
                header(icon: "lock.shield.fill", tint: .green, title: t(.hudRememberedTitle), subtitle: t(.hudRememberedBody))
                if !caller.isEmpty { callerChip(caller) }
            }
        case .skipped(let caller):
            card {
                header(icon: "lock.fill", tint: .accentColor, title: t(.hudSkippedTitle), subtitle: callerLine(caller))
                Text(t(.hudSkippedBody))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: actions.recordAnyway) {
                    HUDLabel(title: t(.hudRecordAnyway), symbol: "record.circle")
                }
                .buttonStyle(HUDButtonStyle(kind: .secondary))
            }
        }
    }

    // MARK: - States

    private func recordingCard(_ caller: CallerLabel, briefing: CallBriefing?) -> some View {
        card {
            HStack(spacing: 10) {
                RecordingDot(size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t(.hudRecordingTitle))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(callerLine(caller))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Self.clock(duration))
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                iconButton("chevron.up", help: t(.hudMinimize)) { collapsed = true }
            }
            if let briefing { briefingBox(briefing) }
            VStack(alignment: .leading, spacing: 7) {
                hint(icon: "checkmark.circle", text: t(.hudKeepHint))
                hint(icon: "lock", text: t(.hudPrivateHint))
            }
            Button(action: actions.markPrivate) {
                HUDLabel(title: t(.hudPrivateButton), symbol: "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HUDButtonStyle(kind: .primary))
        }
    }

    /// What the last call with this caller was about, what the user was to do, and an upcoming meeting.
    private func briefingBox(_ briefing: CallBriefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(t(.briefingTitle)) · \(Self.briefingDate(briefing.date, language: language))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button { actions.openRecording(briefing.recordingId) } label: {
                    HStack(spacing: 3) {
                        Text(t(.briefingOpen))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .foregroundStyle(.secondary)

            if !briefing.headline.isEmpty {
                Text(briefing.headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !briefing.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t(.briefingTasks))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(briefing.tasks.enumerated()), id: \.offset) { _, task in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "circle")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(task)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let meeting = briefing.meeting {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(t(.briefingMeeting)): \(Self.meetingDate(meeting, language: language))")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    /// The minimised panel. "Private…" opens the card first, so the explanation is always on screen before anything is deleted.
    private func pill(_ caller: CallerLabel, briefing: CallBriefing?) -> some View {
        HStack(spacing: 8) {
            RecordingDot(size: 8)
            Text(Self.clock(duration))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            if let title = caller.title {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: briefing == nil ? 150 : 110, alignment: .leading)
            }
            if briefing != nil {
                Button { collapsed = false } label: {
                    HUDLabel(title: t(.briefingShort), symbol: "clock.arrow.circlepath")
                }
                .buttonStyle(HUDButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
            }
            Button { collapsed = false } label: {
                HUDLabel(title: t(.hudPrivateShort), symbol: "lock.fill")
            }
            .buttonStyle(HUDButtonStyle(kind: .secondary, compact: true))
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .hudBackground(Capsule(style: .continuous))
    }

    private func discardedCard(_ caller: CallerLabel, canRemember: Bool) -> some View {
        card {
            header(icon: "checkmark.circle.fill", tint: .green, title: t(.hudDiscardedTitle), subtitle: t(.hudDiscardedBody))
            if canRemember {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                VStack(alignment: .leading, spacing: 9) {
                    Text(t(caller.number == nil ? .hudRememberContact : .hudRememberNumber))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    callerChip(caller)
                    HStack(spacing: 8) {
                        Button(action: actions.rememberCaller) {
                            HUDLabel(title: t(.hudRememberButton), symbol: "lock.shield.fill")
                        }
                        .buttonStyle(HUDButtonStyle(kind: .primary))
                        .fixedSize()
                        Button(action: actions.dismiss) {
                            HUDLabel(title: t(.hudOnlyThisTime)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HUDButtonStyle(kind: .secondary))
                    }
                }
            } else {
                Text(t(caller.online == nil ? .hudDiscardedTip : .hudDiscardedOnlineTip))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(width: Self.cardWidth, alignment: .leading)
            .hudBackground(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func header(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.2)).frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            iconButton("xmark", help: t(.close), action: actions.dismiss)
        }
    }

    private func hint(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func callerChip(_ caller: CallerLabel) -> some View {
        HStack(spacing: 7) {
            Image(systemName: caller.online?.symbol ?? (caller.number == nil ? "person.fill" : "phone.fill"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(caller.title ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if let number = caller.subtitle {
                Text(number)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func callerLine(_ caller: CallerLabel) -> String {
        guard let title = caller.title else { return t(.detailContactUnknown) }
        if let number = caller.subtitle { return "\(title) · \(number)" }
        return title
    }

    private func t(_ key: LocKey) -> String { L10n.t(key, language) }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "today 9:40", "yesterday", "12. 11." / "Nov 12" — with the year when it isn't this year.
    static func briefingDate(_ date: Date, language: AppLanguage, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let locale = Locale(identifier: language.localeIdentifier)
        let formatter = DateFormatter()
        formatter.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "\(L10n.t(.briefingToday, language)) \(formatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.t(.briefingYesterday, language)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let template = language == .czech ? (sameYear ? "dM" : "dMy") : (sameYear ? "MMMd" : "MMMdy")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// "čt 20. 11. 14:00" / "Thu, Nov 20, 2:00 PM".
    static func meetingDate(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate(language == .czech ? "EEEdMjmm" : "EEEMMMdjmm")
        return formatter.string(from: date)
    }
}

/// Icon and title laid out explicitly, so button widths are predictable.
private struct HUDLabel: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
    }
}

/// Pill-shaped buttons in the dark panel: white for the main action, translucent for the rest.
struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 9)
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .background(Capsule(style: .continuous).fill(kind == .primary ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A red dot with a soft pulse, the universal "recording" sign.
struct RecordingDot: View {
    var size: CGFloat = 10
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.45))
                .frame(width: size, height: size)
                .scaleEffect(pulsing ? 2.3 : 1)
                .opacity(pulsing ? 0 : 0.8)
            Circle()
                .fill(Color.red)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.3, height: size * 2.3)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulsing = true }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    func hudBackground<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(Color(white: 0.09).opacity(0.95)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .clipShape(shape)
    }
}

// MARK: - Panel

/// Panel state that lives outside the card: whether it's shrunk to a pill.
@MainActor
private final class CallOverlayModel: ObservableObject {
    @Published var collapsed = false
}

/// Feeds the card from the coordinator.
private struct CallOverlayRoot: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var loc: LocalizationManager
    @ObservedObject var model: CallOverlayModel
    let openRecording: @MainActor (UUID) -> Void

    var body: some View {
        ZStack {
            if let state = coordinator.overlay {
                CallOverlayCard(
                    state: state,
                    duration: coordinator.currentDuration,
                    language: loc.language,
                    collapsed: $model.collapsed,
                    actions: CallOverlayActions(
                        markPrivate: { Task { await coordinator.discardRecording() } },
                        rememberCaller: { coordinator.rememberDiscardedCaller() },
                        recordAnyway: { coordinator.recordAnyway() },
                        dismiss: { coordinator.dismissOverlay() },
                        openRecording: openRecording
                    )
                )
            }
        }
        .fixedSize()
        // Shown in full while the call starts (longer when it recalls the last call), then shrunk to a pill.
        .task(id: coordinator.overlay) {
            guard case .recording(_, let briefing) = coordinator.overlay else {
                if model.collapsed { model.collapsed = false }
                return
            }
            let seconds: UInt64 = briefing == nil ? 12 : 30
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            model.collapsed = true
        }
    }
}

private final class CallOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons react to the first click even though the panel never activates BrumlikAI.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the call panel at the top of the screen whenever the coordinator has something to say during a call.
@MainActor
final class CallOverlayController {
    private let coordinator: RecordingCoordinator
    private let loc: LocalizationManager
    private let openRecording: @MainActor (UUID) -> Void
    private let model = CallOverlayModel()
    private var panel: CallOverlayPanel?
    private var cancellables: Set<AnyCancellable> = []
    /// Top centre the panel hangs from; follows the panel when the user drags it.
    private var anchor: CGPoint?
    private var isPositioning = false
    private static let topGap: CGFloat = 8

    /// `openRecording` opens a call's detail window (the last call, from the panel's recap).
    init(coordinator: RecordingCoordinator, loc: LocalizationManager, openRecording: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.coordinator = coordinator
        self.loc = loc
        self.openRecording = openRecording

        // @Published fires before the value is stored, so react on the next turn of the main queue.
        coordinator.$overlay
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            }
            .store(in: &cancellables)

        // Whatever changes the content's size: the state, the pill, the language, an hour-long call.
        Publishers.Merge4(
            coordinator.$overlay.map { _ in () },
            model.$collapsed.removeDuplicates().map { _ in () },
            loc.$language.removeDuplicates().map { _ in () },
            coordinator.$currentDuration.map { $0 >= 3600 }.removeDuplicates().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.fitToContent() }
        .store(in: &cancellables)
    }

    private func makePanel() -> CallOverlayPanel {
        let panel = CallOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: CallOverlayCard.cardWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        // The hosting view sits in a plain container and reports no size of its own, so AppKit never
        // resizes the panel (it would keep the top-left corner); the controller sizes it, anchored top centre.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: CallOverlayCard.cardWidth, height: 120))
        let hosting = FirstMouseHostingView(rootView: CallOverlayRoot(
            coordinator: coordinator,
            loc: loc,
            model: model,
            openRecording: openRecording
        ))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self, weak panel] _ in
                guard let self, let panel, !self.isPositioning else { return }
                self.anchor = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
            }
            .store(in: &cancellables)
        return panel
    }

    /// The card's ideal size, measured on a throwaway copy with the same values.
    private func measuredSize() -> CGSize? {
        guard let state = coordinator.overlay else { return nil }
        let probe = NSHostingView(rootView: CallOverlayCard(
            state: state,
            duration: coordinator.currentDuration,
            language: loc.language,
            collapsed: .constant(model.collapsed)
        ).fixedSize())
        let size = probe.fittingSize
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return nil }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func fitToContent() {
        guard let panel, panel.isVisible, let size = measuredSize() else { return }
        resize(panel, to: size)
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            placeAtTop(panel, size: measuredSize() ?? CGSize(width: CallOverlayCard.cardWidth, height: 120))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // Something new may have appeared while fading out.
                guard let self, self.coordinator.overlay == nil else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func placeAtTop(_ panel: NSPanel, size: CGSize) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        anchor = CGPoint(x: visible.midX, y: visible.maxY - Self.topGap)
        resize(panel, to: size, force: true)
    }

    /// Fits the panel to the content, hanging from its top centre (wherever the user dragged it).
    private func resize(_ panel: NSPanel, to size: CGSize, force: Bool = false) {
        let current = panel.frame
        guard force || abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        let anchor = self.anchor ?? CGPoint(x: current.midX, y: current.maxY)
        var frame = NSRect(
            x: (anchor.x - size.width / 2).rounded(),
            y: anchor.y - size.height,
            width: size.width,
            height: size.height
        )
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height)
        }
        isPositioning = true
        panel.setFrame(frame, display: true)
        isPositioning = false
        panel.invalidateShadow()
    }

    /// Diagnostics: draws the panel's content into a PNG (no screen recording needed) and returns where the panel is.
    func snapshot(to url: URL) -> (frame: CGRect, screen: CGRect?)? {
        guard let panel, panel.isVisible, let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        return (panel.frame, panel.screen?.visibleFrame)
    }
}
