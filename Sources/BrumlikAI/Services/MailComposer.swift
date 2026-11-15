import AppKit

/// Opens a new, filled-in message in the user's mail app; the user checks it and sends it there.
enum MailComposer {
    @MainActor
    static func open(to recipients: [String], subject: String, body: String) -> Bool {
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = recipients
            service.subject = subject
            if service.canPerform(withItems: [body]) {
                service.perform(withItems: [body])
                return true
            }
        }
        // No Mail account set up: hand the message to whatever handles mailto links.
        guard let url = mailtoURL(to: recipients, subject: subject, body: body) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func mailtoURL(to recipients: [String], subject: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#,")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let to = recipients.map(encode).joined(separator: ",")
        return URL(string: "mailto:\(to)?subject=\(encode(subject))&body=\(encode(body))")
    }
}
