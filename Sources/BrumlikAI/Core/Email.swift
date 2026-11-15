import Foundation

/// How follow-up emails leave the Mac.
enum EmailTransport: String, CaseIterable, Identifiable {
    /// Opens the email in Apple Mail, where the user checks it and sends it.
    case mail
    /// Sends it straight from BrumlikAI through the user's own SMTP server.
    case smtp

    var id: String { rawValue }
}

/// The user's SMTP server. The password is kept in the Keychain, never here.
struct SMTPSettings: Codable, Equatable {
    enum Security: String, Codable, CaseIterable, Identifiable {
        /// Encrypted from the first byte, usually port 465.
        case ssl
        /// Starts plain and switches to encryption with STARTTLS, usually port 587. Never stays unencrypted.
        case startTLS

        var id: String { rawValue }
        var defaultPort: Int { self == .ssl ? 465 : 587 }
        var title: String { self == .ssl ? "SSL/TLS" : "STARTTLS" }
    }

    var host = ""
    var port = 465
    var security: Security = .ssl
    var username = ""
    var fromName = ""
    var fromAddress = ""
    /// A blind copy to the sender, because mail sent over SMTP doesn't land in the Sent folder.
    var bccSelf = true

    init() {}

    enum CodingKeys: String, CodingKey { case host, port, security, username, fromName, fromAddress, bccSelf }

    /// Lenient, so settings saved by another version still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? container.decodeIfPresent(String.self, forKey: .host)) ?? ""
        security = (try? container.decodeIfPresent(Security.self, forKey: .security)) ?? .ssl
        port = (try? container.decodeIfPresent(Int.self, forKey: .port)) ?? security.defaultPort
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        fromName = (try? container.decodeIfPresent(String.self, forKey: .fromName)) ?? ""
        fromAddress = (try? container.decodeIfPresent(String.self, forKey: .fromAddress)) ?? ""
        bccSelf = (try? container.decodeIfPresent(Bool.self, forKey: .bccSelf)) ?? true
    }

    /// The From address: the one filled in, or the username when that's an address.
    var senderAddress: String {
        fromAddress.nonEmpty ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isComplete: Bool {
        host.nonEmpty != nil && (1...65_535).contains(port) && EmailAddress.isValid(senderAddress)
    }
}

/// A follow-up email for a call: written by the AI, then edited by the user.
struct EmailDraft: Codable, Equatable {
    var to: String
    var subject: String
    var body: String
    var createdAt: Date
    /// Set when BrumlikAI sent it over SMTP.
    var sentAt: Date?
    var sentTo: String?
}

enum EmailAddress {
    /// "a@b.cz, c@d.cz; e@f.cz" → the separate addresses.
    static func list(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A plain address — something@domain.tld, no names, spaces or brackets.
    static func isValid(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "<>()[],;:\\\""))
        return address.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

enum FollowUpError: LocalizedError {
    case noSummary

    var errorDescription: String? {
        switch self {
        case .noSummary: return L10n.t(.errNoSummary)
        }
    }
}

extension String {
    /// The text without surrounding whitespace, or nil when nothing is left.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// The trimmed text, or nil when it's missing or blank.
    var nonEmpty: String? { self?.nonEmpty }
}
