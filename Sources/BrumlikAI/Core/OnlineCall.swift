import Foundation

/// A call on the Mac rather than on the phone: Google Meet or WhatsApp — in Chrome, or in the WhatsApp app.
struct OnlineCall: Codable, Equatable {
    enum Service: String, Codable {
        case meet
        case whatsapp
    }

    /// The app that plays and captures the call audio.
    enum App: String, Codable {
        case chrome
        case whatsapp
    }

    var service: Service
    var app: App
    /// The meeting's name, when the window shows one instead of the code.
    var title: String?
    /// The Google Meet code ("abc-defg-hij"). Every meeting of a recurring event has the same one.
    var meetingCode: String?

    init(service: Service, app: App, title: String? = nil, meetingCode: String? = nil) {
        self.service = service
        self.app = app
        self.title = title.nonEmpty
        self.meetingCode = meetingCode.nonEmpty?.lowercased()
    }

    var serviceName: String {
        switch service {
        case .meet: return "Google Meet"
        case .whatsapp: return "WhatsApp"
        }
    }

    /// The name shown for the call: the meeting's name, or the service.
    var displayTitle: String { title ?? serviceName }
    /// What's shown under it: the service when the meeting has a name, otherwise the meeting code.
    var displaySubtitle: String? { title == nil ? meetingCode : serviceName }
    /// The service and the meeting code on one line, e.g. "Google Meet · abc-defg-hij".
    var detail: String { [serviceName, meetingCode].compactMap { $0 }.joined(separator: " · ") }

    var symbol: String {
        switch service {
        case .meet: return "video.fill"
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        }
    }

    /// The bundle IDs of the app's processes that carry the call audio start with this.
    var appBundlePrefix: String {
        switch app {
        case .chrome: return OnlineCallApps.chrome
        case .whatsapp: return OnlineCallApps.whatsApp
        }
    }
}

/// The apps BrumlikAI watches for Meet and WhatsApp calls, as bundle ID prefixes.
enum OnlineCallApps {
    /// Chrome and its helper processes (com.google.Chrome, com.google.Chrome.helper, Beta, Canary).
    static let chrome = "com.google.Chrome"
    /// The WhatsApp app for Mac and WhatsApp Business.
    static let whatsApp = "net.whatsapp."

    static func contains(bundleID: String) -> Bool {
        bundleID.hasPrefix(chrome) || bundleID.hasPrefix(whatsApp)
    }
}

/// Tells a Google Meet or WhatsApp call from the titles of Chrome's windows.
enum OnlineCallRecognizer {
    private static let codePattern = "[a-z]{3}-[a-z]{4}-[a-z]{3}"

    /// `titles` go front to back. A Meet meeting wins over WhatsApp, which people often just leave open in a tab;
    /// the bare Meet start page comes last.
    static func recognize(chromeTitles titles: [String]) -> OnlineCall? {
        var whatsapp: OnlineCall?
        var startPage: OnlineCall?
        for title in titles {
            if let meet = meet(from: title) {
                if meet.meetingCode != nil || meet.title != nil { return meet }
                if startPage == nil { startPage = meet }
            } else if whatsapp == nil, isWhatsApp(title) {
                whatsapp = OnlineCall(service: .whatsapp, app: .chrome)
            }
        }
        return whatsapp ?? startPage
    }

    /// "Meet - abc-defg-hij", "Meet – Weekly sync", "Weekly sync - Google Meet", "Google Meet".
    static func meet(from raw: String) -> OnlineCall? {
        let title = cleaned(raw)
        let rest: Substring
        if title.caseInsensitiveCompare("Google Meet") == .orderedSame || title.caseInsensitiveCompare("Meet") == .orderedSame {
            rest = ""
        } else if let prefix = title.range(of: #"^(Google )?Meet\s*[-–—:|]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            rest = title[prefix.upperBound...]
        } else if let suffix = title.range(of: #"\s*[-–—|]\s*(Google )?Meet$"#, options: [.regularExpression, .caseInsensitive]) {
            rest = title[..<suffix.lowerBound]
        } else {
            return nil
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        if name.range(of: "^\(codePattern)$", options: [.regularExpression, .caseInsensitive]) != nil {
            return OnlineCall(service: .meet, app: .chrome, meetingCode: name)
        }
        let code = name.range(of: #"\b"# + codePattern + #"\b"#, options: .regularExpression).map { String(name[$0]) }
        return OnlineCall(service: .meet, app: .chrome, title: name, meetingCode: code)
    }

    /// "WhatsApp", "(3) WhatsApp", "WhatsApp Business".
    static func isWhatsApp(_ raw: String) -> Bool {
        cleaned(raw).range(of: #"^(\(\d+\)\s*)?WhatsApp\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Drops what Chrome may add after the page title ("… - Google Chrome - Work").
    static func cleaned(_ title: String) -> String {
        var title = title
        if let suffix = title.range(of: #"\s+[-–—]\s+Google Chrome\b.*$"#, options: .regularExpression) {
            title = String(title[..<suffix.lowerBound])
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
