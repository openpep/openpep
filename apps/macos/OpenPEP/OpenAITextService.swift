// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct OpenAITextResult: Sendable {
    let text: String
    let model: String
    let responseID: String
}

enum OpenAITextResponseFormat: Sendable {
    case progressiveSummary
    case patientWiki
    case assistantIntent
}

enum OpenAITextIssue: Error, LocalizedError, Equatable, Sendable {
    case emptyInput
    case inputTooLong
    case invalidInstructions
    case invalidModel
    case invalidAPIKey
    case credentialsRejected
    case usageLimitReached
    case requestRejected
    case networkUnavailable
    case responseTooLarge
    case invalidResponse
    case incompleteResponse
    case refusedResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyInput: "Escreva uma pergunta antes de continuar."
        case .inputTooLong: "O texto excede o limite desta solicitação. Divida-o antes de continuar."
        case .invalidInstructions: "As instruções desta solicitação estão vazias ou excedem o limite."
        case .invalidModel: "Informe um modelo válido nas configurações."
        case .invalidAPIKey: "A chave da OpenAI não está disponível ou é inválida."
        case .credentialsRejected: "A OpenAI recusou a chave configurada."
        case .usageLimitReached: "A OpenAI recusou a solicitação por limite de uso. Confira sua conta."
        case .requestRejected: "A OpenAI recusou a solicitação. Confira o modelo e tente novamente."
        case .networkUnavailable: "Não foi possível concluir a solicitação à OpenAI. Confira a conexão."
        case .responseTooLarge: "A resposta da OpenAI excedeu o limite aceito pelo aplicativo."
        case .invalidResponse: "A OpenAI devolveu uma resposta que o aplicativo não reconhece."
        case .incompleteResponse: "A OpenAI não concluiu a resposta. O texto não será usado."
        case .refusedResponse: "A OpenAI recusou responder a esta solicitação."
        case .emptyResponse: "A OpenAI não devolveu texto para esta solicitação."
        }
    }
}

protocol OpenAITextTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct OpenAITextService: Sendable {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let maximumInputCharacters = 500_000
    private static let maximumInstructionCharacters = 50_000
    private static let maximumResponseBytes = 1_048_576
    private static let maximumResponseCharacters = 100_000

    private let transport: any OpenAITextTransport

    init() {
        self.init(transport: OpenAIURLSessionTransport())
    }

    init(transport: any OpenAITextTransport) {
        self.transport = transport
    }

    func respond(
        input: String,
        instructions: String,
        model: String,
        apiKey: String,
        responseFormat: OpenAITextResponseFormat? = nil
    ) async throws -> OpenAITextResult {
        try Task.checkCancellation()
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else { throw OpenAITextIssue.emptyInput }
        guard input.count <= Self.maximumInputCharacters else { throw OpenAITextIssue.inputTooLong }
        let normalizedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInstructions.isEmpty,
              instructions.count <= Self.maximumInstructionCharacters else {
            throw OpenAITextIssue.invalidInstructions
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeModel(normalizedModel) else { throw OpenAITextIssue.invalidModel }
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeAPIKey(normalizedAPIKey) else { throw OpenAITextIssue.invalidAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(normalizedAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: normalizedModel,
            input: input,
            instructions: instructions,
            store: false,
            maxOutputTokens: 8_192,
            text: responseFormat.map(RequestText.init)
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenAITextIssue.networkUnavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              http.url == Self.endpoint else {
            throw OpenAITextIssue.invalidResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw OpenAITextIssue.responseTooLarge
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw OpenAITextIssue.credentialsRejected
        case 429: throw OpenAITextIssue.usageLimitReached
        default: throw OpenAITextIssue.requestRejected
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              !decoded.id.isEmpty,
              !decoded.model.isEmpty else {
            throw OpenAITextIssue.invalidResponse
        }
        guard decoded.status == "completed" else { throw OpenAITextIssue.incompleteResponse }
        let content = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
        guard !content.contains(where: { $0.type == "refusal" || $0.refusal != nil }) else {
            throw OpenAITextIssue.refusedResponse
        }
        let text = content
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAITextIssue.emptyResponse
        }
        guard text.count <= Self.maximumResponseCharacters else {
            throw OpenAITextIssue.responseTooLarge
        }
        return OpenAITextResult(text: text, model: decoded.model, responseID: decoded.id)
    }

    private func isSafeModel(_ model: String) -> Bool {
        guard (1...256).contains(model.utf8.count) else { return false }
        return model.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private func isSafeAPIKey(_ apiKey: String) -> Bool {
        guard (1...4_096).contains(apiKey.utf8.count) else { return false }
        return apiKey.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: String
        let instructions: String
        let store: Bool
        let maxOutputTokens: Int
        let text: RequestText?

        enum CodingKeys: String, CodingKey {
            case model, input, instructions, store, text
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct RequestText: Encodable, Sendable {
        let format: JSONSchemaFormat

        init(_ responseFormat: OpenAITextResponseFormat) {
            switch responseFormat {
            case .progressiveSummary:
                format = .progressiveSummary
            case .patientWiki:
                format = .patientWiki
            case .assistantIntent:
                format = .assistantIntent
            }
        }
    }

    private struct JSONSchemaFormat: Encodable, Sendable {
        let type = "json_schema"
        let name: String
        let strict = true
        let schema: ObjectSchema

        static let assistantIntent = JSONSchemaFormat(name: "assistant_intent", schema: ObjectSchema(
            properties: ["action": .string(enumValues: ["openPatient", "openHistory", "askPatient", "prepareDocument", "unsupported"]),
                         "query": .string(enumValues: nil)], required: ["action", "query"]))

        private static let wikiParagraph = ObjectSchema(properties: [
            "text": .string(enumValues: nil),
            "sources": .array(items: .string(enumValues: nil), maxItems: 1_000)
        ], required: ["text", "sources"])

        private static let wikiFact = ObjectSchema(properties: [
            "kind": .string(enumValues: PatientWikiFactKind.allCases.map(\.rawValue)),
            "label": .string(enumValues: nil), "text": .string(enumValues: nil),
            "source": .string(enumValues: nil), "quote": .string(enumValues: nil),
            "date": .string(enumValues: nil),
            "clinicalStatus": .string(enumValues: ["active", "resolved", "unknown"]),
            "certainty": .string(enumValues: ["confirmed", "suspected", "refuted", "unknown"]),
            "medicationUse": .string(enumValues: ["reported", "prescribed", "unknown"]),
            "dosage": .string(enumValues: nil),
            "measurement": .string(enumValues: ["", "weight", "hba1c"]),
            "value": .string(enumValues: nil), "unit": .string(enumValues: ["", "kg", "%"]),
            "method": .string(enumValues: nil),
            "observationStatus": .string(enumValues: ["final", "preliminary", "corrected", "unknown"]),
            "ips": .object(ObjectSchema(properties: [
                "course": .string(enumValues: ["chronic", "recurrent", "current", "unknown"]),
                "frequency": .string(enumValues: nil), "route": .string(enumValues: nil),
                "eventStatus": .string(enumValues: ["completed", "planned", "unknown"]),
                "nextDate": .string(enumValues: nil),
                "socialDomain": .string(enumValues: [""] + PatientIPSSocialDomain.allCases.map(\.rawValue))
            ], required: ["course", "frequency", "route", "eventStatus", "nextDate", "socialDomain"]))
        ], required: ["kind", "label", "text", "source", "quote", "date", "clinicalStatus", "certainty",
                      "medicationUse", "dosage", "measurement", "value", "unit", "method", "observationStatus", "ips"])

        static let patientWiki = JSONSchemaFormat(name: "patient_wiki", schema: ObjectSchema(properties: [
            "overview": .object(wikiParagraph),
            "facts": .array(items: .object(wikiFact), maxItems: 100),
            "sections": .array(items: .object(ObjectSchema(properties: [
                "topic": .string(enumValues: PatientWikiTopic.allCases.map(\.rawValue)),
                "paragraphs": .array(items: .object(wikiParagraph), maxItems: 20)
            ], required: ["topic", "paragraphs"])), maxItems: PatientWikiTopic.allCases.count)
        ], required: ["overview", "sections", "facts"]))

        static let progressiveSummary = JSONSchemaFormat(
            name: "progressive_summary_operations",
            schema: ObjectSchema(
                properties: [
                    "operations": .array(
                        items: .object(ObjectSchema(
                            properties: [
                                "action": .string(enumValues: ["add", "replace", "flag"]),
                                "target_item_index": .nullableInteger,
                                "text": .string(enumValues: nil),
                            ],
                            required: ["action", "target_item_index", "text"]
                        )),
                        maxItems: 16
                    ),
                ],
                required: ["operations"]
            )
        )
    }

    private struct ObjectSchema: Encodable, Sendable {
        let type = "object"
        let properties: [String: SchemaProperty]
        let required: [String]
        let additionalProperties = false
    }

    private indirect enum SchemaProperty: Encodable, Sendable {
        case string(enumValues: [String]?)
        case nullableInteger
        case array(items: SchemaProperty, maxItems: Int)
        case object(ObjectSchema)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .string(enumValues):
                try container.encode("string", forKey: .type)
                try container.encodeIfPresent(enumValues, forKey: .enumValues)
            case .nullableInteger:
                try container.encode(["integer", "null"], forKey: .type)
            case let .array(items, maxItems):
                try container.encode("array", forKey: .type)
                try container.encode(items, forKey: .items)
                try container.encode(maxItems, forKey: .maxItems)
            case let .object(schema):
                try schema.encode(to: encoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, items
            case enumValues = "enum"
            case maxItems = "maxItems"
        }
    }

    private struct ResponseBody: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
                let refusal: String?
            }

            let type: String
            let content: [Content]?
        }

        let id: String
        let model: String
        let status: String
        let output: [Output]
    }
}

private final class OpenAINoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct OpenAIURLSessionTransport: OpenAITextTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(
            configuration: configuration,
            delegate: OpenAINoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
