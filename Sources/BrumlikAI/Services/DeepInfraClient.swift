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

final class DeepInfraClient {
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

    /// Transcribes a recording. Long recordings are split into chunks and the texts joined.
    /// `language` nil lets Whisper detect the language.
    func transcribe(
        audio url: URL,
        language: String?,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> String {
        _ = try currentToken()
        let chunks = try await AudioChunker.split(url: url)
        defer { AudioChunker.cleanup(chunks, except: url) }

        var texts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            progress(index + 1, chunks.count)
            texts.append(try await transcribeChunk(chunk, language: language))
        }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summarize(
        transcript: String,
        clientContext: String?,
        userRole: String?,
        language: AppLanguage,
        now: Date
    ) async throws -> CallSummary {
        let system = """
        You summarise a recorded phone call between the app's user and a client. The transcript has no speaker \
        labels — work out from the context who is speaking.

        STRICT RULES
        1. Never invent anything. If something wasn't said in the call, leave it out. An empty field is better than a guess.
        2. Write every text value in \(language.llmName), whatever language the call was in.
        3. humanSummary — for the user: as much concrete information from the call as possible (what the client wants, \
        details, numbers, names, deadlines, decisions). Factual, no interpretation, 3–10 sentences. Address the user as \
        "you" and call the other party "the client" (or by their name if it was said).
        4. aiPrompt — one imperative instruction for another AI tool (e.g. Claude or Cursor) that will do the actual work. \
        Start with an imperative verb. Add concrete details from CLIENT CONTEXT (URLs, servers, stack, project type) so it \
        can be pasted as is. If there is no client context, say so at the very start of aiPrompt.
        5. requests — the client's requests as short bullet points, as they were said.
        6. tasks — concrete action items for the user, at most 8. Set dueISO only if a deadline was said explicitly.
        7. meeting — only if a specific date and time for a meeting were agreed; otherwise null.
        8. Use CLIENT CONTEXT only for aiPrompt — never copy it into humanSummary or requests.
        9. Return ONLY valid JSON, no markdown.

        Current time: \(ISO8601DateFormatter.brumlik.string(from: now)) (time zone \(TimeZone.current.identifier))

        CLIENT CONTEXT
        \(clientContext ?? "No client assigned.")

        USER'S WORK
        \(userRole ?? "Not specified.")
        Use it to decide which details matter to the user, and phrase aiPrompt for this field.

        JSON schema:
        {
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

    private func transcribeChunk(_ url: URL, language: String?) async throws -> String {
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

        struct WhisperResponse: Decodable {
            let text: String?
            let segments: [Segment]?
            struct Segment: Decodable { let text: String }
        }
        let data = try await send(request)
        guard let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) else {
            throw DeepInfraError.decodingFailed
        }
        if let text = decoded.text { return text }
        if let segments = decoded.segments { return segments.map(\.text).joined(separator: " ") }
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
