import Foundation
import AppKit
import AVFoundation
import EventKit
import Contacts
import CoreGraphics
import UserNotifications

enum SetupItem: String, CaseIterable, Identifiable {
    case microphone, systemAudio, deepInfra, iphoneCalls, calendars, reminders, notifications, contacts, screenRecording

    var id: String { rawValue }

    var isRequired: Bool {
        switch self {
        case .microphone, .systemAudio, .deepInfra, .iphoneCalls: return true
        case .calendars, .reminders, .notifications, .contacts, .screenRecording: return false
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .deepInfra: return "key.fill"
        case .iphoneCalls: return "iphone"
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .notifications: return "bell.badge.fill"
        case .contacts: return "person.crop.circle"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    var title: LocKey {
        switch self {
        case .microphone: return .guideMicTitle
        case .systemAudio: return .guideSystemAudioTitle
        case .deepInfra: return .guideTokenTitle
        case .iphoneCalls: return .guideIPhoneTitle
        case .calendars: return .guideCalendarTitle
        case .reminders: return .guideRemindersTitle
        case .notifications: return .guideNotificationsTitle
        case .contacts: return .guideContactsTitle
        case .screenRecording: return .guideScreenTitle
        }
    }

    var why: LocKey {
        switch self {
        case .microphone: return .guideMicWhy
        case .systemAudio: return .guideSystemAudioWhy
        case .deepInfra: return .guideTokenWhy
        case .iphoneCalls: return .guideIPhoneWhy
        case .calendars: return .guideCalendarWhy
        case .reminders: return .guideRemindersWhy
        case .notifications: return .guideNotificationsWhy
        case .contacts: return .guideContactsWhy
        case .screenRecording: return .guideScreenWhy
        }
    }

    var steps: LocKey {
        switch self {
        case .microphone: return .guideMicSteps
        case .systemAudio: return .guideSystemAudioSteps
        case .deepInfra: return .guideTokenSteps
        case .iphoneCalls: return .guideIPhoneSteps
        case .calendars: return .guideCalendarSteps
        case .reminders: return .guideRemindersSteps
        case .notifications: return .guideNotificationsSteps
        case .contacts: return .guideContactsSteps
        case .screenRecording: return .guideScreenSteps
        }
    }

    var settingsURL: URL? {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone: return URL(string: privacy + "Privacy_Microphone")
        case .systemAudio, .screenRecording: return URL(string: privacy + "Privacy_ScreenCapture")
        case .calendars: return URL(string: privacy + "Privacy_Calendars")
        case .reminders: return URL(string: privacy + "Privacy_Reminders")
        case .contacts: return URL(string: privacy + "Privacy_Contacts")
        case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .deepInfra, .iphoneCalls: return nil
        }
    }
}

enum SetupStatus: Equatable {
    case done
    case missing
    case unknown
    case checking
    case failed(String)
}

/// Live status of everything BrumlikAI needs: permissions, the system audio test, the API token and the iPhone setup.
@MainActor
final class SetupChecklist: ObservableObject {
    static let shared = SetupChecklist()

    @Published private(set) var statuses: [SetupItem: SetupStatus] = [:]
    private var tokenCheck: SetupStatus?

    private static let systemAudioWorksKey = "setup.systemAudioWorks"
    private static let systemAudioBuildKey = "setup.systemAudioBuild"
    private static let iphoneConfirmedKey = "setup.iphoneCallsConfirmed"
    private static let screenRequestedKey = "setup.screenRecordingRequested"

    func status(_ item: SetupItem) -> SetupStatus {
        statuses[item] ?? .unknown
    }

    var doneCount: Int {
        SetupItem.allCases.filter { status($0) == .done }.count
    }

    /// Required steps that are known to be missing — unverified ones don't count, so nobody gets nagged by guesses.
    var requiredMissingCount: Int {
        SetupItem.allCases.filter { item in
            guard item.isRequired else { return false }
            switch status(item) {
            case .missing, .failed: return true
            case .done, .unknown, .checking: return false
            }
        }.count
    }

    func refresh() async {
        statuses[.microphone] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .done : .missing
        if status(.systemAudio) != .checking {
            statuses[.systemAudio] = storedSystemAudioStatus()
        }
        if status(.deepInfra) != .checking {
            statuses[.deepInfra] = Keychain.exists(key: "deepinfra_token") ? (tokenCheck ?? .unknown) : .missing
        }
        statuses[.iphoneCalls] = UserDefaults.standard.bool(forKey: Self.iphoneConfirmedKey) ? .done : .unknown
        statuses[.calendars] = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? .done : .missing
        statuses[.reminders] = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? .done : .missing
        statuses[.contacts] = CNContactStore.authorizationStatus(for: .contacts) == .authorized ? .done : .missing
        statuses[.screenRecording] = CGPreflightScreenCaptureAccess() ? .done : .missing
        let notifications = await UNUserNotificationCenter.current().notificationSettings()
        statuses[.notifications] = [.authorized, .provisional].contains(notifications.authorizationStatus) ? .done : .missing
    }

    /// The main action of a guide row: ask for the permission if macOS still can, otherwise open the right System Settings pane.
    func perform(_ item: SetupItem) async {
        switch item {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                openSystemSettings(for: item)
            }
        case .systemAudio:
            await testSystemAudio()
        case .deepInfra:
            await checkToken()
        case .iphoneCalls:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FaceTime.app"))
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await EKEventStore().requestFullAccessToEvents()
            } else {
                openSystemSettings(for: item)
            }
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await EKEventStore().requestFullAccessToReminders()
            } else {
                openSystemSettings(for: item)
            }
        case .contacts:
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            } else {
                openSystemSettings(for: item)
            }
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } else {
                openSystemSettings(for: item)
            }
        case .screenRecording:
            // macOS shows its own dialog only the first time; after that the user has to use System Settings.
            if UserDefaults.standard.bool(forKey: Self.screenRequestedKey) {
                openSystemSettings(for: item)
            } else {
                UserDefaults.standard.set(true, forKey: Self.screenRequestedKey)
                _ = CGRequestScreenCaptureAccess()
            }
        }
        await refresh()
    }

    func openSystemSettings(for item: SetupItem) {
        if let url = item.settingsURL { NSWorkspace.shared.open(url) }
    }

    func setIPhoneCallsConfirmed(_ confirmed: Bool) {
        UserDefaults.standard.set(confirmed, forKey: Self.iphoneConfirmedKey)
        statuses[.iphoneCalls] = confirmed ? .done : .unknown
    }

    func tokenChanged() {
        tokenCheck = nil
        statuses[.deepInfra] = Keychain.exists(key: "deepinfra_token") ? .unknown : .missing
    }

    func checkToken() async {
        statuses[.deepInfra] = .checking
        do {
            try await DeepInfraClient { Keychain.read(key: "deepinfra_token") }.checkToken()
            tokenCheck = .done
        } catch DeepInfraError.missingToken {
            tokenCheck = nil
            statuses[.deepInfra] = .missing
            return
        } catch {
            tokenCheck = .failed(L10n.f(.guideTokenInvalid, error.localizedDescription))
        }
        statuses[.deepInfra] = tokenCheck
    }

    func testSystemAudio() async {
        statuses[.systemAudio] = .checking
        let works = await SystemAudioTap.verifyCapture()
        storeSystemAudio(works)
        statuses[.systemAudio] = works ? .done : .missing
    }

    func markSystemAudioWorking() {
        storeSystemAudio(true)
        statuses[.systemAudio] = .done
    }

    // MARK: - System audio result

    /// Permissions of an app without a Developer ID reset with every build, so a test result only counts for the build that produced it.
    private static var buildStamp: String {
        guard let url = Bundle.main.executableURL,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return "unknown" }
        return String(Int(date.timeIntervalSince1970))
    }

    private func storeSystemAudio(_ works: Bool) {
        UserDefaults.standard.set(works, forKey: Self.systemAudioWorksKey)
        UserDefaults.standard.set(Self.buildStamp, forKey: Self.systemAudioBuildKey)
    }

    private func storedSystemAudioStatus() -> SetupStatus {
        guard UserDefaults.standard.string(forKey: Self.systemAudioBuildKey) == Self.buildStamp,
              UserDefaults.standard.object(forKey: Self.systemAudioWorksKey) != nil else { return .unknown }
        return UserDefaults.standard.bool(forKey: Self.systemAudioWorksKey) ? .done : .missing
    }
}
