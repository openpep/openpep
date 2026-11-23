// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor struct PatientQuestionWikiIPSTests {
    @Test func currentWikiAndAcceptedIPSUseOnlySelectedOriginalSources() async throws {
        try await withFixture { fixture in
            let context = try PatientWikiContext.load(context: fixture.history, corrections: "")
            let first = try #require(context.entries.first { $0.id == fixture.firstID })
            let second = try #require(context.entries.first { $0.id == fixture.secondID })
            let registration = try #require(context.entries.first { $0.source == "patient.yaml" })
            let accepted = fact(first, patient: fixture.patient, text: "IPS_ACEITO_SINTETICO")
            let rejected = fact(second, patient: fixture.patient, text: "IPS_REJEITADO_SINTETICO")
            _ = try saveSummary(fixture, context: context, sources: [first, second, registration],
                markdown: "# Resumo breve\n\nWIKI_PRIMEIRA_SINTETICA [F1]\n\nWIKI_SEGUNDA_SINTETICA [F2]\n\nWIKI_COMPARTILHADA_SINTETICA [F1] [F2]\n\nWIKI_CADASTRO_NAO_ENVIAR [F3]\n\nWIKI_SEM_REFERENCIA_NAO_ENVIAR", proposals: [accepted, rejected])
            try PatientWikiStore().saveReviews([review(accepted), review(rejected, decision: .rejected)],
                for: fixture.patient, expectedData: nil, validateSources: {})
            let summaryBefore = try Data(contentsOf: fixture.patient.url.appending(path: "wiki/summary.md"))
            let reviewsBefore = try Data(contentsOf: fixture.patient.url.appending(path: "wiki/review.json"))
            let result = try await PatientQuestionService().answer(question: "O que está registrado?", context: fixture.history,
                selected: [first.id]) { input, instructions in
                    #expect(input.contains("WIKI_PRIMEIRA_SINTETICA [F1]") && input.contains("IPS_ACEITO_SINTETICO"))
                    #expect(!input.contains("WIKI_SEGUNDA_SINTETICA") && !input.contains("WIKI_COMPARTILHADA_SINTETICA"))
                    #expect(!input.contains("WIKI_CADASTRO_NAO_ENVIAR") && !input.contains("WIKI_SEM_REFERENCIA_NAO_ENVIAR"))
                    #expect(!input.contains("IPS_REJEITADO_SINTETICO") && !input.contains("Profissional Revisor Sintético"))
                    #expect(!input.contains("FONTE_SEGUNDA_SINTETICA") && !input.contains("[F2]"))
                    #expect(instructions.contains("Se fornecidos") && instructions.contains("fonte soberana"))
                    #expect(input.contains("Trecho da evidência [F1]: " + first.text))
                    return .init(text: "Registro sintético [F1].", model: "synthetic", responseID: "synthetic")
                }
            #expect(result.entries.map(\.id) == [first.id])
            #expect(result.wikiReadingSnapshot?.entries.map(\.id) == [first.id])
            #expect(result.promptVersion == "openpep/patient-history-question-openai-pt-BR@4")
            let clinical = try PatientAIContext.load(context: fixture.history, corrections: "", includeDrafts: false)
            #expect(result.sourceFingerprint == clinical.fingerprint)
            #expect(try Data(contentsOf: fixture.patient.url.appending(path: "wiki/summary.md")) == summaryBefore)
            #expect(try Data(contentsOf: fixture.patient.url.appending(path: "wiki/review.json")) == reviewsBefore)
        }
    }

    @Test(arguments: ["outdated", "missing", "invalid"])
    func unavailableWikiDoesNotReplaceSourcesOrValidAcceptedFacts(state: String) async throws {
        try await withFixture { fixture in
            let context = try PatientWikiContext.load(context: fixture.history, corrections: "")
            let first = try #require(context.entries.first { $0.id == fixture.firstID })
            let accepted = fact(first, patient: fixture.patient, text: "IPS_AINDA_ELEGIVEL")
            if state != "missing" {
                _ = try saveSummary(fixture, context: context, sources: context.entries,
                    markdown: "WIKI_ANTIGA_NAO_ENVIAR [F1]", proposals: [accepted])
            }
            try PatientWikiStore().saveReview(review(accepted), for: fixture.patient, expectedData: nil, validateSources: {})
            if state == "outdated" {
                _ = try PatientWikiStore().saveCorrections(for: fixture.patient, markdown: "Correção humana sintética nova.", expectedData: nil)
            } else if state == "invalid" {
                try Data("invalid summary".utf8).write(to: fixture.patient.url.appending(path: "wiki/summary.md"), options: .atomic)
            }
            let result = try await PatientQuestionService().answer(question: "Qual o registro?", context: fixture.history) { input, _ in
                #expect(!input.contains("WIKI_ANTIGA_NAO_ENVIAR"))
                #expect(input.contains("FONTE_PRIMEIRA_SINTETICA") && input.contains("IPS_AINDA_ELEGIVEL"))
                #expect(input.contains(state == "missing" ? "Wiki: ausente" : state == "invalid" ? "Wiki: indisponível" : "Wiki: desatualizada"))
                return .init(text: "Registro sintético [F1].", model: "synthetic", responseID: "synthetic")
            }
            #expect(result.entries.count == 2 && result.wikiReadingSnapshot?.wikiParagraphs.isEmpty == true)
        }
    }

    @Test func conflictingAcceptedFactsRemainExplicitAndInvalidReviewsRemainUnavailable() async throws {
        try await withFixture { fixture in
            let context = try PatientWikiContext.load(context: fixture.history, corrections: "")
            let first = try #require(context.entries.first { $0.id == fixture.firstID })
            let active = fact(first, patient: fixture.patient, text: "IPS_CONFLITO_ATIVO", status: "active")
            let resolved = fact(first, patient: fixture.patient, text: "IPS_CONFLITO_RESOLVIDO", status: "resolved")
            try PatientWikiStore().saveReviews([review(active), review(resolved)], for: fixture.patient,
                expectedData: nil, validateSources: {})
            _ = try await PatientQuestionService().answer(question: "O que consta?", context: fixture.history) { input, _ in
                #expect(input.contains("Conflito documental pendente: Condição sintética: IPS_CONFLITO_ATIVO"))
                #expect(input.contains("Conflito documental pendente: Condição sintética: IPS_CONFLITO_RESOLVIDO"))
                return .init(text: "Registros conflitantes para revisão [F1].", model: "synthetic", responseID: "synthetic")
            }
            try Data("invalid review".utf8).write(to: fixture.patient.url.appending(path: "wiki/review.json"), options: .atomic)
            _ = try await PatientQuestionService().answer(question: "O que consta?", context: fixture.history) { input, _ in
                #expect(input.contains("As revisões do IPS não estão disponíveis"))
                #expect(!input.contains("IPS_CONFLITO_ATIVO") && !input.contains("IPS_CONFLITO_RESOLVIDO"))
                #expect(input.contains("FONTE_PRIMEIRA_SINTETICA"))
                return .init(text: "Fonte sintética disponível [F1].", model: "synthetic", responseID: "synthetic")
            }
        }
    }

    @Test(arguments: [false, true])
    func changedSummaryOrReviewRejectsResponse(changeReview: Bool) async throws {
        try await withFixture { fixture in
            let context = try PatientWikiContext.load(context: fixture.history, corrections: "")
            let first = try #require(context.entries.first { $0.id == fixture.firstID })
            let accepted = fact(first, patient: fixture.patient, text: "IPS_ACEITO_SINTETICO")
            let summary = try saveSummary(fixture, context: context, sources: context.entries,
                markdown: "Wiki sintética. [F1]", proposals: [accepted])
            try PatientWikiStore().saveReview(review(accepted), for: fixture.patient, expectedData: nil, validateSources: {})
            do {
                _ = try await PatientQuestionService().answer(question: "O que consta?", context: fixture.history) { _, _ in
                    if changeReview {
                        let (_, data) = try PatientWikiStore().loadReviews(for: fixture.patient)
                        try PatientWikiStore().saveReview(review(accepted, decision: .rejected), for: fixture.patient,
                            expectedData: data, validateSources: {})
                    } else {
                        _ = try saveSummary(fixture, context: context, sources: context.entries,
                            markdown: "Wiki substituída. [F1]", expected: summary.persistedData)
                    }
                    return .init(text: "Proposta antiga [F1].", model: "synthetic", responseID: "synthetic")
                }
                Issue.record("Response must not survive a changed wiki or IPS review")
            } catch PatientAIIssue.changed {}
        }
    }

    @Test func combinedLimitRejectsRequestWithoutTruncatingWiki() async throws {
        try await withFixture(firstText: String(repeating: "Texto sintético. ", count: 5_000)) { fixture in
            let context = try PatientWikiContext.load(context: fixture.history, corrections: "")
            _ = try saveSummary(fixture, context: context, sources: context.entries,
                markdown: String(repeating: "Síntese sintética. ", count: 6_000) + " [F1]")
            do {
                _ = try await PatientQuestionService().answer(question: "Resumo?", context: fixture.history) { _, _ in
                    Issue.record("Oversized combined input must not request a response")
                    return .init(text: "Não deveria executar", model: "synthetic", responseID: "synthetic")
                }
                Issue.record("Expected combined context limit")
            } catch PatientAIIssue.tooLong {}
        }
    }

    @Test func cancelledRequestCannotReturnDerivedAnswer() async throws {
        try await withFixture { fixture in
            let gate = QuestionResponseGate()
            let task = Task {
                try await PatientQuestionService().answer(question: "Resumo?", context: fixture.history) { _, _ in
                    await gate.wait()
                    return .init(text: "Resposta tardia [F1].", model: "synthetic", responseID: "synthetic")
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while gate.continuation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(gate.continuation != nil)
            task.cancel()
            gate.continuation?.resume()
            do { _ = try await task.value; Issue.record("Cancelled response must not publish") }
            catch is CancellationError {}
        }
    }

    private struct Fixture {
        let patient: PatientSummary
        let history: PatientHistoryContext
        let firstID = "asset_0198f5d2-0000-7000-8000-000000000551"
        let secondID = "asset_0198f5d2-0000-7000-8000-000000000552"
    }
    private func fact(_ entry: PatientHistoryEntry, patient: PatientSummary, text: String, status: String = "active") -> PatientWikiFact {
        .init(patientID: patient.patientID, draft: .init(kind: .problem, label: "Condição sintética", text: text,
            source: entry.id, quote: entry.text, clinicalStatus: status), source: source(entry))
    }
    private func source(_ entry: PatientHistoryEntry) -> PatientWikiSource {
        .init(id: entry.id, path: entry.source, sha256: PatientAIContext.digest(Data(entry.text.utf8)))
    }
    private func review(_ fact: PatientWikiFact, decision: PatientWikiReview.Decision = .accepted) -> PatientWikiReview {
        .init(fact: fact, decision: decision, reviewer: "Profissional Revisor Sintético", reviewedAt: "2026-09-17T12:00:00Z")
    }
    private func saveSummary(_ fixture: Fixture, context: PatientWikiContext, sources: [PatientHistoryEntry],
                             markdown: String, proposals: [PatientWikiFact] = [], expected: Data? = nil) throws -> PatientWikiSummary {
        try PatientWikiStore().saveSummary(for: fixture.patient,
            input: .init(markdown: markdown, sourceFingerprint: context.fingerprint, model: "synthetic",
                generatedAt: "2026-09-17T12:00:00Z", sources: sources.map(source), overview: "Resumo sintético.",
                exclusions: context.exclusions, proposals: proposals, promptVersion: PatientWikiGeneration.prompt.id),
            expectedData: expected, expectedCorrectionsData: nil)
    }
    private func withFixture(firstText: String = "FONTE_PRIMEIRA_SINTETICA. Condição sintética registrada.",
                             _ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "question-wiki-ips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try VaultCreator().create(in: directory, identity: .init(
            vaultID: "vlt_0198f5c0-0000-7000-8000-000000000551", deviceID: "dev_0198f5c1-0000-7000-8000-000000000551"), createdAt: Date())
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-000000000551"),
            input: .init(fullName: "Ana Fictícia", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []))
        let fixture = Fixture(patient: patient, history: .init(patientID: patient.patientID, patientName: patient.displayName,
            vaultURL: vault.url, authorizationURL: vault.url, insertionEncounter: nil))
        for (id, text, date) in [(fixture.firstID, firstText, "2026-09-01T12:00:00Z"),
                                 (fixture.secondID, "FONTE_SEGUNDA_SINTETICA. Registro sintético adicional.", "2026-09-02T12:00:00Z")] {
            let file = directory.appending(path: id + ".txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            _ = try GeneralDocumentImporter().importDocument(from: file, into: patient, encounterID: nil,
                deviceID: vault.manifest.deviceID, identity: .init(assetID: id), importedAt: ISO8601DateFormatter().date(from: date)!)
        }
        try await body(fixture)
    }
}

@MainActor private final class QuestionResponseGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
}
