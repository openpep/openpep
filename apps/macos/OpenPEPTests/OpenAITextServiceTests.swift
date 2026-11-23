// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("AI-ROUTE-001 synthetic Responses API client")
struct OpenAITextServiceTests {
    @Test("assistant sends only its prompt with a closed action schema")
    func assistantSchema() async throws {
        let transport = OpenAIRecordingTransport(statusCode: 200, data: Self.completedResponse)
        _ = try await OpenAITextService(transport: transport).respond(input: "Busque Ana Fictícia",
            instructions: AIPromptCatalog.assistantIntent.instructions,
            model: "synthetic-model", apiKey: "sk-synthetic", responseFormat: .assistantIntent)
        let request = try #require(await transport.requests().first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["input"] as? String == "Busque Ana Fictícia")
        #expect(json["tools"] == nil && json["store"] as? Bool == false)
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["action", "query"])
        #expect(action["enum"] as? [String] == ["openPatient", "openHistory", "askPatient", "prepareDocument", "unsupported"])
    }

    @Test("wiki transport requires citations and complete structured evidence fields")
    func wikiSchema() async throws {
        let transport = OpenAIRecordingTransport(statusCode: 200, data: Self.completedResponse)
        _ = try await OpenAITextService(transport: transport).respond(input: "Sintético", instructions: "Sintético",
            model: "gpt-5.6-sol", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        let request = try #require(await transport.requests().first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect(Set(schema["required"] as? [String] ?? []) == Set(["overview", "sections", "facts"]))
        let properties = try #require(schema["properties"] as? [String: Any])
        let facts = try #require(properties["facts"] as? [String: Any])
        let item = try #require(facts["items"] as? [String: Any])
        let fields = try #require(item["properties"] as? [String: Any])
        #expect(Set(item["required"] as? [String] ?? []) == Set(fields.keys))
        #expect(fields["quote"] != nil && fields["source"] != nil && fields["observationStatus"] != nil)
    }
    @Test("sends the bounded no-storage request and reads completed output text")
    func sendsRequestAndReadsCompletedText() async throws {
        let transport = OpenAIRecordingTransport(
            statusCode: 200,
            data: Data(#"""
            {
              "id":"resp_synthetic_001",
              "model":"gpt-5.6-sol-2026-09-01",
              "status":"completed",
              "output":[
                {"type":"reasoning","content":[]},
                {"type":"message","role":"assistant","content":[
                  {"type":"output_text","text":"Resposta sintética ","annotations":[]},
                  {"type":"output_text","text":"concluída.","annotations":[]}
                ]}
              ]
            }
            """#.utf8)
        )
        let result = try await OpenAITextService(transport: transport).respond(
            input: "Pergunta inteiramente sintética.",
            instructions: "Responda em português.",
            model: "gpt-5.6-sol",
            apiKey: "sk-synthetic-never-sent"
        )

        #expect(result.text == "Resposta sintética concluída.")
        #expect(result.model == "gpt-5.6-sol-2026-09-01")
        #expect(result.responseID == "resp_synthetic_001")
        let request = try #require(await transport.requests().first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-synthetic-never-sent")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-5.6-sol")
        #expect(json["input"] as? String == "Pergunta inteiramente sintética.")
        #expect(json["instructions"] as? String == "Responda em português.")
        #expect(json["store"] as? Bool == false)
        #expect(json["max_output_tokens"] as? Int == 8_192)
        #expect(json["tools"] == nil)
    }

    @Test("refuses incomplete, refusal, and empty responses")
    func refusesUnusableResponses() async throws {
        for (data, expected) in [
            (Self.response(status: "incomplete", content: #"{"type":"output_text","text":"parcial"}"#),
             OpenAITextIssue.incompleteResponse),
            (Self.response(status: "completed", content: #"{"type":"refusal","refusal":"remote detail"}"#),
             OpenAITextIssue.refusedResponse),
            (Self.response(status: "completed", content: #"{"type":"output_text","text":"   "}"#),
             OpenAITextIssue.emptyResponse),
        ] {
            let transport = OpenAIRecordingTransport(statusCode: 200, data: data)
            do {
                _ = try await OpenAITextService(transport: transport).respond(
                    input: "Entrada sintética",
                    instructions: "Instrução sintética",
                    model: "gpt-5.6-sol",
                    apiKey: "sk-synthetic"
                )
                Issue.record("a resposta inutilizável deveria ser recusada")
            } catch let issue as OpenAITextIssue {
                #expect(issue == expected)
            }
        }
    }

    @Test("requests a strict schema for progressive summary operations")
    func requestsProgressiveSummarySchema() async throws {
        let transport = OpenAIRecordingTransport(
            statusCode: 200,
            data: Self.completedResponse
        )
        _ = try await OpenAITextService(transport: transport).respond(
            input: "Transcrição sintética.",
            instructions: "Produza operações sintéticas.",
            model: "gpt-4o",
            apiKey: "sk-synthetic",
            responseFormat: .progressiveSummary
        )

        let request = try #require(await transport.requests().first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let text = try #require(json["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let operations = try #require(properties["operations"] as? [String: Any])
        let items = try #require(operations["items"] as? [String: Any])

        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(items["required"] as? [String] ?? []) == Set([
            "action", "target_item_index", "text",
        ]))
        #expect(items["additionalProperties"] as? Bool == false)
    }

    @Test("redacts remote failures, performs no retry, and propagates cancellation")
    func redactsFailureAndCancelsWithoutRetry() async throws {
        let remoteSecret = "remote-secret-that-must-not-appear"
        let rejected = OpenAIRecordingTransport(
            statusCode: 401,
            data: Data(#"{"error":{"message":"remote-secret-that-must-not-appear"}}"#.utf8)
        )
        do {
            _ = try await OpenAITextService(transport: rejected).respond(
                input: "Entrada sintética",
                instructions: "Instrução sintética",
                model: "gpt-5.6-sol",
                apiKey: "sk-secret-that-must-not-appear"
            )
            Issue.record("a credencial rejeitada deveria falhar")
        } catch let issue as OpenAITextIssue {
            #expect(issue == .credentialsRejected)
            #expect(!issue.localizedDescription.contains(remoteSecret))
            #expect(!issue.localizedDescription.contains("sk-secret-that-must-not-appear"))
        }
        #expect(await rejected.requests().count == 1)

        let slow = OpenAIRecordingTransport(
            statusCode: 200,
            data: Self.completedResponse,
            delayNanoseconds: 10_000_000_000
        )
        let task = Task {
            try await OpenAITextService(transport: slow).respond(
                input: "Entrada cancelada sintética",
                instructions: "Instrução sintética",
                model: "gpt-5.6-sol",
                apiKey: "sk-synthetic"
            )
        }
        while await slow.requests().isEmpty { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("o cancelamento deveria encerrar a solicitação")
        } catch is CancellationError {
            // Expected: cancellation is not converted into a network error.
        }
        #expect(await slow.requests().count == 1)
    }

    @Test("classifies a realistic Responses envelope before wiki and fact validation")
    func classifiesResponsePhases() async throws {
        let validTransport = OpenAIRecordingTransport(
            statusCode: 200,
            data: Self.responsesEnvelope(text: Self.validWikiText)
        )
        let response = try await OpenAITextService(transport: validTransport).respond(
            input: "Contexto sintético", instructions: "Instrução sintética",
            model: "gpt-5.6-terra", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        #expect(response.model == "gpt-5.6-terra-2026-09-01")
        #expect(response.responseID == "resp_synthetic_wiki")
        #expect(try PatientWikiGeneration.decode(response.text, sourceCount: 1).overviewText
            == "Resumo sintético.")

        let invalidWikiTransport = OpenAIRecordingTransport(
            statusCode: 200,
            data: Self.responsesEnvelope(text: Self.validWikiText.replacingOccurrences(
                of: "[\"F1\"]", with: "[]"))
        )
        let invalidWikiResponse = try await OpenAITextService(transport: invalidWikiTransport).respond(
            input: "Contexto sintético", instructions: "Instrução sintética",
            model: "gpt-5.6-terra", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        var wikiDiagnostic: PatientWikiGenerationDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiGeneration.decode(invalidWikiResponse.text, sourceCount: 1,
                diagnostic: { wikiDiagnostic = $0 })
        }
        #expect(wikiDiagnostic?.code == .emptySources)
        #expect(wikiDiagnostic?.sectionIndex == nil && wikiDiagnostic?.paragraphIndex == nil)

        let factContext = try PatientWikiContext.make(
            patient: PatientSummary(
                patientID: "pt_0198f700-0000-7000-8000-000000000201",
                url: URL(fileURLWithPath: "/synthetic/wiki-bind"), record: nil,
                rawAssets: [], encounters: []),
            entries: [PatientHistoryEntry(
                id: "enc_0198f700-0000-7000-8000-000000000202",
                title: "Consulta sintética", timestamp: "2026-09-01T12:00:00Z",
                status: "Finalizada", text: "Peso 72 kg.",
                source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)],
            corrections: "")
        let validFactGeneration = try PatientWikiGeneration.decode(
            Self.validWikiTextWithFact, sourceCount: factContext.entries.count)
        var invalidFact = try #require(validFactGeneration.facts.first)
        invalidFact.quote = "Peso 71 kg."
        var factDiagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bind([invalidFact], to: factContext,
                diagnostic: { factDiagnostic = $0 })
        }
        #expect(factDiagnostic?.code == .quoteMismatch)
        #expect(factDiagnostic?.factIndex == 0 && factDiagnostic?.sourceIndex == 0)

        let nonQuantitative = PatientWikiFactDraft(kind: .problem, label: "Peso registrado",
            text: "Medida documentada.", source: "F1", quote: "Peso 72 kg.", observationStatus: "final")
        var fieldDiagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bind([nonQuantitative], to: factContext,
                diagnostic: { fieldDiagnostic = $0 })
        }
        #expect(fieldDiagnostic?.code == .observationStatusForKind)
        #expect(fieldDiagnostic?.factIndex == 0 && fieldDiagnostic?.sourceIndex == 0)

        let truncated = OpenAIRecordingTransport(statusCode: 200, data: Data("{\"id\":\"resp".utf8))
        await #expect(throws: OpenAITextIssue.invalidResponse) {
            try await OpenAITextService(transport: truncated).respond(
                input: "Contexto sintético", instructions: "Instrução sintética",
                model: "gpt-5.6-terra", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        }

        let incomplete = OpenAIRecordingTransport(
            statusCode: 200, data: Self.responsesEnvelope(text: "", status: "incomplete"))
        await #expect(throws: OpenAITextIssue.incompleteResponse) {
            try await OpenAITextService(transport: incomplete).respond(
                input: "Contexto sintético", instructions: "Instrução sintética",
                model: "gpt-5.6-terra", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        }

        let timedOut = OpenAITimedOutTransport()
        await #expect(throws: OpenAITextIssue.networkUnavailable) {
            try await OpenAITextService(transport: timedOut).respond(
                input: "Contexto sintético", instructions: "Instrução sintética",
                model: "gpt-5.6-terra", apiKey: "sk-synthetic", responseFormat: .patientWiki)
        }
    }

    @Test("rejects oversized input and unsafe model before transport")
    func validatesLocalBounds() async throws {
        let transport = OpenAIRecordingTransport(statusCode: 200, data: Self.completedResponse)
        await #expect(throws: OpenAITextIssue.inputTooLong) {
            try await OpenAITextService(transport: transport).respond(
                input: String(repeating: "x", count: 500_001),
                instructions: "Instrução sintética",
                model: "gpt-5.6-sol",
                apiKey: "sk-synthetic"
            )
        }
        await #expect(throws: OpenAITextIssue.invalidModel) {
            try await OpenAITextService(transport: transport).respond(
                input: "Entrada sintética",
                instructions: "Instrução sintética",
                model: "gpt-5.6-sol\nunsafe",
                apiKey: "sk-synthetic"
            )
        }
        #expect(await transport.requests().isEmpty)
    }

    private static let completedResponse = Data(#"""
    {
      "id":"resp_synthetic_002","model":"gpt-5.6-sol","status":"completed",
      "output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]
    }
    """#.utf8)

    private static let validWikiText = #"{"overview":{"text":"Resumo sintético.","sources":["F1"]},"sections":[],"facts":[]}"#

    private static let validWikiTextWithFact = #"{"overview":{"text":"Resumo sintético.","sources":["F1"]},"sections":[],"facts":[{"kind":"measurement","label":"Peso","text":"Peso documentado.","source":"F1","quote":"Peso 72 kg.","date":"2026-09-01","clinicalStatus":"unknown","certainty":"unknown","medicationUse":"unknown","dosage":"","measurement":"weight","value":"72","unit":"kg","method":"","observationStatus":"unknown"}]}"#

    private static func responsesEnvelope(text: String, status: String = "completed") -> Data {
        let object: [String: Any] = [
            "id": "resp_synthetic_wiki",
            "object": "response",
            "status": status,
            "model": "gpt-5.6-terra-2026-09-01",
            "output": [[
                "id": "msg_synthetic_wiki",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "annotations": [],
                    "logprobs": [],
                    "text": text
                ]]
            ]],
            "usage": ["input_tokens": 123, "output_tokens": 321, "total_tokens": 444]
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func response(status: String, content: String) -> Data {
        Data("""
        {"id":"resp_synthetic","model":"gpt-5.6-sol","status":"\(status)","output":[{"type":"message","content":[\(content)]}]}
        """.utf8)
    }
}

private actor OpenAIRecordingTransport: OpenAITextTransport {
    private let statusCode: Int
    private let responseData: Data
    private let delayNanoseconds: UInt64
    private var capturedRequests: [URLRequest] = []

    init(statusCode: Int, data: Data, delayNanoseconds: UInt64 = 0) {
        self.statusCode = statusCode
        responseData = data
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }

    func requests() -> [URLRequest] { capturedRequests }
}

private struct OpenAITimedOutTransport: OpenAITextTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        throw URLError(.timedOut)
    }
}
