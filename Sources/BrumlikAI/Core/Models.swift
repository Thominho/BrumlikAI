import Foundation

// MARK: - Client

struct Client: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var ico: String?
    var dic: String?
    var address: String?
    var contactPerson: String?
    var email: String?
    var phone: String?
    var notes: String?
    var assets: [ManagedAsset]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        ico: String? = nil,
        dic: String? = nil,
        address: String? = nil,
        contactPerson: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        notes: String? = nil,
        assets: [ManagedAsset] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.ico = ico
        self.dic = dic
        self.address = address
        self.contactPerson = contactPerson
        self.email = email
        self.phone = phone
        self.notes = notes
        self.assets = assets
        self.createdAt = createdAt
    }

    /// What the LLM is told about the client and the systems managed for them. Credential hints are never included.
    func aiContext() -> String {
        var lines = ["Client: \(name)"]
        if let ico, !ico.isEmpty { lines.append("Company ID (IČO): \(ico)") }
        if let email, !email.isEmpty { lines.append("Email: \(email)") }
        if let phone, !phone.isEmpty { lines.append("Phone: \(phone)") }
        if let contactPerson, !contactPerson.isEmpty { lines.append("Contact person: \(contactPerson)") }
        if !assets.isEmpty {
            lines.append("Systems managed for this client:")
            for asset in assets {
                var line = "  - \(asset.kind.promptName): \(asset.name)"
                if let url = asset.url, !url.isEmpty { line += " (\(url))" }
                if let server = asset.server, !server.isEmpty { line += ", server \(server)" }
                if let technology = asset.technology, !technology.isEmpty { line += ", stack \(technology)" }
                lines.append(line)
                if let notes = asset.notes, !notes.isEmpty { lines.append("    Notes: \(notes)") }
            }
        }
        if let notes, !notes.isEmpty { lines.append("Notes about the client: \(notes)") }
        return lines.joined(separator: "\n")
    }
}

struct ManagedAsset: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: AssetKind
    var name: String
    var url: String?
    var server: String?
    var technology: String?
    var credentialsHint: String?
    var notes: String?

    init(
        id: UUID = UUID(),
        kind: AssetKind = .website,
        name: String,
        url: String? = nil,
        server: String? = nil,
        technology: String? = nil,
        credentialsHint: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.server = server
        self.technology = technology
        self.credentialsHint = credentialsHint
        self.notes = notes
    }
}

enum AssetKind: String, Codable, CaseIterable, Identifiable {
    case website = "web"
    case app = "app"
    case crm = "CRM"
    case server = "server"
    case other = "jiné"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .website: return "globe"
        case .app: return "iphone"
        case .crm: return "person.2.fill"
        case .server: return "server.rack"
        case .other: return "square.stack.3d.up"
        }
    }

    var label: LocKey {
        switch self {
        case .website: return .assetWeb
        case .app: return .assetApp
        case .crm: return .assetCRM
        case .server: return .assetServer
        case .other: return .assetOther
        }
    }

    var promptName: String {
        switch self {
        case .website: return "website"
        case .app: return "app"
        case .crm: return "CRM"
        case .server: return "server"
        case .other: return "other system"
        }
    }
}

// MARK: - Recording

struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var audioURL: URL
    var transcript: String?
    var summary: CallSummary?
    var status: ProcessingStatus
    var clientId: UUID?
    var phoneNumber: String?
    var contactName: String?
    var errorMessage: String?
    var audioWarning: String?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        audioURL: URL,
        transcript: String? = nil,
        summary: CallSummary? = nil,
        status: ProcessingStatus = .recording,
        clientId: UUID? = nil,
        phoneNumber: String? = nil,
        contactName: String? = nil,
        errorMessage: String? = nil,
        audioWarning: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioURL = audioURL
        self.transcript = transcript
        self.summary = summary
        self.status = status
        self.clientId = clientId
        self.phoneNumber = phoneNumber
        self.contactName = contactName
        self.errorMessage = errorMessage
        self.audioWarning = audioWarning
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var displayTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: AppLanguage.current.localeIdentifier)
        return formatter.string(from: startedAt)
    }
}

enum ProcessingStatus: String, Codable {
    case recording
    case pendingTranscription = "pending_transcription"
    case transcribing
    case summarizing
    case completed
    case failed
}

// MARK: - Summary

struct CallSummary: Codable, Equatable {
    /// What the call contained, for the user.
    var humanSummary: String
    /// A ready-to-paste instruction for another AI tool, enriched with the client's context.
    var aiPrompt: String
    var requests: [String]
    var meeting: MeetingProposal?
    var tasks: [TaskProposal]?

    enum CodingKeys: String, CodingKey {
        case humanSummary, aiPrompt, requests, meeting, tasks
    }

    init(humanSummary: String, aiPrompt: String, requests: [String], meeting: MeetingProposal? = nil, tasks: [TaskProposal]? = nil) {
        self.humanSummary = humanSummary
        self.aiPrompt = aiPrompt
        self.requests = requests
        self.meeting = meeting
        self.tasks = tasks
    }

    /// Lenient on purpose: the LLM sometimes returns nulls or half-filled objects, which shouldn't throw away the whole summary.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        humanSummary = (try? container.decodeIfPresent(String.self, forKey: .humanSummary)) ?? ""
        aiPrompt = (try? container.decodeIfPresent(String.self, forKey: .aiPrompt)) ?? ""
        requests = (try? container.decodeIfPresent([String].self, forKey: .requests)) ?? []
        meeting = try? container.decodeIfPresent(MeetingProposal.self, forKey: .meeting)
        tasks = (try? container.decodeIfPresent([Lossy<TaskProposal>].self, forKey: .tasks))?.compactMap(\.value)
    }
}

/// Decodes an array element without failing the whole array when the element is malformed.
private struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct TaskProposal: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var dueISO: String?
    var notes: String?

    init(id: UUID = UUID(), title: String, dueISO: String? = nil, notes: String? = nil) {
        self.id = id
        self.title = title
        self.dueISO = dueISO
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, title, dueISO, notes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "Empty task title")
        }
        self.title = title
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        dueISO = try? container.decodeIfPresent(String.self, forKey: .dueISO)
        notes = try? container.decodeIfPresent(String.self, forKey: .notes)
    }

    var dueDate: Date? { FlexibleDate.parse(dueISO) }
}

struct MeetingProposal: Codable, Equatable {
    var title: String
    var startISO: String
    var durationMinutes: Int
    var location: String?
    var notes: String?

    enum CodingKeys: String, CodingKey { case title, startISO, durationMinutes, location, notes }

    var startDate: Date? { FlexibleDate.parse(startISO) }
}

extension MeetingProposal {
    /// A meeting without a time isn't a meeting; everything else gets a sensible default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = try? container.decode(String.self, forKey: .startISO),
              !start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .startISO, in: container, debugDescription: "Missing meeting time")
        }
        startISO = start

        if let decodedTitle = try? container.decodeIfPresent(String.self, forKey: .title),
           !decodedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = decodedTitle
        } else {
            title = L10n.t(.recordingMeeting)
        }

        var minutes = 30
        if let value = try? container.decode(Int.self, forKey: .durationMinutes) {
            minutes = value
        } else if let text = try? container.decode(String.self, forKey: .durationMinutes), let value = Int(text) {
            minutes = value
        }
        durationMinutes = minutes > 0 ? minutes : 30

        location = try? container.decodeIfPresent(String.self, forKey: .location)
        notes = try? container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// Parses the date formats LLMs produce: full ISO 8601, local date-times without a zone, and bare dates (9:00 local time).
enum FlexibleDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        let isoVariants: [ISO8601DateFormatter.Options] = [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]]
        for options in isoVariants {
            iso.formatOptions = options
            if let date = iso.date(from: raw) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: raw) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let day = formatter.date(from: raw) {
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        }
        return nil
    }
}

enum CallEvent {
    case started(callerHint: String?)
    case ended
}

/// An entry of BrumlikAI's own phonebook: the name the user gave a number, optionally linked to a client.
struct PhonebookEntry: Identifiable, Codable, Equatable {
    var id: String { number }
    var number: String
    var name: String
    var clientId: UUID?
    var updatedAt: Date

    init(number: String, name: String, clientId: UUID? = nil, updatedAt: Date = Date()) {
        self.number = PhonebookEntry.normalize(number)
        self.name = name
        self.clientId = clientId
        self.updatedAt = updatedAt
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0.isNumber || $0 == "+" }
    }
}
