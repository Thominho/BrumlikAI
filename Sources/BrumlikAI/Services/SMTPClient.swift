import Foundation

enum SMTPError: LocalizedError, Equatable {
    case notConfigured
    case noRecipient
    case invalidAddress(String)
    case connectionClosed
    case startTLSUnavailable
    case authUnsupported
    case authFailed(String)
    case rejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.t(.errSMTPNotConfigured)
        case .noRecipient: return L10n.t(.emailNoRecipient)
        case .invalidAddress(let address): return L10n.f(.errSMTPInvalidAddress, address)
        case .connectionClosed: return L10n.t(.errSMTPClosed)
        case .startTLSUnavailable: return L10n.t(.errSMTPNoStartTLS)
        case .authUnsupported: return L10n.t(.errSMTPAuthUnsupported)
        case .authFailed(let message): return L10n.f(.errSMTPAuthFailed, message)
        case .rejected(let code, let message): return L10n.f(.errSMTPRejected, code, message)
        }
    }
}

struct SMTPReply: Equatable {
    let code: Int
    /// The text of each line, without the code.
    let lines: [String]
    var text: String { lines.joined(separator: " ") }
}

/// The byte stream SMTP talks over: a URLSession stream task in the app, a script in tests.
protocol SMTPTransport: AnyObject {
    func open(host: String, port: Int, tls: Bool) async throws
    /// Switches the open connection to TLS (after STARTTLS).
    func startTLS() async throws
    func write(_ data: Data) async throws
    /// The next bytes from the server; throws when the connection is gone.
    func read() async throws -> Data
    func close()
}

struct OutgoingEmail: Equatable {
    var fromName: String
    var fromAddress: String
    var to: [String]
    /// Blind copies: delivered, but not listed in the message.
    var bcc: [String]
    var subject: String
    var body: String
}

/// A small SMTP client: always encrypted (SSL/TLS or STARTTLS, never plain), password sign-in with AUTH PLAIN
/// or LOGIN, one message per connection.
final class SMTPClient {
    private let settings: SMTPSettings
    private let password: String
    private let makeTransport: () -> SMTPTransport
    private var transport: SMTPTransport?
    private var buffer = Data()

    /// Sent with EHLO; an address literal every server accepts.
    private static let clientName = "[127.0.0.1]"

    init(settings: SMTPSettings, password: String, makeTransport: @escaping () -> SMTPTransport = { StreamTaskTransport() }) {
        self.settings = settings
        self.password = password
        self.makeTransport = makeTransport
    }

    /// Connects and signs in, then quits — checks the settings without sending anything.
    func verify() async throws {
        try await session {}
    }

    func send(_ email: OutgoingEmail) async throws {
        for address in [email.fromAddress] + email.to + email.bcc where !EmailAddress.isValid(address) {
            throw SMTPError.invalidAddress(address)
        }
        guard !email.to.isEmpty else { throw SMTPError.noRecipient }
        try await session {
            try await self.command("MAIL FROM:<\(email.fromAddress)>", expect: [250])
            for recipient in email.to + email.bcc {
                try await self.command("RCPT TO:<\(recipient)>", expect: [250, 251])
            }
            try await self.command("DATA", expect: [354])
            let message = SMTPMessage.render(email, date: Date(), messageID: SMTPMessage.messageID(for: email.fromAddress))
            try await self.write(SMTPMessage.dotStuffed(message) + "\r\n.\r\n")
            try self.check(try await self.readReply(), expect: [250])
        }
    }

    // MARK: - Session

    private func session(_ work: () async throws -> Void) async throws {
        let transport = makeTransport()
        self.transport = transport
        buffer = Data()
        defer {
            transport.close()
            self.transport = nil
        }

        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await transport.open(host: host, port: settings.port, tls: settings.security == .ssl)
        try check(try await readReply(), expect: [220])
        var capabilities = try await hello()
        if settings.security == .startTLS {
            // Never fall back to an unencrypted connection.
            guard capabilities.contains("STARTTLS") else { throw SMTPError.startTLSUnavailable }
            try await command("STARTTLS", expect: [220])
            try await transport.startTLS()
            buffer = Data()
            capabilities = try await hello()
        }
        if settings.username.nonEmpty != nil {
            try await authenticate(Self.mechanisms(in: capabilities))
        }
        try await work()
        _ = try? await command("QUIT")
    }

    /// EHLO; returns the server's extensions in upper case ("STARTTLS", "AUTH PLAIN LOGIN", …).
    private func hello() async throws -> Set<String> {
        let reply = try await command("EHLO \(Self.clientName)", expect: [250])
        return Set(reply.lines.dropFirst().map { $0.uppercased().trimmingCharacters(in: .whitespaces) })
    }

    /// The sign-in methods the server offers, from "AUTH PLAIN LOGIN" (or the old "AUTH=PLAIN").
    static func mechanisms(in capabilities: Set<String>) -> Set<String> {
        var result = Set<String>()
        for line in capabilities where line.hasPrefix("AUTH") {
            for name in line.dropFirst(4).split(whereSeparator: { $0 == " " || $0 == "=" }) {
                result.insert(String(name))
            }
        }
        return result
    }

    private func authenticate(_ mechanisms: Set<String>) async throws {
        let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if mechanisms.contains("PLAIN") {
            let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
            try checkSignIn(try await command("AUTH PLAIN \(token)"))
        } else if mechanisms.contains("LOGIN") {
            try await command("AUTH LOGIN", expect: [334])
            let afterUser = try await command(Data(user.utf8).base64EncodedString())
            guard afterUser.code == 334 else { return try checkSignIn(afterUser) }
            try checkSignIn(try await command(Data(password.utf8).base64EncodedString()))
        } else {
            throw SMTPError.authUnsupported
        }
    }

    private func checkSignIn(_ reply: SMTPReply) throws {
        guard reply.code != 235 else { return }
        if reply.code == 535 || reply.code == 534 || reply.code == 454 {
            throw SMTPError.authFailed("\(reply.code) \(reply.text)")
        }
        throw SMTPError.rejected(code: reply.code, message: reply.text)
    }

    // MARK: - Wire

    @discardableResult
    private func command(_ line: String, expect codes: Set<Int>? = nil) async throws -> SMTPReply {
        try await write(line + "\r\n")
        let reply = try await readReply()
        if let codes { try check(reply, expect: codes) }
        return reply
    }

    private func check(_ reply: SMTPReply, expect codes: Set<Int>) throws {
        guard codes.contains(reply.code) else { throw SMTPError.rejected(code: reply.code, message: reply.text) }
    }

    private func write(_ text: String) async throws {
        guard let transport else { throw SMTPError.connectionClosed }
        try await transport.write(Data(text.utf8))
    }

    /// One reply, which may span several lines ("250-…" up to "250 …").
    private func readReply() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError.rejected(code: 0, message: line)
            }
            let rest = line.dropFirst(3)
            lines.append(String(rest.dropFirst()))
            if rest.first != "-" { return SMTPReply(code: code, lines: lines) }
        }
    }

    private func readLine() async throws -> String {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard let transport, buffer.count < 1_000_000 else { throw SMTPError.connectionClosed }
            buffer.append(try await transport.read())
        }
    }
}

/// Builds the message text sent after DATA.
enum SMTPMessage {
    static func render(_ email: OutgoingEmail, date: Date, messageID: String) -> String {
        let headers = [
            "Date: \(rfc5322Date(date))",
            "From: \(mailbox(name: email.fromName, address: email.fromAddress))",
            "To: \(email.to.joined(separator: ", "))",
            "Subject: \(encodedHeader(email.subject))",
            "Message-ID: <\(messageID)>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "X-Mailer: BrumlikAI"
        ]
        let body = Data(crlf(email.body).utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    /// Lines starting with a dot get another one, so the server doesn't read them as the end of the message.
    static func dotStuffed(_ message: String) -> String {
        message.components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
    }

    static func messageID(for sender: String) -> String {
        let domain = sender.split(separator: "@").last.map(String.init) ?? "brumlikai.local"
        return "\(UUID().uuidString)@\(domain)"
    }

    /// A header value as is when it's short plain ASCII, otherwise as RFC 2047 encoded words.
    static func encodedHeader(_ raw: String) -> String {
        let text = singleLine(raw)
        if text.count <= 70, text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return text }
        func word(_ part: String) -> String { "=?UTF-8?B?" + Data(part.utf8).base64EncodedString() + "?=" }
        // At most 45 bytes per word (60 Base64 characters), cut between characters, never inside one.
        var words: [String] = []
        var part = ""
        for character in text {
            if !part.isEmpty, (part + String(character)).utf8.count > 45 {
                words.append(word(part))
                part = ""
            }
            part.append(character)
        }
        if !part.isEmpty { words.append(word(part)) }
        return words.joined(separator: "\r\n ")
    }

    static func mailbox(name rawName: String, address: String) -> String {
        let name = singleLine(rawName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return address }
        let display: String
        if name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }) {
            display = name
        } else if name.unicodeScalars.allSatisfy(\.isASCII) {
            display = "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            display = encodedHeader(name)
        }
        return "\(display) <\(address)>"
    }

    /// Header values never contain line breaks — that would let text inject extra headers.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

/// SMTP over a URLSession stream task, which can switch an open connection to TLS for STARTTLS.
/// The server's certificate is checked against the host name.
final class StreamTaskTransport: SMTPTransport {
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionStreamTask?
    private let timeout: TimeInterval = 30

    func open(host: String, port: Int, tls: Bool) async throws {
        let task = session.streamTask(withHostName: host, port: port)
        self.task = task
        task.resume()
        if tls { task.startSecureConnection() }
    }

    func startTLS() async throws {
        guard let task else { throw SMTPError.connectionClosed }
        task.startSecureConnection()
    }

    func write(_ data: Data) async throws {
        guard let task else { throw SMTPError.connectionClosed }
        try await task.write(data, timeout: timeout)
    }

    func read() async throws -> Data {
        guard let task else { throw SMTPError.connectionClosed }
        let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: timeout)
        if let data, !data.isEmpty { return data }
        if atEOF { throw SMTPError.connectionClosed }
        return Data()
    }

    func close() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }
}
