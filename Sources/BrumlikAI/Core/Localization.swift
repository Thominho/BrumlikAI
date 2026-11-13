import Foundation
import SwiftUI
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case czech = "cs"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: return "English"
        case .czech: return "Čeština"
        }
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appLanguage")
        self.language = AppLanguage(rawValue: stored ?? "en") ?? .english
    }

    func t(_ key: LocKey) -> String {
        L10n.t(key, language)
    }
}

extension AppLanguage {
    /// Readable from any thread; `LocalizationManager` keeps it in sync.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .english
    }

    var localeIdentifier: String { self == .czech ? "cs_CZ" : "en_US" }

    /// Language name as written in instructions for the LLM.
    var llmName: String { self == .czech ? "Czech" : "English" }
}

/// String lookup usable outside SwiftUI views (errors, notifications, models).
enum L10n {
    static func t(_ key: LocKey, _ language: AppLanguage = .current) -> String {
        switch language {
        case .english: return Strings.english[key] ?? key.rawValue
        case .czech: return Strings.czech[key] ?? Strings.english[key] ?? key.rawValue
        }
    }

    static func f(_ key: LocKey, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

enum LocKey: String {
    case appName
    case menuRecord, menuStop, menuSettings, menuQuit, menuHistory, menuClients
    case statusIdle, statusRecording, statusProcessing

    case onboardingWelcomeTitle, onboardingWelcomeSubtitle, onboardingWelcomeBody, onboardingContinue
    case onboardingConsentTitle, onboardingConsentBody, onboardingConsentAck
    case onboardingApiTitle, onboardingApiBody, onboardingApiPlaceholder, onboardingApiHelp
    case onboardingRoleTitle, onboardingRoleBody, onboardingRolePlaceholder, onboardingRoleHelp, onboardingRoleDefault
    case onboardingGuideTitle, onboardingGuideBody
    case onboardingDoneTitle, onboardingDoneBody, onboardingFinish

    case settingsTitle, settingsLanguage, settingsApiToken, settingsApiReveal, settingsApiSave, settingsCalendar, settingsRemindersList, settingsAutoDetect, settingsReopenGuide, settingsConsent, settingsLaunchAtLogin, settingsLaunchAtLoginHint, settingsRole, settingsRoleHelp

    case chunkingProgress, chunkingFailed

    case tasksTitle, tasksEmpty, tasksAddToReminders, tasksAdded, tasksDue, tasksList

    case meetingEdit, meetingSaveEdit, meetingTitleField, meetingStartField, meetingDurationField, meetingLocationField, meetingNotesField, meetingDurationMinutes

    case searchPlaceholder, searchNoResults

    case recordingsTitle, recordingsEmpty, recordingProcessing, recordingSummary, recordingRequests, recordingMeeting, recordingAddToCalendar, recordingAdded, recordingTranscriptToggle, recordingDelete, recordingOpenDetail

    case detailTitle, detailClient, detailAssignClient, detailUnassigned, detailHumanSummary, detailHumanSummaryHint, detailAiPrompt, detailAiPromptHint, detailCopy, detailCopied, detailRegeneratingPrompt, detailTranscript, detailMetadata, detailDuration
    case detailContact, detailPhone, detailNoPhone, detailEditContact, detailContactName, detailContactCompany, detailContactSave, detailContactSaveHint, detailContactRememberHint, detailContactFromContacts, detailContactUnknown

    case clientsTitle, clientsEmpty, clientsAdd, clientsAddManual, clientsAddFromAres, clientsAresHint, clientsIcoPlaceholder, clientsLookup, clientsName, clientsContact, clientsEmail, clientsPhone, clientsAddress, clientsNotes, clientsAssets, clientsAddAsset, clientsAssetName, clientsAssetUrl, clientsAssetServer, clientsAssetTech, clientsAssetNotes, clientsAssetCredentials, clientsSave, clientsDelete, clientsConfirmDelete

    case errMissingToken, errBadResponse, errDecodingFailed, errInvalidURL, errEmptyTranscript, errAudioMissing, errNoAudio, errMixFailed
    case errMicUnavailable, errSystemAudioFailed, errFileCreation, errAlreadyRecording, errNotRecording, errNothingToRecord
    case errInterruptedRecording, errInterruptedProcessing
    case errCalendarNotAuthorized, errCalendarInvalidDate, errCalendarSaveFailed, errRemindersNotAuthorized, errRemindersSaveFailed
    case warnCallerSilent, warnMicSilent
    case notifRecordingStarted, notifSummarised, notifSummarisedMeeting, notifMeetingAdded, notifFailed
    case createdByBrumlik, retryButton, failedTitle, audioWarningTitle
    case statusPreparing, statusTranscribing, statusSummarizing, statusFailedShort
    case menuSetupIncomplete, menuOpenGuide

    case settingsCallLanguage, settingsCallLanguageAuto, settingsCallLanguageHint, settingsShowAIPrompt, settingsShowAIPromptHint, settingsOpenGuide
    case settingsDiagnostics, settingsTestRecording, settingsTestHint, settingsTestRunning, settingsTestCaller, settingsTestMic, settingsTestOK, settingsTestSilent, settingsTestNotRecorded
    case settingsProcesses, settingsProcessesHint, settingsRefresh, settingsCallTag

    case assetWeb, assetApp, assetCRM, assetServer, assetOther

    case guideTitle, guideSubtitle, guideProgress, guideRequired, guideRecommended
    case guideStatusAllowed, guideStatusNotAllowed, guideStatusNotVerified, guideStatusChecking, guideStatusWorks, guideStatusNotWorking, guideStatusDone, guideStatusMissing
    case guideAllow, guideOpenSettings, guideTest, guideHowTo, guideMarkDone, guideOpenFaceTime, guideCheckToken, guideEnterToken, guideTokenInvalid
    case guideMicTitle, guideMicWhy, guideMicSteps
    case guideSystemAudioTitle, guideSystemAudioWhy, guideSystemAudioSteps
    case guideTokenTitle, guideTokenWhy, guideTokenSteps
    case guideIPhoneTitle, guideIPhoneWhy, guideIPhoneSteps
    case guideCalendarTitle, guideCalendarWhy, guideCalendarSteps
    case guideRemindersTitle, guideRemindersWhy, guideRemindersSteps
    case guideNotificationsTitle, guideNotificationsWhy, guideNotificationsSteps
    case guideContactsTitle, guideContactsWhy, guideContactsSteps
    case guideScreenTitle, guideScreenWhy, guideScreenSteps
    case guideUpdateNoteTitle, guideUpdateNote
    case updatesTitle, updatesCurrentVersion, updatesAutoCheck, updatesAutoInstall, updatesAutoInstallHint, updatesCheckNow, updatesChecking
    case updatesUpToDate, updatesAvailable, updatesInstall, updatesDownloading, updatesInstalling, updatesNotConfigured, updatesReleaseNotes
    case errUpdateHTTP, errUpdateSignature, errUpdateBundle, errUpdateLocation
    case settingsInputDevice

    case errorTitle, errorDismiss

    case previous, next, cancel, save, close, delete, edit
}

enum Strings {
    static let english: [LocKey: String] = [
        .appName: "BrumlikAI",
        .menuRecord: "Start recording",
        .menuStop: "Stop recording",
        .menuSettings: "Settings…",
        .menuQuit: "Quit BrumlikAI",
        .menuHistory: "Recent calls",
        .menuClients: "Clients",
        .statusIdle: "Idle",
        .statusRecording: "Recording",
        .statusProcessing: "Processing…",

        .onboardingWelcomeTitle: "Welcome to BrumlikAI",
        .onboardingWelcomeSubtitle: "AI summaries of your phone calls.",
        .onboardingWelcomeBody: "BrumlikAI waits in your menu bar. When you answer a phone call on your Mac (via iPhone Continuity), it records it, transcribes it with DeepInfra, summarises the client's web / app requests, and if you agreed on a meeting, adds it to your Apple Calendar.",
        .onboardingContinue: "Continue",

        .onboardingConsentTitle: "Legal consent",
        .onboardingConsentBody: "Recording phone calls is subject to data protection law (GDPR in the EU) and often requires the other party's consent. Tell the other party at the start of every call that it's being recorded. BrumlikAI keeps recordings on your Mac; the audio and the transcript are sent to DeepInfra for processing.",
        .onboardingConsentAck: "I understand — I will inform callers that the call is recorded.",

        .onboardingApiTitle: "DeepInfra API token",
        .onboardingApiBody: "BrumlikAI uses DeepInfra for transcription (Whisper) and summarisation (Llama). Create a free account at deepinfra.com, generate a token in your dashboard, and paste it below. The token is stored in your macOS Keychain.",
        .onboardingApiPlaceholder: "sk-…",
        .onboardingApiHelp: "Get your token at deepinfra.com → Dashboard → API Keys",

        .onboardingRoleTitle: "What do you do for clients?",
        .onboardingRoleBody: "Describe your work in one or two sentences. BrumlikAI uses it to focus the summaries on what matters in your field — a web developer, a graphic designer and an accountant care about different details of the same call. It also shapes the optional AI prompts.",
        .onboardingRolePlaceholder: "e.g. I manage WordPress sites and iOS apps for small businesses…",
        .onboardingRoleHelp: "You can change this any time in Settings.",
        .onboardingRoleDefault: "I manage websites and mobile apps for my clients.",

        .errMissingToken: "The DeepInfra API token is missing. Add it in Settings.",
        .errBadResponse: "DeepInfra returned error %d: %@",
        .errDecodingFailed: "DeepInfra's response couldn't be read.",
        .errInvalidURL: "Invalid URL.",
        .errEmptyTranscript: "The transcript is empty — the recording probably contains no speech.",
        .errAudioMissing: "The audio file for this call is missing.",
        .errNoAudio: "The recording contains no audio.",
        .errMixFailed: "Preparing the audio failed: %@",
        .errMicUnavailable: "The microphone isn't available. Check the microphone permission in the setup guide.",
        .errSystemAudioFailed: "Capturing the call audio failed (Core Audio error %d).",
        .errFileCreation: "The recording file couldn't be created: %@",
        .errAlreadyRecording: "A recording is already running.",
        .errNotRecording: "No recording is running.",
        .errNothingToRecord: "Nothing could be recorded. %@",
        .errInterruptedRecording: "The recording was interrupted (the app quit or crashed). You can still process what was recorded.",
        .errInterruptedProcessing: "Processing was interrupted when the app quit.",
        .errCalendarNotAuthorized: "BrumlikAI can't access your calendars. Allow it in the setup guide.",
        .errCalendarInvalidDate: "The meeting time couldn't be read. Edit the meeting and set the time.",
        .errCalendarSaveFailed: "Saving to Calendar failed: %@",
        .errRemindersNotAuthorized: "BrumlikAI can't access Reminders. Allow it in the setup guide.",
        .errRemindersSaveFailed: "Saving to Reminders failed: %@",

        .warnCallerSilent: "The other party's audio was completely silent. Open the setup guide and test system audio.",
        .warnMicSilent: "The microphone (%@) recorded only silence. Allow microphone access in the setup guide — and if this Mac has no microphone (e.g. a Mac mini), connect a headset and choose it as the sound input.",

        .notifRecordingStarted: "Recording started",
        .notifSummarised: "Call summarised",
        .notifSummarisedMeeting: "Call summarised — a meeting is waiting for confirmation",
        .notifMeetingAdded: "Meeting added to Calendar",
        .notifFailed: "Processing the call failed — open it to try again.",

        .createdByBrumlik: "Created by BrumlikAI",
        .retryButton: "Try again",
        .failedTitle: "Processing failed",
        .audioWarningTitle: "Audio check",
        .statusPreparing: "Preparing audio…",
        .statusTranscribing: "Transcribing…",
        .statusSummarizing: "Summarising…",
        .statusFailedShort: "Failed",
        .menuSetupIncomplete: "Setup isn't finished — required steps missing: %d",
        .menuOpenGuide: "Open guide",

        .settingsCallLanguage: "Language of your calls",
        .settingsCallLanguageAuto: "Detect automatically",
        .settingsCallLanguageHint: "Used for the transcript. Summaries are written in the app's language.",
        .settingsShowAIPrompt: "Show AI prompts under the summary",
        .settingsShowAIPromptHint: "Adds a ready-to-paste instruction for Claude, Cursor or another AI tool to each call.",
        .settingsOpenGuide: "Permissions & setup guide",
        .settingsDiagnostics: "Diagnostics",
        .settingsTestRecording: "Test recording (5 s)",
        .settingsTestHint: "During the test, play some sound (e.g. a video) and say a few words.",
        .settingsTestRunning: "Recording…",
        .settingsTestCaller: "Other party's audio",
        .settingsTestMic: "Microphone",
        .settingsTestOK: "works",
        .settingsTestSilent: "silent",
        .settingsTestNotRecorded: "not recorded",
        .settingsProcesses: "Apps using audio right now",
        .settingsProcessesHint: "During a call, the app handling it should be tagged “call” and use the microphone. If none is, automatic detection won't work — start recording manually.",
        .settingsRefresh: "Refresh",
        .settingsCallTag: "call",

        .assetWeb: "Website",
        .assetApp: "App",
        .assetCRM: "CRM",
        .assetServer: "Server",
        .assetOther: "Other",

        .guideTitle: "Setup guide",
        .guideSubtitle: "Everything BrumlikAI needs to work. The status refreshes when you come back from System Settings.",
        .guideProgress: "%d of %d done",
        .guideRequired: "Required",
        .guideRecommended: "Recommended",
        .guideStatusAllowed: "Allowed",
        .guideStatusNotAllowed: "Not allowed",
        .guideStatusNotVerified: "Not verified",
        .guideStatusChecking: "Checking…",
        .guideStatusWorks: "Works",
        .guideStatusNotWorking: "Not working",
        .guideStatusDone: "Done",
        .guideStatusMissing: "Missing",
        .guideAllow: "Allow",
        .guideOpenSettings: "Open System Settings",
        .guideTest: "Test",
        .guideHowTo: "How to",
        .guideMarkDone: "I've done this",
        .guideOpenFaceTime: "Open FaceTime",
        .guideCheckToken: "Check token",
        .guideEnterToken: "Enter token",
        .guideTokenInvalid: "The token doesn't work: %@",

        .guideMicTitle: "Microphone",
        .guideMicWhy: "Records your voice during the call. Mac mini, Mac Studio and Mac Pro have no built-in microphone — connect a headset.",
        .guideMicSteps: "1. Click Allow and confirm the system dialog.\n2. If you clicked Don't Allow earlier: open System Settings → Privacy & Security → Microphone and turn on BrumlikAI.",
        .guideSystemAudioTitle: "System audio",
        .guideSystemAudioWhy: "Records the other party's voice. Without it, the summary only contains what you said.",
        .guideSystemAudioSteps: "1. Click Test — you'll hear a short sound.\n2. If macOS asks, click Allow and run the test again.\n3. If it still fails: System Settings → Privacy & Security → Screen & System Audio Recording → turn on BrumlikAI under System Audio Recording Only (add it with + if it isn't listed).",
        .guideTokenTitle: "DeepInfra API token",
        .guideTokenWhy: "Needed for the transcript and the summary.",
        .guideTokenSteps: "1. Create an account at deepinfra.com.\n2. In the dashboard, open API Keys and create a key.\n3. Paste it in BrumlikAI Settings and click Check token.",
        .guideIPhoneTitle: "Calls from your iPhone on this Mac",
        .guideIPhoneWhy: "BrumlikAI records calls you take on the Mac. A call answered only on the iPhone can't be recorded.",
        .guideIPhoneSteps: "1. iPhone: Settings → Phone → Calls on Other Devices → allow calls and turn on this Mac.\n2. Mac: open FaceTime → Settings → turn on Calls from iPhone.\n3. Both devices: the same Apple Account, Wi-Fi and Bluetooth on.\n4. Answer incoming calls on the Mac (the notification in the corner of the screen).",
        .guideCalendarTitle: "Calendars",
        .guideCalendarWhy: "Saves agreed meetings to Apple Calendar.",
        .guideCalendarSteps: "Click Allow and choose full access. If nothing happens, turn on BrumlikAI in System Settings → Privacy & Security → Calendars.",
        .guideRemindersTitle: "Reminders",
        .guideRemindersWhy: "Saves to-dos from your calls to Apple Reminders.",
        .guideRemindersSteps: "Click Allow and choose full access. If nothing happens, turn on BrumlikAI in System Settings → Privacy & Security → Reminders.",
        .guideNotificationsTitle: "Notifications",
        .guideNotificationsWhy: "Lets you know when a recording starts and when the summary is ready.",
        .guideNotificationsSteps: "Click Allow. If nothing happens, turn on BrumlikAI in System Settings → Notifications.",
        .guideContactsTitle: "Contacts",
        .guideContactsWhy: "Shows the caller's name from your contacts.",
        .guideContactsSteps: "Click Allow and confirm. If nothing happens, turn on BrumlikAI in System Settings → Privacy & Security → Contacts.",
        .guideScreenTitle: "Screen recording",
        .guideScreenWhy: "Lets BrumlikAI read the caller's name or number from the call window. Without it you'll type the name yourself.",
        .guideScreenSteps: "1. Click Allow — macOS shows a dialog that opens System Settings.\n2. Under Screen & System Audio Recording, turn on BrumlikAI.\n3. macOS may ask you to quit and reopen BrumlikAI.",
        .updatesTitle: "Updates",
        .updatesCurrentVersion: "Version %@",
        .updatesAutoCheck: "Check for updates automatically",
        .updatesAutoInstall: "Install updates automatically",
        .updatesAutoInstallHint: "Only while no call is being recorded or processed. BrumlikAI restarts itself and opens the setup guide so you can re-check permissions.",
        .updatesCheckNow: "Check now",
        .updatesChecking: "Checking…",
        .updatesUpToDate: "You have the latest version.",
        .updatesAvailable: "BrumlikAI %@ is available.",
        .updatesInstall: "Install and restart",
        .updatesDownloading: "Downloading…",
        .updatesInstalling: "Installing…",
        .updatesNotConfigured: "Updates aren't set up for this build.",
        .updatesReleaseNotes: "What's new",
        .errUpdateHTTP: "GitHub returned error %d.",
        .errUpdateSignature: "The update's signature doesn't match, so it wasn't installed.",
        .errUpdateBundle: "The downloaded update isn't a valid newer BrumlikAI.",
        .errUpdateLocation: "To install updates, move BrumlikAI to the Applications folder and open it from there.",
        .settingsInputDevice: "Microphone input: %@",

        .guideUpdateNoteTitle: "Updating without an Apple Developer account",
        .guideUpdateNote: "BrumlikAI isn't signed with an Apple Developer ID. When you install a new version, macOS may block the first launch — open System Settings → Privacy & Security and click Open Anyway. It may also ask for some permissions again, or show them as allowed even though they don't work: then turn BrumlikAI off and on again in that list in System Settings (or remove it with − and add it back) and run Test here.",

        .onboardingGuideTitle: "How to use it",
        .onboardingGuideBody: """
        1. Pair your iPhone with this Mac — enable “Allow calls on other devices” (iPhone Settings → Phone → Calls on Other Devices).
        2. When a call comes in, answer it on the Mac (notification, FaceTime, or Phone app).
        3. BrumlikAI detects the call automatically; a red dot appears in the menu bar. You can also start / stop recording manually from the menu.
        4. When the call ends, BrumlikAI transcribes and summarises it in the background. Click a call in “Recent calls” to see the summary — a ready-to-paste prompt for your AI tool can be turned on in Settings.
        5. Assign each call to a client so you always know who it was with — and so the optional AI prompts include the sites, servers and stack you manage for them.
        6. If a meeting was agreed, BrumlikAI proposes a calendar event — review the time and confirm.
        """,

        .onboardingDoneTitle: "You're ready",
        .onboardingDoneBody: "BrumlikAI now lives in your menu bar. You can change anything in Settings at any time.",
        .onboardingFinish: "Finish",

        .settingsTitle: "Settings",
        .settingsLanguage: "Language",
        .settingsApiToken: "DeepInfra API token",
        .settingsApiReveal: "Show / hide",
        .settingsApiSave: "Save",
        .settingsCalendar: "Default calendar",
        .settingsAutoDetect: "Detect calls automatically",
        .settingsReopenGuide: "Run the setup guide again",
        .settingsConsent: "I inform callers that calls are recorded",
        .settingsLaunchAtLogin: "Start BrumlikAI at login",
        .settingsLaunchAtLoginHint: "The menu-bar icon appears automatically after you log in.",
        .settingsRole: "Your work for clients",
        .settingsRoleHelp: "Helps BrumlikAI focus the summaries (and AI prompts, if turned on) on your field.",
        .settingsRemindersList: "Default Reminders list",

        .chunkingProgress: "Processing long recording — chunk %d of %d…",
        .chunkingFailed: "Chunked upload failed",

        .tasksTitle: "To-dos from the call",
        .tasksEmpty: "No action items detected.",
        .tasksAddToReminders: "Add to Reminders",
        .tasksAdded: "Added ✓",
        .tasksDue: "Due",
        .tasksList: "Reminders list",

        .meetingEdit: "Edit",
        .meetingSaveEdit: "Save & add to Calendar",
        .meetingTitleField: "Title",
        .meetingStartField: "Starts",
        .meetingDurationField: "Duration",
        .meetingLocationField: "Location",
        .meetingNotesField: "Notes",
        .meetingDurationMinutes: "min",

        .searchPlaceholder: "Search calls, clients, transcripts…",
        .searchNoResults: "No calls match your search.",

        .recordingsTitle: "Recent calls",
        .recordingsEmpty: "No calls yet. BrumlikAI will show them here after each call ends.",
        .recordingProcessing: "Processing…",
        .recordingSummary: "Summary",
        .recordingRequests: "Client requests",
        .recordingMeeting: "Proposed meeting",
        .recordingAddToCalendar: "Add to Calendar",
        .recordingAdded: "Added to Calendar",
        .recordingTranscriptToggle: "Show full transcript",
        .recordingDelete: "Delete",
        .recordingOpenDetail: "Open detail",

        .detailTitle: "Call detail",
        .detailClient: "Client",
        .detailAssignClient: "Assign client",
        .detailUnassigned: "— unassigned —",
        .detailHumanSummary: "Summary for you",
        .detailHumanSummaryHint: "Everything the call actually contained, no invention.",
        .detailAiPrompt: "Prompt for your AI",
        .detailAiPromptHint: "Ready to paste into Claude / Cursor / another AI tool.",
        .detailCopy: "Copy",
        .detailCopied: "Copied ✓",
        .detailRegeneratingPrompt: "Regenerating prompt…",
        .detailTranscript: "Full transcript",
        .detailMetadata: "Metadata",
        .detailDuration: "Duration",

        .detailContact: "Contact",
        .detailPhone: "Phone number",
        .detailNoPhone: "No phone number detected",
        .detailEditContact: "Edit contact",
        .detailContactName: "Name",
        .detailContactCompany: "Company",
        .detailContactSave: "Save",
        .detailContactSaveHint: "Saved — future calls from this number will show this name automatically.",
        .detailContactRememberHint: "Changes are saved to your BrumlikAI phonebook — future calls from this number pick them up.",
        .detailContactFromContacts: "from Contacts",
        .detailContactUnknown: "Unknown caller",

        .clientsTitle: "Clients",
        .clientsEmpty: "No clients yet. Add your first one to enrich the AI prompts with their websites, servers and stack.",
        .clientsAdd: "Add client",
        .clientsAddManual: "Manually",
        .clientsAddFromAres: "By company ID (ARES)",
        .clientsAresHint: "Enter the Czech company ID (IČO). BrumlikAI fills in the name and address from the ARES public registry.",
        .clientsIcoPlaceholder: "e.g. 27074358",
        .clientsLookup: "Look up",
        .clientsName: "Company / person name",
        .clientsContact: "Contact person",
        .clientsEmail: "Email",
        .clientsPhone: "Phone",
        .clientsAddress: "Address",
        .clientsNotes: "Notes",
        .clientsAssets: "Managed systems",
        .clientsAddAsset: "Add system",
        .clientsAssetName: "Name",
        .clientsAssetUrl: "URL",
        .clientsAssetServer: "Server / host",
        .clientsAssetTech: "Stack (WordPress, Laravel, …)",
        .clientsAssetNotes: "Notes",
        .clientsAssetCredentials: "Credentials hint (never real password!)",
        .clientsSave: "Save client",
        .clientsDelete: "Delete client",
        .clientsConfirmDelete: "This removes the client and un-links their calls. Continue?",

        .errorTitle: "Something went wrong",
        .errorDismiss: "OK",

        .previous: "Back",
        .next: "Next",
        .cancel: "Cancel",
        .save: "Save",
        .close: "Close",
        .delete: "Delete",
        .edit: "Edit"
    ]

    static let czech: [LocKey: String] = [
        .appName: "BrumlikAI",
        .menuRecord: "Spustit nahrávání",
        .menuStop: "Zastavit nahrávání",
        .menuSettings: "Nastavení…",
        .menuQuit: "Ukončit BrumlikAI",
        .menuHistory: "Poslední hovory",
        .menuClients: "Klienti",
        .statusIdle: "Čeká",
        .statusRecording: "Nahrává se",
        .statusProcessing: "Zpracovává se…",

        .onboardingWelcomeTitle: "Vítej v BrumlikAI",
        .onboardingWelcomeSubtitle: "AI shrnutí tvých telefonních hovorů.",
        .onboardingWelcomeBody: "BrumlikAI sedí v menu baru. Jakmile přijmeš hovor na Macu (přes iPhone Continuity), nahraje ho, přepíše přes DeepInfra, shrne požadavky klienta na webu / appce a pokud dojde ke schůzce, přidá ji do tvého Kalendáře Apple.",
        .onboardingContinue: "Pokračovat",

        .onboardingConsentTitle: "Právní souhlas",
        .onboardingConsentBody: "Nahrávání hovorů podléhá ochraně osobních údajů (GDPR) a často vyžaduje souhlas druhé strany. Vždy jí na začátku hovoru řekni, že hovor nahráváš. Nahrávky zůstávají na tvém Macu, zvuk a přepis se posílají ke zpracování na DeepInfra.",
        .onboardingConsentAck: "Rozumím — druhé straně řeknu, že hovor nahrávám.",

        .onboardingApiTitle: "DeepInfra API token",
        .onboardingApiBody: "BrumlikAI používá DeepInfra pro přepis (Whisper) a shrnutí (Llama). Založ si zdarma účet na deepinfra.com, v dashboardu vygeneruj token a vlož ho níže. Token se uloží do macOS Keychain.",
        .onboardingApiPlaceholder: "sk-…",
        .onboardingApiHelp: "Token najdeš na deepinfra.com → Dashboard → API Keys",

        .onboardingRoleTitle: "Co pro klienty děláš?",
        .onboardingRoleBody: "Popiš svoji práci jednou dvěma větami. BrumlikAI podle toho zaměří shrnutí na to, co je ve tvém oboru důležité — vývojáře webů, grafika a účetního zajímají na stejném hovoru jiné detaily. Ovlivní to i volitelné pokyny pro AI.",
        .onboardingRolePlaceholder: "např. Spravuji WordPress weby a iOS aplikace pro malé firmy…",
        .onboardingRoleHelp: "Kdykoli změníš v Nastavení.",
        .onboardingRoleDefault: "Spravuji klientům weby a mobilní aplikace.",

        .errMissingToken: "Chybí DeepInfra API token. Doplň ho v Nastavení.",
        .errBadResponse: "DeepInfra vrátila chybu %d: %@",
        .errDecodingFailed: "Odpověď DeepInfra se nepodařilo přečíst.",
        .errInvalidURL: "Neplatná URL.",
        .errEmptyTranscript: "Přepis je prázdný — nahrávka nejspíš neobsahuje řeč.",
        .errAudioMissing: "Zvukový soubor k tomuto hovoru chybí.",
        .errNoAudio: "Nahrávka neobsahuje žádný zvuk.",
        .errMixFailed: "Příprava zvuku selhala: %@",
        .errMicUnavailable: "Mikrofon není dostupný. Zkontroluj v průvodci nastavením oprávnění k mikrofonu.",
        .errSystemAudioFailed: "Zachytávání zvuku hovoru selhalo (chyba Core Audio %d).",
        .errFileCreation: "Soubor nahrávky se nepodařilo vytvořit: %@",
        .errAlreadyRecording: "Nahrávání už běží.",
        .errNotRecording: "Žádné nahrávání neběží.",
        .errNothingToRecord: "Nepodařilo se nic nahrát. %@",
        .errInterruptedRecording: "Nahrávání se přerušilo (aplikace se ukončila nebo spadla). Co se stihlo nahrát, můžeš pořád zpracovat.",
        .errInterruptedProcessing: "Zpracování přerušilo ukončení aplikace.",
        .errCalendarNotAuthorized: "BrumlikAI nemá přístup ke kalendářům. Povol ho v průvodci nastavením.",
        .errCalendarInvalidDate: "Čas schůzky se nepodařilo rozpoznat. Uprav schůzku a nastav čas ručně.",
        .errCalendarSaveFailed: "Uložení do Kalendáře selhalo: %@",
        .errRemindersNotAuthorized: "BrumlikAI nemá přístup k Připomínkám. Povol ho v průvodci nastavením.",
        .errRemindersSaveFailed: "Uložení do Připomínek selhalo: %@",

        .warnCallerSilent: "Zvuk druhé strany byl úplně potichu. Otevři průvodce nastavením a otestuj systémový zvuk.",
        .warnMicSilent: "Mikrofon (%@) nahrál jen ticho. Povol v průvodci nastavením přístup k mikrofonu — a pokud tenhle Mac mikrofon nemá (třeba Mac mini), připoj sluchátka s mikrofonem a nastav je jako vstup zvuku.",

        .notifRecordingStarted: "Nahrávání spuštěno",
        .notifSummarised: "Hovor je shrnutý",
        .notifSummarisedMeeting: "Hovor je shrnutý — čeká návrh schůzky",
        .notifMeetingAdded: "Schůzka je v Kalendáři",
        .notifFailed: "Zpracování hovoru selhalo — otevři ho a zkus to znovu.",

        .createdByBrumlik: "Vytvořeno v BrumlikAI",
        .retryButton: "Zkusit znovu",
        .failedTitle: "Zpracování selhalo",
        .audioWarningTitle: "Kontrola zvuku",
        .statusPreparing: "Připravuji zvuk…",
        .statusTranscribing: "Přepisuji…",
        .statusSummarizing: "Shrnuji…",
        .statusFailedShort: "Selhalo",
        .menuSetupIncomplete: "Nastavení není hotové — chybí povinné kroky: %d",
        .menuOpenGuide: "Otevřít průvodce",

        .settingsCallLanguage: "Jazyk hovorů",
        .settingsCallLanguageAuto: "Rozpoznat automaticky",
        .settingsCallLanguageHint: "Použije se pro přepis. Shrnutí se píšou v jazyce aplikace.",
        .settingsShowAIPrompt: "Zobrazovat pokyny pro AI pod shrnutím",
        .settingsShowAIPromptHint: "Ke každému hovoru přidá připravený pokyn pro Claude, Cursor nebo jiný AI nástroj.",
        .settingsOpenGuide: "Průvodce oprávněními a nastavením",
        .settingsDiagnostics: "Diagnostika",
        .settingsTestRecording: "Otestovat nahrávání (5 s)",
        .settingsTestHint: "Během testu pusť nějaký zvuk (třeba video) a řekni pár slov.",
        .settingsTestRunning: "Nahrávám…",
        .settingsTestCaller: "Zvuk druhé strany",
        .settingsTestMic: "Mikrofon",
        .settingsTestOK: "funguje",
        .settingsTestSilent: "ticho",
        .settingsTestNotRecorded: "nenahráno",
        .settingsProcesses: "Aplikace, které právě používají zvuk",
        .settingsProcessesHint: "Během hovoru by aplikace, která ho obsluhuje, měla mít štítek „hovor“ a používat mikrofon. Pokud žádná nemá, automatická detekce nebude fungovat — spusť nahrávání ručně.",
        .settingsRefresh: "Obnovit",
        .settingsCallTag: "hovor",

        .assetWeb: "Web",
        .assetApp: "Aplikace",
        .assetCRM: "CRM",
        .assetServer: "Server",
        .assetOther: "Jiné",

        .guideTitle: "Průvodce nastavením",
        .guideSubtitle: "Vše, co BrumlikAI potřebuje ke správné funkci. Stav se obnoví, když se vrátíš z Nastavení systému.",
        .guideProgress: "Hotovo %d z %d",
        .guideRequired: "Povinné",
        .guideRecommended: "Doporučené",
        .guideStatusAllowed: "Povoleno",
        .guideStatusNotAllowed: "Nepovoleno",
        .guideStatusNotVerified: "Neověřeno",
        .guideStatusChecking: "Ověřuji…",
        .guideStatusWorks: "Funguje",
        .guideStatusNotWorking: "Nefunguje",
        .guideStatusDone: "Hotovo",
        .guideStatusMissing: "Chybí",
        .guideAllow: "Povolit",
        .guideOpenSettings: "Otevřít Nastavení systému",
        .guideTest: "Otestovat",
        .guideHowTo: "Jak na to",
        .guideMarkDone: "Mám hotovo",
        .guideOpenFaceTime: "Otevřít FaceTime",
        .guideCheckToken: "Ověřit token",
        .guideEnterToken: "Zadat token",
        .guideTokenInvalid: "Token nefunguje: %@",

        .guideMicTitle: "Mikrofon",
        .guideMicWhy: "Nahrává tvůj hlas během hovoru. Mac mini, Mac Studio a Mac Pro vestavěný mikrofon nemají — připoj sluchátka s mikrofonem.",
        .guideMicSteps: "1. Klikni na Povolit a potvrď systémový dotaz.\n2. Pokud jsi dřív zvolil Nepovolit: otevři Nastavení systému → Soukromí a zabezpečení → Mikrofon a zapni BrumlikAI.",
        .guideSystemAudioTitle: "Systémový zvuk",
        .guideSystemAudioWhy: "Nahrává hlas druhé strany. Bez něj bude ve shrnutí jen to, co jsi řekl ty.",
        .guideSystemAudioSteps: "1. Klikni na Otestovat — uslyšíš krátký zvuk.\n2. Pokud se macOS zeptá, klikni na Povolit a test spusť znovu.\n3. Když test pořád selhává: Nastavení systému → Soukromí a zabezpečení → nahrávání obrazovky a systémového zvuku → zapni BrumlikAI v části jen pro systémový zvuk (pokud tam chybí, přidej ji tlačítkem +).",
        .guideTokenTitle: "DeepInfra API token",
        .guideTokenWhy: "Potřeba pro přepis a shrnutí.",
        .guideTokenSteps: "1. Založ si účet na deepinfra.com.\n2. V dashboardu otevři API Keys a vytvoř klíč.\n3. Vlož ho v Nastavení BrumlikAI a klikni na Ověřit token.",
        .guideIPhoneTitle: "Hovory z iPhonu na tomto Macu",
        .guideIPhoneWhy: "BrumlikAI nahrává hovory, které vyřizuješ na Macu. Hovor přijatý jen na iPhonu nahrát nejde.",
        .guideIPhoneSteps: "1. iPhone: Nastavení → Telefon → Volání na jiných zařízeních → povol volání a zapni tento Mac.\n2. Mac: otevři FaceTime → Nastavení → zapni hovory z iPhonu.\n3. Obě zařízení: stejný Apple účet, zapnutá Wi-Fi a Bluetooth.\n4. Příchozí hovor přijmi na Macu (oznámení v rohu obrazovky).",
        .guideCalendarTitle: "Kalendáře",
        .guideCalendarWhy: "Ukládá domluvené schůzky do Kalendáře.",
        .guideCalendarSteps: "Klikni na Povolit a zvol plný přístup. Když se nic nestane, zapni BrumlikAI v Nastavení systému → Soukromí a zabezpečení → Kalendáře.",
        .guideRemindersTitle: "Připomínky",
        .guideRemindersWhy: "Ukládá úkoly z hovorů do Připomínek.",
        .guideRemindersSteps: "Klikni na Povolit a zvol plný přístup. Když se nic nestane, zapni BrumlikAI v Nastavení systému → Soukromí a zabezpečení → Připomínky.",
        .guideNotificationsTitle: "Oznámení",
        .guideNotificationsWhy: "Dá vědět, když začne nahrávání a když je hotové shrnutí.",
        .guideNotificationsSteps: "Klikni na Povolit. Když se nic nestane, zapni BrumlikAI v Nastavení systému → Oznámení.",
        .guideContactsTitle: "Kontakty",
        .guideContactsWhy: "Zobrazí jméno volajícího podle tvých kontaktů.",
        .guideContactsSteps: "Klikni na Povolit a potvrď. Když se nic nestane, zapni BrumlikAI v Nastavení systému → Soukromí a zabezpečení → Kontakty.",
        .guideScreenTitle: "Nahrávání obrazovky",
        .guideScreenWhy: "Umožní BrumlikAI přečíst jméno nebo číslo volajícího z okna hovoru. Bez něj jméno doplníš sám.",
        .guideScreenSteps: "1. Klikni na Povolit — macOS ukáže dotaz, který otevře Nastavení systému.\n2. U nahrávání obrazovky a systémového zvuku zapni BrumlikAI.\n3. macOS může chtít BrumlikAI ukončit a znovu otevřít.",
        .updatesTitle: "Aktualizace",
        .updatesCurrentVersion: "Verze %@",
        .updatesAutoCheck: "Automaticky kontrolovat aktualizace",
        .updatesAutoInstall: "Aktualizace instalovat automaticky",
        .updatesAutoInstallHint: "Jen když se zrovna nenahrává ani nezpracovává hovor. BrumlikAI se sama restartuje a otevře průvodce nastavením, abys mohl zkontrolovat oprávnění.",
        .updatesCheckNow: "Zkontrolovat",
        .updatesChecking: "Kontroluji…",
        .updatesUpToDate: "Máš nejnovější verzi.",
        .updatesAvailable: "Je k dispozici BrumlikAI %@.",
        .updatesInstall: "Nainstalovat a restartovat",
        .updatesDownloading: "Stahuji…",
        .updatesInstalling: "Instaluji…",
        .updatesNotConfigured: "Aktualizace nejsou pro toto sestavení nastavené.",
        .updatesReleaseNotes: "Co je nového",
        .errUpdateHTTP: "GitHub vrátil chybu %d.",
        .errUpdateSignature: "Podpis aktualizace nesedí, proto se nenainstalovala.",
        .errUpdateBundle: "Stažená aktualizace není platná novější BrumlikAI.",
        .errUpdateLocation: "Pro instalaci aktualizací přesuň BrumlikAI do složky Aplikace a spusť ji odtud.",
        .settingsInputDevice: "Vstup mikrofonu: %@",

        .guideUpdateNoteTitle: "Aktualizace bez vývojářského účtu Apple",
        .guideUpdateNote: "BrumlikAI není podepsaná vývojářským účtem Apple. Po instalaci nové verze může macOS první spuštění zablokovat — otevři Nastavení systému → Soukromí a zabezpečení a klikni na Přesto otevřít. Může se také znovu ptát na některá oprávnění, případně je ukazovat jako povolená, i když nefungují: pak BrumlikAI v daném seznamu v Nastavení systému vypni a znovu zapni (nebo ji odeber tlačítkem − a přidej znovu) a tady spusť Otestovat.",

        .onboardingGuideTitle: "Jak to používat",
        .onboardingGuideBody: """
        1. Spáruj iPhone s tímto Macem — v Nastavení iPhonu → Telefon → Volání na jiných zařízeních zapni Mac.
        2. Když ti někdo volá, přijmi hovor na Macu (notifikace, FaceTime nebo aplikace Telefon).
        3. BrumlikAI hovor rozpozná automaticky — v menu baru se objeví červená tečka. Nahrávání jde spustit / zastavit i ručně z menu.
        4. Po skončení hovoru BrumlikAI na pozadí přepíše a shrne obsah. Klikem na hovor v „Poslední hovory“ otevřeš shrnutí — připravený pokyn pro tvůj AI nástroj si můžeš zapnout v Nastavení.
        5. Každý hovor přiřaď klientovi, ať víš, s kým byl — volitelné pokyny pro AI pak zahrnou i weby, servery a stack, co mu spravuješ.
        6. Pokud se domluvila schůzka, BrumlikAI navrhne událost v Kalendáři — ty jen potvrdíš čas.
        """,

        .onboardingDoneTitle: "Hotovo",
        .onboardingDoneBody: "BrumlikAI teď bydlí v menu baru. Cokoli můžeš kdykoliv změnit v Nastavení.",
        .onboardingFinish: "Dokončit",

        .settingsTitle: "Nastavení",
        .settingsLanguage: "Jazyk",
        .settingsApiToken: "DeepInfra API token",
        .settingsApiReveal: "Zobrazit / skrýt",
        .settingsApiSave: "Uložit",
        .settingsCalendar: "Výchozí kalendář",
        .settingsAutoDetect: "Rozpoznávat hovory automaticky",
        .settingsReopenGuide: "Spustit průvodce znovu",
        .settingsConsent: "Druhou stranu informuji o nahrávání",
        .settingsLaunchAtLogin: "Spouštět BrumlikAI po přihlášení",
        .settingsLaunchAtLoginHint: "Ikona v menu baru naskočí automaticky po přihlášení do Macu.",
        .settingsRole: "Co pro klienty děláš",
        .settingsRoleHelp: "Pomáhá BrumlikAI zaměřit shrnutí (a pokyny pro AI, pokud jsou zapnuté) na tvůj obor.",
        .settingsRemindersList: "Výchozí seznam Připomínek",

        .chunkingProgress: "Zpracovávám dlouhou nahrávku — část %d z %d…",
        .chunkingFailed: "Odesílání nahrávky po částech selhalo",

        .tasksTitle: "Úkoly z hovoru",
        .tasksEmpty: "Žádné úkoly nebyly rozpoznány.",
        .tasksAddToReminders: "Přidat do Připomínek",
        .tasksAdded: "Přidáno ✓",
        .tasksDue: "Termín",
        .tasksList: "Seznam",

        .meetingEdit: "Upravit",
        .meetingSaveEdit: "Uložit a přidat do Kalendáře",
        .meetingTitleField: "Název",
        .meetingStartField: "Začátek",
        .meetingDurationField: "Délka",
        .meetingLocationField: "Místo",
        .meetingNotesField: "Poznámky",
        .meetingDurationMinutes: "min",

        .searchPlaceholder: "Hledej v hovorech, klientech, přepisu…",
        .searchNoResults: "Žádný hovor neodpovídá hledání.",

        .recordingsTitle: "Poslední hovory",
        .recordingsEmpty: "Zatím žádné hovory. BrumlikAI je sem bude přidávat po skončení každého hovoru.",
        .recordingProcessing: "Zpracovává se…",
        .recordingSummary: "Shrnutí",
        .recordingRequests: "Požadavky klienta",
        .recordingMeeting: "Navržená schůzka",
        .recordingAddToCalendar: "Přidat do Kalendáře",
        .recordingAdded: "Přidáno do Kalendáře",
        .recordingTranscriptToggle: "Zobrazit celý přepis",
        .recordingDelete: "Smazat",
        .recordingOpenDetail: "Otevřít detail",

        .detailTitle: "Detail hovoru",
        .detailClient: "Klient",
        .detailAssignClient: "Přiřadit klienta",
        .detailUnassigned: "— nepřiřazeno —",
        .detailHumanSummary: "Shrnutí pro mě",
        .detailHumanSummaryHint: "Co v hovoru skutečně zaznělo, bez vymýšlení.",
        .detailAiPrompt: "Pokyn pro moji AI",
        .detailAiPromptHint: "Připraveno ke vložení do Claude / Cursoru / jiného AI nástroje.",
        .detailCopy: "Kopírovat",
        .detailCopied: "Zkopírováno ✓",
        .detailRegeneratingPrompt: "Přegenerovávám pokyn…",
        .detailTranscript: "Celý přepis",
        .detailMetadata: "Metadata",
        .detailDuration: "Délka",

        .detailContact: "Kontakt",
        .detailPhone: "Telefonní číslo",
        .detailNoPhone: "Číslo se nepodařilo zjistit",
        .detailEditContact: "Upravit kontakt",
        .detailContactName: "Jméno",
        .detailContactCompany: "Firma",
        .detailContactSave: "Uložit",
        .detailContactSaveHint: "Uloženo — příští hovor z tohoto čísla se rovnou podepíše tímto jménem.",
        .detailContactRememberHint: "Změny se uloží do BrumlikAI telefonního seznamu — další hovory z tohoto čísla už je použijí automaticky.",
        .detailContactFromContacts: "z Kontaktů",
        .detailContactUnknown: "Neznámý volající",

        .clientsTitle: "Klienti",
        .clientsEmpty: "Zatím žádní klienti. Přidej prvního a BrumlikAI pak do pokynů pro AI zapojí jeho weby, servery a stack.",
        .clientsAdd: "Přidat klienta",
        .clientsAddManual: "Ručně",
        .clientsAddFromAres: "Podle IČ (ARES)",
        .clientsAresHint: "Zadej IČO firmy. BrumlikAI dotáhne název a adresu z veřejného registru ARES.",
        .clientsIcoPlaceholder: "např. 27074358",
        .clientsLookup: "Načíst",
        .clientsName: "Název firmy / osoba",
        .clientsContact: "Kontaktní osoba",
        .clientsEmail: "E-mail",
        .clientsPhone: "Telefon",
        .clientsAddress: "Adresa",
        .clientsNotes: "Poznámky",
        .clientsAssets: "Spravované systémy",
        .clientsAddAsset: "Přidat systém",
        .clientsAssetName: "Název",
        .clientsAssetUrl: "URL",
        .clientsAssetServer: "Server / host",
        .clientsAssetTech: "Stack (WordPress, Laravel, …)",
        .clientsAssetNotes: "Poznámky",
        .clientsAssetCredentials: "Nápověda ke přihlášení (nikdy skutečné heslo!)",
        .clientsSave: "Uložit klienta",
        .clientsDelete: "Smazat klienta",
        .clientsConfirmDelete: "Smaže se klient a odpojí se od jeho hovorů. Pokračovat?",

        .errorTitle: "Něco se pokazilo",
        .errorDismiss: "OK",

        .previous: "Zpět",
        .next: "Dál",
        .cancel: "Zrušit",
        .save: "Uložit",
        .close: "Zavřít",
        .delete: "Smazat",
        .edit: "Upravit"
    ]
}

struct LocalizedText: View {
    @EnvironmentObject private var loc: LocalizationManager
    let key: LocKey
    var body: some View { Text(loc.t(key)) }
}
