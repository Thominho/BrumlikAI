import SwiftUI
import AppKit

@main
struct BrumlikAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Prázdná scéna — veškerá okna řídí AppDelegate (menu bar + onboarding + nastavení).
        Settings { EmptyView() }
    }
}
