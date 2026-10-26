import Foundation
import Observation

@MainActor
@Observable
final class NoteParsingService {
    enum State: Equatable, Sendable {
        case idle
        case parsing
        case success(NoteParsingResponse)
        case error(NoteParsingUserFacingError)
    }

    private(set) var state: State = .idle

    private let session: URLSession
    private let baseURLOverride: URL?
    private let authTokenProvider: () async throws -> String
    private var activeRequestID: UUID?

    init(
        session: URLSession = .shared,
        baseURL: URL? = nil,
        authService: WiskAuthService? = nil,
        authTokenProvider: (() async throws -> String)? = nil
    ) {
        self.session = session
        self.baseURLOverride = baseURL
        if let authTokenProvider {
            self.authTokenProvider = authTokenProvider
        } else if let authService {
            self.authTokenProvider = {
                try await authService.idToken()
            }
        } else {
            self.authTokenProvider = {
                throw NoteParsingUserFacingError.unauthorized
            }
        }
    }

    @discardableResult
    func parse(note: String, buckets: [NoteParsingBucketInput] = []) async throws -> NoteParsingResponse {
        let requestID = UUID()
        activeRequestID = requestID
        state = .parsing

        do {
            let token = try await authTokenProvider()
            let request = try parseNoteRequest(note: note, buckets: buckets, token: token)
            let (data, response) = try await session.data(for: request)

            try ensureCurrent(requestID)
            let parsedResponse = try decodeResponse(data: data, response: response)
            try ensureCurrent(requestID)

            state = .success(parsedResponse)
            activeRequestID = nil
            return parsedResponse
        } catch {
            let mappedError = mapError(error)

            if case .cancelled = mappedError {
                if activeRequestID == requestID {
                    activeRequestID = nil
                    state = .idle
                }
                throw mappedError
            }

            if activeRequestID == requestID {
                activeRequestID = nil
                state = .error(mappedError)
            }

            throw mappedError
        }
    }

    @discardableResult
    func parse(note: String, bucketDefinitions: [NoteBucket]) async throws -> NoteParsingResponse {
        try await parse(note: note, buckets: bucketDefinitions.map(\.asParsingInput))
    }

    func cancelParsing() {
        activeRequestID = nil
        state = .idle
    }

    private func resolvedBaseURL() -> URL {
        baseURLOverride ?? WiskAPIConfiguration.resolvedBaseURL()
    }

    private func parseNoteRequest(note: String, buckets: [NoteParsingBucketInput], token: String) throws -> URLRequest {
        let url = resolvedBaseURL()
            .appendingPathComponent("openai")
            .appendingPathComponent("parse-note")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = BackendParseNoteRequest(
            body: note,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            buckets: buckets
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func decodeResponse(data: Data, response: URLResponse) throws -> NoteParsingResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NoteParsingUserFacingError.malformedResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        let completion: OpenAIParseNoteEnvelope
        do {
            completion = try JSONDecoder().decode(OpenAIParseNoteEnvelope.self, from: data)
        } catch {
            throw NoteParsingUserFacingError.malformedResponse
        }

        guard let choice = completion.result.choices.first else {
            throw NoteParsingUserFacingError.emptyResponse
        }

        if choice.message.refusal?.isEmpty == false || choice.finishReason == "content_filter" {
            throw NoteParsingUserFacingError.refusal
        }

        let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw NoteParsingUserFacingError.emptyResponse
        }

        guard let contentData = content.data(using: .utf8) else {
            throw NoteParsingUserFacingError.malformedResponse
        }

        do {
            return try JSONDecoder().decode(NoteParsingResponse.self, from: contentData)
        } catch {
            throw NoteParsingUserFacingError.malformedResponse
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> NoteParsingUserFacingError {
        if statusCode == 401 {
            return .unauthorized
        }

        if statusCode == 429 {
            return .rateLimited
        }

        if 500..<600 ~= statusCode {
            return .serverUnavailable
        }

        if let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
           apiError.error.code == "content_filter" || apiError.error.type == "content_filter" {
            return .refusal
        }

        if let apiError = try? JSONDecoder().decode(WiskAPIErrorBody.self, from: data),
           let message = apiError.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return .network(message)
        }

        return .requestFailed(statusCode: statusCode)
    }

    private func mapError(_ error: Error) -> NoteParsingUserFacingError {
        if let userFacingError = error as? NoteParsingUserFacingError {
            return userFacingError
        }

        if error is CancellationError {
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                return .unreachable
            default:
                return .network(urlError.localizedDescription)
            }
        }

        return .network(error.localizedDescription)
    }

    private func ensureCurrent(_ requestID: UUID) throws {
        guard activeRequestID == requestID else {
            throw NoteParsingUserFacingError.cancelled
        }
    }
}

struct NoteParsingResponse: Codable, Equatable, Sendable {
    let items: [NoteParsingItem]
    let dailySummary: String
    let suggestedFollowUps: [String]
}

struct NoteParsingBucketInput: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let descriptionText: String
    let examples: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case descriptionText = "description"
        case examples
    }
}

struct NoteParsingItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let rawText: String
    let title: String
    let type: ParsedNoteItemType
    let confidence: Double
    let sourceLineIndex: Int
    let dueHint: String?
    let project: String?
    let people: [String]
    let bucketId: String?
    let bucketReason: String?
}

extension NoteParsingResponse {
    func asDraft(rawText: String, fallbackDate: Date) -> ParsedDailyNoteDraft {
        ParsedDailyNoteDraft(
            date: fallbackDate,
            rawText: rawText,
            parseVersion: 1,
            parseModel: "openai-server-default",
            items: items.map(\.asDraftItem)
        )
    }
}

private extension NoteParsingItem {
    var asDraftItem: ParsedNoteItemDraft {
        ParsedNoteItemDraft(
            rawText: rawText,
            title: title,
            itemType: type,
            status: .open,
            reviewStatus: .pending,
            confidence: confidence,
            sourceLineIndex: sourceLineIndex,
            dueHint: dueHint,
            project: project,
            people: people,
            bucketId: bucketId,
            bucketReason: bucketReason
        )
    }
}

enum NoteParsingUserFacingError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case rateLimited
    case serverUnavailable
    case timedOut
    case refusal
    case emptyResponse
    case malformedResponse
    case requestFailed(statusCode: Int)
    case network(String)
    case unreachable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Wisk Pro could not verify your account. Sign in and try again."
        case .rateLimited:
            return "Wisk Pro is rate limiting AI requests. Wait a moment and try again."
        case .serverUnavailable:
            return "Wisk AI is temporarily unavailable. Try again in a few minutes."
        case .timedOut:
            return "The note parsing request timed out. Check your connection and try again."
        case .refusal:
            return "Wisk AI refused to parse this note. Edit the note and try again."
        case .emptyResponse:
            return "Wisk AI returned an empty parsing result. Try again."
        case .malformedResponse:
            return "Wisk AI returned a response Wisk could not read. Try again."
        case .requestFailed(let statusCode):
            return "Wisk AI returned an unexpected error (\(statusCode)). Try again."
        case .network(let message):
            return "The note parsing request failed: \(message)"
        case .unreachable:
            return "Could not reach Wisk AI. Check your connection and try again."
        case .cancelled:
            return "The note parsing request was cancelled."
        }
    }
}

extension NoteParsingService {
    static let systemPrompt = """
    You are Wisk, a thoughtful daily-notes organizer. The user writes messy fragments, not a formal todo list.
    Return only JSON that matches the provided schema.

    Your job:
    - Preserve each meaningful raw line as an item unless it is just the day/date or blank filler.
    - Convert bracketed checklist lines like "[ ] Claire bday" into action items.
    - Infer actions from terse fragments with verbs or implied next steps: "Invite Alex", "Disclosure comments respond", "Eight sleep. Install apps".
    - Infer reminders for birthdays, dates, appointments, errands, or things the user likely needs to remember.
    - Infer learnings from observations, decisions, patterns, takeaways, or "now I know" style notes.
    - Use topic for project/context headers like "SplitTab issues" or "HTML Builder in Saffron" when no action is explicit.
    - Use reference for media, names, links, or things merely mentioned, like "Bridgerton", unless context implies action.
    - Extract people names when obvious. Do not invent people.
    - Extract project/context when obvious, such as SplitTab, Thorble, Saffron, UserMoment, UserEvent.
    - Use confidence from 0.0 to 1.0. Prefer 0.55-0.75 for ambiguous fragments instead of pretending certainty.
    - Keep titles short and useful, rewriting fragments into natural language when helpful.
    - sourceLineIndex is zero-based in the original note, including blank lines.
    - dueHint is a natural-language hint from the note, not a guessed date. Use null when unknown.
    - If buckets are provided, set bucketId only when one bucket clearly fits; otherwise return null.
    - bucketReason should briefly explain the bucket choice when bucketId is set, otherwise null.

    Write a dailySummary that captures the themes of the day in one concise sentence.
    suggestedFollowUps should ask about ambiguous items that need clarification, for example "What should happen next with Forma?"
    """

    static let responseFormat = OpenAIResponseFormat(
        type: "json_schema",
        jsonSchema: .init(
            name: "wisk_note_parse",
            strict: true,
            schema: .object([
                "items": .array(
                    .object([
                        "id": .string(format: "uuid"),
                        "rawText": .string(),
                        "title": .string(),
                        "type": .string(enumValues: ParsedNoteItemType.allCases.map(\.rawValue)),
                        "confidence": .number,
                        "sourceLineIndex": .integer,
                        "dueHint": .nullable(.string()),
                        "project": .nullable(.string()),
                        "people": .array(.string()),
                        "bucketId": .nullable(.string(format: "uuid")),
                        "bucketReason": .nullable(.string())
                    ], required: ["id", "rawText", "title", "type", "confidence", "sourceLineIndex", "dueHint", "project", "people", "bucketId", "bucketReason"])
                ),
                "dailySummary": .string(),
                "suggestedFollowUps": .array(.string())
            ], required: ["items", "dailySummary", "suggestedFollowUps"])
        )
    )
}

private struct BackendParseNoteRequest: Encodable, Sendable {
    let body: String
    let locale: String
    let timezone: String
    let buckets: [NoteParsingBucketInput]
}

struct OpenAIChatRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenAIMessage]
    let responseFormat: OpenAIResponseFormat

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

struct OpenAIMessage: Encodable, Sendable {
    let role: String
    let content: String

    static func system(content: String) -> OpenAIMessage {
        OpenAIMessage(role: "system", content: content)
    }

    static func user(content: String) -> OpenAIMessage {
        OpenAIMessage(role: "user", content: content)
    }
}

struct OpenAIResponseFormat: Encodable, Sendable {
    let type: String
    let jsonSchema: JSONSchemaEnvelope

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct JSONSchemaEnvelope: Encodable, Sendable {
    let name: String
    let strict: Bool
    let schema: JSONSchema
}

indirect enum JSONSchema: Encodable, Sendable {
    case object([String: JSONSchema], required: [String])
    case array(JSONSchema)
    case string(format: String? = nil, enumValues: [String]? = nil)
    case number
    case integer
    case nullable(JSONSchema)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .object(let properties, let required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encode(false, forKey: .additionalProperties)
        case .array(let items):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
        case .string(let format, let enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(format, forKey: .format)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)
        case .number:
            try container.encode("number", forKey: .type)
        case .integer:
            try container.encode("integer", forKey: .type)
        case .nullable(let schema):
            try container.encode(["null", schema.schemaType], forKey: .type)
            try schema.encodeNestedProperties(into: &container)
        }
    }

    private var schemaType: String {
        switch self {
        case .object:
            return "object"
        case .array:
            return "array"
        case .string:
            return "string"
        case .number:
            return "number"
        case .integer:
            return "integer"
        case .nullable:
            return "null"
        }
    }

    private func encodeNestedProperties(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .string(let format, let enumValues):
            try container.encodeIfPresent(format, forKey: .format)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)
        case .array(let items):
            try container.encode(items, forKey: .items)
        case .object(let properties, let required):
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encode(false, forKey: .additionalProperties)
        case .number, .integer:
            break
        case .nullable(let schema):
            try schema.encodeNestedProperties(into: &container)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case additionalProperties = "additionalProperties"
        case items
        case format
        case enumValues = "enum"
    }
}

private struct OpenAIParseNoteEnvelope: Decodable, Sendable {
    let result: OpenAIChatCompletion
}

private struct WiskAPIErrorBody: Decodable, Sendable {
    let error: String?
    let code: String?
}

struct OpenAIChatCompletion: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable, Sendable {
        let content: String?
        let refusal: String?
    }
}

private struct OpenAIErrorResponse: Decodable, Sendable {
    let error: APIError

    struct APIError: Decodable, Sendable {
        let message: String?
        let type: String?
        let code: String?
    }
}
