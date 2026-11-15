import XCTest
@testable import BrumlikAI

/// A pretend SMTP server: answers like a real one and records what it was sent.
private final class ScriptedSMTPServer: SMTPTransport {
    var capabilities = ["STARTTLS", "AUTH PLAIN LOGIN"]
    var user = "jan@firma.cz"
    var password = "tajne"

    private(set) var openedWithTLS: Bool?
    private(set) var tlsStarted = false
    private(set) var commands: [String] = []
    private(set) var message = ""
    private var pending = Data()
    private var inData = false
    private var dataBuffer = ""
    private var loginStep = 0

    func open(host: String, port: Int, tls: Bool) async throws {
        openedWithTLS = tls
        reply("220 smtp.test ESMTP")
    }

    func startTLS() async throws { tlsStarted = true }

    func write(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        if inData {
            dataBuffer += text
            if dataBuffer.hasSuffix("\r\n.\r\n") {
                // Bytes, not characters: "\r\n" is a single Character in Swift.
                message = String(decoding: Array(dataBuffer.utf8.dropLast(5)), as: UTF8.self)
                inData = false
                reply("250 2.0.0 Queued")
            }
            return
        }
        let line = text.trimmingCharacters(in: .newlines)
        commands.append(line)
        handle(line)
    }

    func read() async throws -> Data {
        guard !pending.isEmpty else { throw SMTPError.connectionClosed }
        defer { pending = Data() }
        return pending
    }

    func close() {}

    private func reply(_ text: String) { pending.append(Data((text + "\r\n").utf8)) }

    private func decoded(_ base64: String) -> String { String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self) }

    private func handle(_ line: String) {
        switch loginStep {
        case 1:
            loginStep = 2
            return reply(decoded(line) == user ? "334 UGFzc3dvcmQ6" : "535 5.7.8 Bad user")
        case 2:
            loginStep = 0
            return reply(decoded(line) == password ? "235 2.7.0 OK" : "535 5.7.8 Authentication failed")
        default:
            break
        }
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") {
            let lines = ["smtp.test"] + (tlsStarted ? capabilities.filter { $0 != "STARTTLS" } : capabilities)
            for (index, text) in lines.enumerated() {
                reply("250\(index == lines.count - 1 ? " " : "-")\(text)")
            }
        } else if upper == "STARTTLS" {
            reply("220 2.0.0 Ready")
        } else if upper.hasPrefix("AUTH PLAIN ") {
            let expected = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
            reply(line.dropFirst("AUTH PLAIN ".count) == expected ? "235 2.7.0 OK" : "535 5.7.8 Authentication failed")
        } else if upper == "AUTH LOGIN" {
            loginStep = 1
            reply("334 VXNlcm5hbWU6")
        } else if upper.hasPrefix("MAIL FROM:") || upper.hasPrefix("RCPT TO:") {
            reply("250 2.1.0 OK")
        } else if upper == "DATA" {
            inData = true
            dataBuffer = ""
            reply("354 Go ahead")
        } else if upper == "QUIT" {
            reply("221 Bye")
        } else {
            reply("500 Unknown command")
        }
    }
}

final class EmailTests: XCTestCase {
    private func settings(_ security: SMTPSettings.Security = .startTLS) -> SMTPSettings {
        var settings = SMTPSettings()
        settings.host = "smtp.test"
        settings.security = security
        settings.port = security.defaultPort
        settings.username = "jan@firma.cz"
        settings.fromName = "Jan Novák"
        settings.fromAddress = "jan@firma.cz"
        return settings
    }

    private let email = OutgoingEmail(
        fromName: "Jan Novák",
        fromAddress: "jan@firma.cz",
        to: ["klient@example.com"],
        bcc: ["jan@firma.cz"],
        subject: "Shrnutí našeho telefonátu – nový e-shop a doména",
        body: "Dobrý den,\n.tečka na začátku řádku\nS pozdravem"
    )

    private func decodeWords(_ header: String) -> String {
        let bytes = header.components(separatedBy: "\r\n ").flatMap { word -> [UInt8] in
            let base64 = word.replacingOccurrences(of: "=?UTF-8?B?", with: "").replacingOccurrences(of: "?=", with: "")
            return [UInt8](Data(base64Encoded: base64) ?? Data())
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parts(of message: String) -> (headers: [String: String], body: String) {
        let split = message.components(separatedBy: "\r\n\r\n")
        var headers: [String: String] = [:]
        var lastKey = ""
        for line in split[0].components(separatedBy: "\r\n") {
            if line.hasPrefix(" "), !lastKey.isEmpty {
                headers[lastKey, default: ""] += "\r\n" + line
            } else if let colon = line.firstIndex(of: ":") {
                lastKey = String(line[..<colon])
                headers[lastKey] = String(line[line.index(colon, offsetBy: 2)...])
            }
        }
        let body = Data(base64Encoded: split.dropFirst().joined(separator: "\r\n\r\n").replacingOccurrences(of: "\r\n", with: "")) ?? Data()
        return (headers, String(decoding: body, as: UTF8.self))
    }

    // MARK: - SMTP conversation

    func testSendsOverSTARTTLSWithPlainSignIn() async throws {
        let server = ScriptedSMTPServer()
        try await SMTPClient(settings: settings(), password: "tajne", makeTransport: { server }).send(email)

        XCTAssertEqual(server.openedWithTLS, false)
        XCTAssertTrue(server.tlsStarted)
        let verbs = server.commands.map { String($0.split(separator: " ").first ?? "") }
        XCTAssertEqual(verbs, ["EHLO", "STARTTLS", "EHLO", "AUTH", "MAIL", "RCPT", "RCPT", "DATA", "QUIT"])
        XCTAssertTrue(server.commands.contains("RCPT TO:<klient@example.com>"))
        XCTAssertTrue(server.commands.contains("RCPT TO:<jan@firma.cz>"), "the blind copy is delivered")

        let (headers, body) = parts(of: server.message)
        XCTAssertNil(headers["Bcc"], "the blind copy isn't listed")
        XCTAssertEqual(headers["To"], "klient@example.com")
        XCTAssertEqual(decodeWords(try XCTUnwrap(headers["Subject"])), email.subject)
        XCTAssertEqual(decodeWords(try XCTUnwrap(headers["From"]).replacingOccurrences(of: " <jan@firma.cz>", with: "")), "Jan Novák")
        XCTAssertEqual(body, "Dobrý den,\r\n.tečka na začátku řádku\r\nS pozdravem")
    }

    func testSSLWithLoginSignIn() async throws {
        let server = ScriptedSMTPServer()
        server.capabilities = ["AUTH LOGIN"]
        try await SMTPClient(settings: settings(.ssl), password: "tajne", makeTransport: { server }).send(email)
        XCTAssertEqual(server.openedWithTLS, true)
        XCTAssertFalse(server.tlsStarted)
        XCTAssertTrue(server.commands.contains("AUTH LOGIN"))
        XCTAssertFalse(server.message.isEmpty)
    }

    func testNeverSignsInWithoutEncryption() async {
        let server = ScriptedSMTPServer()
        server.capabilities = ["AUTH PLAIN LOGIN"]
        do {
            try await SMTPClient(settings: settings(.startTLS), password: "tajne", makeTransport: { server }).send(email)
            XCTFail("Should refuse a server without STARTTLS")
        } catch {
            XCTAssertEqual(error as? SMTPError, .startTLSUnavailable)
        }
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("AUTH") }, "the password must never go out unencrypted")
    }

    func testWrongPasswordIsReportedAndNothingIsSent() async {
        let server = ScriptedSMTPServer()
        do {
            try await SMTPClient(settings: settings(), password: "spatne", makeTransport: { server }).send(email)
            XCTFail("Should fail to sign in")
        } catch let error as SMTPError {
            guard case .authFailed = error else { return XCTFail("Unexpected \(error)") }
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("MAIL") })
    }

    func testTestConnectionSendsNothing() async throws {
        let server = ScriptedSMTPServer()
        try await SMTPClient(settings: settings(), password: "tajne", makeTransport: { server }).verify()
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("MAIL") || $0 == "DATA" })
        XCTAssertEqual(server.commands.last, "QUIT")
    }

    func testBadAddressesStopBeforeConnecting() async {
        let server = ScriptedSMTPServer()
        var bad = email
        bad.to = ["klient@example.com>\r\nRCPT TO:<evil@example.com"]
        do {
            try await SMTPClient(settings: settings(), password: "tajne", makeTransport: { server }).send(bad)
            XCTFail("Should refuse the address")
        } catch {
            XCTAssertEqual(error as? SMTPError, .invalidAddress(bad.to[0]))
        }
        XCTAssertNil(server.openedWithTLS, "no connection was opened")
    }

    // MARK: - Message

    func testHeadersCannotBeInjected() {
        var tricky = email
        tricky.subject = "Ahoj\r\nBcc: evil@example.com"
        tricky.fromName = "Jan\nX-Evil: 1"
        let message = SMTPMessage.render(tricky, date: Date(), messageID: "id@firma.cz")
        let headerLines = message.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        XCTAssertFalse(headerLines.contains { $0.hasPrefix("Bcc:") || $0.hasPrefix("X-Evil:") })
    }

    func testLongCzechSubjectBecomesShortEncodedWords() {
        let subject = "Shrnutí našeho telefonátu – nový e-shop, doména a termín spuštění před Vánocemi"
        let encoded = SMTPMessage.encodedHeader(subject)
        let words = encoded.components(separatedBy: "\r\n ")
        XCTAssertGreaterThan(words.count, 1)
        XCTAssertTrue(words.allSatisfy { $0.count <= 75 && $0.hasPrefix("=?UTF-8?B?") && $0.hasSuffix("?=") })
        XCTAssertEqual(decodeWords(encoded), subject)
        XCTAssertEqual(SMTPMessage.encodedHeader("Hello"), "Hello")
    }

    func testSenderNames() {
        XCTAssertEqual(SMTPMessage.mailbox(name: "Jan Novak", address: "a@b.cz"), "Jan Novak <a@b.cz>")
        XCTAssertEqual(SMTPMessage.mailbox(name: "Novak, s.r.o.", address: "a@b.cz"), "\"Novak, s.r.o.\" <a@b.cz>")
        XCTAssertTrue(SMTPMessage.mailbox(name: "Jan Novák", address: "a@b.cz").hasPrefix("=?UTF-8?B?"))
        XCTAssertEqual(SMTPMessage.mailbox(name: " ", address: "a@b.cz"), "a@b.cz")
    }

    func testDotStuffing() {
        XCTAssertEqual(SMTPMessage.dotStuffed("a\r\n.b\r\n..c"), "a\r\n..b\r\n...c")
    }

    func testAuthMechanismsAreRead() {
        XCTAssertEqual(SMTPClient.mechanisms(in: ["AUTH PLAIN LOGIN XOAUTH2", "SIZE 100"]), ["PLAIN", "LOGIN", "XOAUTH2"])
        XCTAssertEqual(SMTPClient.mechanisms(in: ["AUTH=LOGIN"]), ["LOGIN"])
    }

    // MARK: - Settings and addresses

    func testAddresses() {
        XCTAssertEqual(EmailAddress.list(" a@b.cz, c@d.cz;e@f.cz \n"), ["a@b.cz", "c@d.cz", "e@f.cz"])
        XCTAssertTrue(EmailAddress.isValid("jan.novak+crm@firma.cz"))
        for bad in ["", "jan", "jan@", "@firma.cz", "jan@firma", "jan novak@firma.cz", "jan@firma.cz>", "a@b.cz\r\nX: y", "jan@.cz"] {
            XCTAssertFalse(EmailAddress.isValid(bad), bad)
        }
    }

    func testSMTPSettings() throws {
        var settings = SMTPSettings()
        XCTAssertFalse(settings.isComplete)
        settings.host = "smtp.firma.cz"
        settings.username = "jan@firma.cz"
        XCTAssertTrue(settings.isComplete)
        XCTAssertEqual(settings.senderAddress, "jan@firma.cz")
        settings.fromAddress = " obchod@firma.cz "
        XCTAssertEqual(settings.senderAddress, "obchod@firma.cz")
        settings.port = 0
        XCTAssertFalse(settings.isComplete)

        let saved = try JSONDecoder().decode(SMTPSettings.self, from: Data(#"{"host":"smtp.x.cz","security":"startTLS"}"#.utf8))
        XCTAssertEqual(saved.port, 587)
        XCTAssertTrue(saved.bccSelf)
    }

    func testMailtoKeepsSpecialCharacters() throws {
        let url = try XCTUnwrap(MailComposer.mailtoURL(to: ["a+b@c.cz"], subject: "Nabídka & cena", body: "1 + 1 = 2\nDěkuji"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "subject" }?.value, "Nabídka & cena")
        XCTAssertEqual(items.first { $0.name == "body" }?.value, "1 + 1 = 2\nDěkuji")
    }
}
