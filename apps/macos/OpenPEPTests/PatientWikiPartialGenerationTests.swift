// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientWikiPartialGenerationTests {
    @Test("partial binding keeps valid facts and counts local failures")
    func keepsValidFacts() throws {
        let context = try context(text: "Peso 72 kg. Paciente nega febre.")
        let invalidQuote = PatientWikiFactDraft(kind: .problem, label: "Febre",
            text: "Relato sintético.", source: "F1", quote: "Paciente não nega febre.")
        var invalidSource = weight()
        invalidSource.source = "F9"
        let duplicate = weight()

        var diagnostics: [PatientWikiFactBindingDiagnostic] = []
        let result = try PatientWikiFact.bindPartially(
            [weight(), invalidQuote, invalidSource, duplicate], to: context,
            diagnostic: { diagnostics.append($0) })

        #expect(result.facts.count == 1)
        #expect(result.omittedCount == 3)
        #expect(result.facts[0].draft.value == "72")
        #expect(diagnostics.map(\.code) == [.quoteMismatch, .sourceReference, .duplicateFact])
        #expect(result.facts.allSatisfy { $0.matches(context.entries) })
    }

    @Test("global fact volume remains an error")
    func globalVolumeRemainsError() throws {
        let context = try context()
        var diagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bindPartially(
                Array(repeating: weight(), count: 101), to: context,
                diagnostic: { diagnostic = $0 })
        }
        #expect(diagnostic?.code == .tooManyFacts)
        #expect(diagnostic?.factIndex == nil)
    }

    @Test("omitted fact count persists, remains optional for legacy summaries, and reaches IPS narrative")
    func persistsAndExportsOmission() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openpep-wiki-partial-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try context(url: directory)
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let store = PatientWikiStore()
        let candidate = PatientWikiSummaryInput(
            markdown: "# Resumo breve\n\nPeso registrado. [F1]",
            sourceFingerprint: context.fingerprint, model: "synthetic",
            generatedAt: "2026-09-13T12:00:00Z", sources: [fact.source],
            overview: "Peso registrado. [F1]", exclusions: context.exclusions,
            proposals: [fact], promptVersion: PatientWikiGeneration.prompt.id,
            omittedFactCount: 1)
        let saved = try store.saveSummary(for: context.patient, input: candidate,
            expectedData: nil, expectedCorrectionsData: nil)
        #expect(saved.omittedFactCount == 1)
        #expect(String(decoding: saved.persistedData, as: UTF8.self)
            .contains("omitted_fact_count"))
        #expect(try store.load(for: context.patient).summary?.omittedFactCount == 1)

        let reviews = PatientWikiReviews(patientID: patientID, records: [
            PatientWikiReview(fact: fact, decision: .accepted,
                reviewer: "Profissional Sintético", reviewedAt: "2026-09-13T12:01:00Z")
        ])
        let ips = try PatientWikiExport.ips(context: context, reviews: reviews,
            author: "Profissional Sintético", omittedFactCount: 1)
        let ipsText = String(decoding: ips, as: UTF8.self)
        #expect(ipsText.contains("Dados não incluídos no IPS: 1"))
        #expect(ipsText.contains("72"))
        #expect(!ipsText.contains("não nega febre"))

        let legacy = try store.saveSummary(for: context.patient,
            input: PatientWikiSummaryInput(markdown: "Legado", sourceFingerprint: context.fingerprint,
                model: "synthetic", generatedAt: "2026-09-13T12:02:00Z", sources: [fact.source]),
            expectedData: saved.persistedData, expectedCorrectionsData: nil)
        #expect(legacy.omittedFactCount == 0)
        #expect(!String(decoding: legacy.persistedData, as: UTF8.self)
            .contains("omitted_fact_count"))

        var invalidCount = candidate
        invalidCount.omittedFactCount = 101
        #expect(throws: (any Error).self) {
            try store.saveSummary(for: context.patient, input: invalidCount,
                expectedData: legacy.persistedData, expectedCorrectionsData: nil)
        }
    }

    private let patientID = "pt_0198f700-0000-7000-8000-000000000291"

    private func context(text: String = "Peso 72 kg.", url: URL? = nil) throws -> PatientWikiContext {
        let record = PatientRecord(schema: "openpep/patient@1", patientID: patientID,
            status: .active, fullName: "Pessoa Sintética Parcial", preferredName: nil,
            birthDate: nil, contacts: [], identifiers: [], alerts: [],
            createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-01T12:00:00Z",
            archivedAt: nil, extensions: [:])
        let patient = PatientSummary(patientID: patientID,
            url: url ?? URL(fileURLWithPath: "/synthetic/" + patientID), record: record,
            rawAssets: [], encounters: [])
        let source = PatientHistoryEntry(
            id: "enc_0198f700-0000-7000-8000-000000000291",
            title: "Consulta sintética", timestamp: "2026-09-01T12:00:00Z",
            status: "Finalizada", text: text,
            source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)
        return try PatientWikiContext.make(patient: patient, entries: [source], corrections: "")
    }

    private func weight() -> PatientWikiFactDraft {
        PatientWikiFactDraft(kind: .measurement, label: "Peso", text: "Peso registrado.",
            source: "F1", quote: "Peso 72 kg.", date: "2026-09-01",
            measurement: "weight", value: "72", unit: "kg")
    }
}
