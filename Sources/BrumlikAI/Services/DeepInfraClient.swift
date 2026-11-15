import Foundation

enum DeepInfraError: LocalizedError {
    case missingToken
    case badResponse(status: Int, body: String)
    case decodingFailed
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .missingToken: return L10n.t(.errMissingToken)
        case .badResponse(let status, let body): return L10n.f(.errBadResponse, status, String(body.prefix(300)))
        case .decodingFailed: return L10n.t(.errDecodingFailed)
        case .invalidURL: return L10n.t(.errInvalidURL)
        }
    }
}

final class DeepInfraClient: SpeechTranscribing {
    private let baseURL = URL(string: "https://api.deepinfra.com/v1/")!
    private let whisperModel = "openai/whisper-large-v3"
    private let chatModel = "meta-llama/Llama-3.3-70B-Instruct"
    private let token: () -> String?

    init(token: @escaping () -> String?) {
        self.token = token
    }

    func checkToken() async throws {
        var request = try authorizedRequest("openai/models")
        request.httpMethod = "GET"
        _ = try await send(request)
    }

    func summarize(
        transcript: String,
        hasSpeakers: Bool,
        clientContext: String?,
        userRole: String?,
        language: AppLanguage,
        now: Date
    ) async throws -> CallSummary {
        let speakers = hasSpeakers
            ? "Every line of the transcript starts with who is speaking: USER (the app's user) or CLIENT (the other party)."
            : "The transcript has no speaker labels — work out from the context who is speaking."
        let system = """
        You summarise a recorded phone call between the app's user and a client. \(speakers)

        STRICT RULES
        1. Never invent anything. If something wasn't said in the call, leave it out. An empty field is better than a guess.
        2. Write every text value in \(language.llmName), whatever language the call was in.
        3. headline — one short sentence (at most 90 characters) saying what the call was about and what was agreed.
        4. humanSummary — for the user: as much concrete information from the call as possible (what the client wants, \
        details, numbers, names, deadlines, decisions). Factual, no interpretation, 3–10 sentences. Address the user as \
        "you" and call the other party "the client" (or by their name if it was said).
        5. aiPrompt — one imperative instruction for another AI tool (e.g. Claude or Cursor) that will do the actual work. \
        Start with an imperative verb. Add concrete details from CLIENT CONTEXT (URLs, servers, stack, project type) so it \
        can be pasted as is. If there is no client context, say so at the very start of aiPrompt.
        6. requests — the client's requests as short bullet points, as they were said.
        7. tasks — concrete action items for the user (what the user promised or was asked to do), at most 8. What the \
        client promised to do belongs in humanSummary, not in tasks. Set dueISO only if a deadline was said explicitly.
        8. meeting — only if a specific date and time for a meeting were agreed; otherwise null.
        9. Use CLIENT CONTEXT only for aiPrompt — never copy it into headline, humanSummary or requests.
        10. Return ONLY valid JSON, no markdown.

        Current time: \(ISO8601DateFormatter.brumlik.string(from: now)) (time zone \(TimeZone.current.identifier))

        CLIENT CONTEXT
        \(clientContext ?? "No client assigned.")

        USER'S WORK
        \(userRole ?? "Not specified.")
        Use it to decide which details matter to the user, and phrase aiPrompt for this field.

        JSON schema:
        {
          "headline": "string",
          "humanSummary": "string",
          "aiPrompt": "string",
          "requests": ["string"],
          "tasks": [{"title": "string", "dueISO": "ISO 8601 or null", "notes": "string or null"}],
          "meeting": {"title": "string", "startISO": "ISO 8601 with time zone offset", "durationMinutes": 30, \
        "location": "string or null", "notes": "string or null"}
        }
        """
        let content = try await chat(system: system, user: "Call transcript:\n\n\(transcript)", temperature: 0.15, json: true)
        guard let data = Self.extractJSONObject(from: content),
              let summary = try? JSONDecoder().decode(CallSummary.self, from: data) else {
            throw DeepInfraError.decodingFailed
        }
        return summary
    }

    /// Rewrites the AI prompt of an existing call, e.g. after a client was assigned.
    func regenerateAIPrompt(
        humanSummary: String,
        requests: [String],
        clientContext: String?,
        userRole: String?,
        language: AppLanguage
    ) async throws -> String {
        let system = """
        Write one concrete, copy-pasteable instruction for another AI tool (e.g. Claude or Cursor) that will do the work \
        described below. Start with an imperative verb. Write it in \(language.llmName). Phrase it for the user's field of \
        work. Include concrete URLs, servers and stack from CLIENT CONTEXT. Never invent anything that isn't in the \
        material. Return only the instruction text — no JSON, no quotes.

        CLIENT CONTEXT
        \(clientContext ?? "No client assigned — mention at the start that the client's details are missing.")

        USER'S WORK
        \(userRole ?? "Not specified.")
        """
        let user = """
        CALL SUMMARY
        \(humanSummary)

        CLIENT REQUESTS
        \(requests.map { "- \($0)" }.joined(separator: "\n"))
        """
        return try await chat(system: system, user: user, temperature: 0.2, json: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short follow-up email from the user to the person they spoke with, built only from what was said.
    func draftFollowUpEmail(
        transcript: String,
        summary: CallSummary,
        recipientName: String?,
        company: String?,
        language: AppLanguage,
        now: Date
    ) async throws -> (subject: String, body: String) {
        let system = """
        You write a short follow-up email that the app's user sends to the person they just spoke with on the phone.

        STRICT RULES
        1. Use only what was said in the call. Never invent facts, prices, dates or promises.
        2. Write in the language the call was held in (judge by the transcript). If you can't tell, write in \(language.llmName).
        3. Structure: a greeting; thanks for the call; a short recap of what you talked about; the agreed next steps — \
        who does what and by when; the meeting date and time if one was agreed; a polite closing line.
        4. Polite, professional and brief — at most about 150 words. Use formal address (in Czech "vykání", and the \
        vocative in the greeting, e.g. "Dobrý den, pane Nováku,"). If the recipient's name isn't known, greet neutrally \
        ("Dobrý den," / "Hello,").
        5. Leave out internal notes, technical details meant only for the user, and anything about recording, \
        transcripts or AI.
        6. End with a closing phrase only (e.g. "S pozdravem" or "Best regards"), without a name — the user's own mail \
        signature follows.
        7. The subject is short and specific (e.g. "Shrnutí našeho telefonátu – nový e-shop").
        8. Plain text with line breaks, no markdown.
        9. Return ONLY valid JSON: {"subject": "string", "body": "string"}

        Today: \(ISO8601DateFormatter.brumlik.string(from: now)) (time zone \(TimeZone.current.identifier))

        RECIPIENT
        Name: \(recipientName ?? "unknown")
        Company: \(company ?? "unknown")
        """
        var material = """
        CALL SUMMARY (written for the user)
        \(summary.humanSummary)
        """
        if !summary.requests.isEmpty {
            material += "\n\nCLIENT'S REQUESTS\n" + summary.requests.map { "- \($0)" }.joined(separator: "\n")
        }
        if let tasks = summary.tasks, !tasks.isEmpty {
            material += "\n\nUSER'S NEXT STEPS\n" + tasks.map { task in
                "- \(task.title)" + (task.dueISO.map { " (by \($0))" } ?? "")
            }.joined(separator: "\n")
        }
        if let meeting = summary.meeting {
            material += "\n\nAGREED MEETING\n\(meeting.title), \(meeting.startISO), \(meeting.durationMinutes) min"
            if let location = meeting.location, !location.isEmpty { material += ", \(location)" }
        }
        material += "\n\nTRANSCRIPT\n" + String(transcript.prefix(24_000))

        let content = try await chat(system: system, user: material, temperature: 0.3, json: true)
        struct Draft: Decodable { let subject: String?; let body: String? }
        guard let data = Self.extractJSONObject(from: content),
              let draft = try? JSONDecoder().decode(Draft.self, from: data),
              let body = draft.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            throw DeepInfraError.decodingFailed
        }
        return ((draft.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines), body)
    }

    /// Takes the JSON object out of a reply that may be wrapped in a markdown fence or prose.
    static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - HTTP

    /// Transcribes one file (up to about 25 MB) into segments with times from the start of the file.
    /// `language` nil lets Whisper detect the language.
    func transcribeSegments(of url: URL, language: String?) async throws -> [WhisperSegment] {
        var request = try authorizedRequest("inference/\(whisperModel)")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        let boundary = "BrumlikAI-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let language { field("language", language) }
        field("task", "transcribe")
        body.append(Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(url.lastPathComponent)\"\r\n" +
            "Content-Type: \(Self.mimeType(for: url))\r\n\r\n"
        ).utf8))
        body.append(try Data(contentsOf: url))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        return try Self.parseWhisperResponse(try await send(request))
    }

    /// Whisper's reply: segments with times, or at least the whole text.
    static func parseWhisperResponse(_ data: Data) throws -> [WhisperSegment] {
        struct WhisperResponse: Decodable {
            let text: String?
            let segments: [Segment]?
            struct Segment: Decodable {
                let start: Double?
                let end: Double?
                let text: String
            }
        }
        guard let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) else {
            throw DeepInfraError.decodingFailed
        }
        if let segments = decoded.segments, !segments.isEmpty {
            return segments.map { WhisperSegment(start: $0.start ?? 0, end: $0.end ?? $0.start ?? 0, text: $0.text) }
        }
        if let text = decoded.text {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [WhisperSegment(start: 0, end: 0, text: text)]
        }
        throw DeepInfraError.decodingFailed
    }

    private func chat(system: String, user: String, temperature: Double, json: Bool) async throws -> String {
        var request = try authorizedRequest("openai/chat/completions")
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": chatModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": temperature
        ]
        if json { payload["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        struct ChatResponse: Decodable {
            let choices: [Choice]
            struct Choice: Decodable { let message: Message }
            struct Message: Decodable { let content: String? }
        }
        let data = try await send(request)
        guard let content = (try? JSONDecoder().decode(ChatResponse.self, from: data))?.choices.first?.message.content else {
            throw DeepInfraError.decodingFailed
        }
        return content
    }

    private func currentToken() throws -> String {
        guard let token = token()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw DeepInfraError.missingToken
        }
        return token
    }

    private func authorizedRequest(_ path: String) throws -> URLRequest {
        let token = try currentToken()
        guard let url = URL(string: path, relativeTo: baseURL) else { throw DeepInfraError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepInfraError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepInfraError.badResponse(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
