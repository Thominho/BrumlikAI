import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let loc = LocalizationManager.shared
    let checklist = SetupChecklist.shared
    let updater = UpdateChecker.shared

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var callDetector: CallDetector!
    private var recordingCoordinator: RecordingCoordinator!
    private var windows: [String: NSWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        recordingCoordinator = RecordingCoordinator(appState: appState)

        if let options = SelfTest.Options(arguments: CommandLine.arguments) {
            Task {
                await SelfTest.run(options, coordinator: recordingCoordinator, appState: appState)
                NSApp.terminate(nil)
            }
            return
        }

        callDetector = CallDetector { [weak self] event in
            self?.recordingCoordinator.handleCallEvent(event)
        }
        setupStatusItem()
        setupPopover()
        observeState()

        if appState.autoDetectEnabled {
            callDetector.start()
        }
        updater.startAutomaticChecks { [weak self] in
            guard let coordinator = self?.recordingCoordinator else { return false }
            return !coordinator.isRecording && coordinator.processingIds.isEmpty
        }

        let onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        let previousVersion = UserDefaults.standard.string(forKey: "lastLaunchedVersion")
        UserDefaults.standard.set(updater.currentVersion, forKey: "lastLaunchedVersion")
        if !onboardingCompleted {
            DispatchQueue.main.async { self.showOnboarding() }
        } else if let previousVersion, previousVersion != updater.currentVersion {
            // A new version may have lost macOS permissions (no Developer ID), so let the user re-check them.
            DispatchQueue.main.async { self.openPermissionsGuide() }
        }
        Task { await checklist.refresh() }
    }

    private func observeState() {
        appState.$autoDetectEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.callDetector.start() } else { self.callDetector.stop() }
            }
            .store(in: &cancellables)

        recordingCoordinator.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in self?.updateStatusIcon(recording: recording) }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateStatusIcon(recording: false)
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: recording ? "record.circle.fill" : "waveform.circle",
            accessibilityDescription: "BrumlikAI"
        )
        button.contentTintColor = recording ? .systemRed : nil
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 600)
        popover.behavior = .transient
        let root = MenuBarView(
            onRecordTap: { [weak self] in self?.recordingCoordinator.toggleManual() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenClients: { [weak self] in self?.openClients() },
            onOpenRecording: { [weak self] id in self?.openRecordingDetail(id: id) },
            onOpenGuide: { [weak self] in self?.openPermissionsGuide() }
        )
        popover.contentViewController = NSHostingController(rootView: withEnvironment(root))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func openSettings() {
        present("settings", title: loc.t(.settingsTitle), resizable: false) {
            SettingsView(
                onReopenOnboarding: { [weak self] in self?.showOnboarding() },
                onOpenPermissionsGuide: { [weak self] in self?.openPermissionsGuide() }
            )
        }
    }

    func openPermissionsGuide() {
        present("guide", title: loc.t(.guideTitle), resizable: true) {
            PermissionsGuideView(onEnterToken: { [weak self] in self?.openSettings() })
        }
    }

    func openClients() {
        present("clients", title: loc.t(.clientsTitle), resizable: true) {
            ClientsView()
        }
    }

    func openRecordingDetail(id: UUID) {
        present("detail-\(id.uuidString)", title: loc.t(.detailTitle), resizable: true) {
            RecordingDetailView(recordingId: id)
        }
    }

    func showOnboarding() {
        present("onboarding", title: loc.t(.appName), resizable: false) {
            OnboardingView(onClose: { [weak self] in
                self?.windows["onboarding"]?.close()
                self?.windows["onboarding"] = nil
            })
        }
    }

    private func withEnvironment<Content: View>(_ view: Content) -> some View {
        view
            .environmentObject(appState)
            .environmentObject(loc)
            .environmentObject(checklist)
            .environmentObject(updater)
            .environmentObject(recordingCoordinator)
    }

    private func present<Content: View>(_ key: String, title: String, resizable: Bool, @ViewBuilder content: () -> Content) {
        popover?.performClose(nil)
        if let existing = windows[key] {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: withEnvironment(content())))
        window.title = title
        window.styleMask = resizable
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = !resizable
        window.isReleasedWhenClosed = false
        window.center()
        windows[key] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
