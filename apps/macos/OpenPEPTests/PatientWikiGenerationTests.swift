// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientWikiGenerationTests {
    @Test("registration projection participates in provenance without sending contact data")
    func registrationProjection() throws {
        let first = try PatientWikiContext.make(patient: patient(name: "Pessoa Sintética"), entries: [], corrections: "")
        #expect(first.entries.count == 1)
        #expect(first.entries[0].source == "patient.yaml")
        #expect(first.entries[0].id == first.patient.patientID)
        #expect(first.input.contains("Pessoa Sintética"))
        #expect(first.input.contains("1990-01-01"))
        #expect(!first.input.contains("omit-contact-synthetic"))
        #expect(!first.input.contains("omit-id-synthetic"))
        #expect(!first.input.contains("omit-extension-synthetic"))
        let changed = try PatientWikiContext.make(patient: patient(name: "Nome Corrigido Sintético"), entries: [], corrections: "")
        #expect(first.fingerprint != changed.fingerprint)
        let otherPatient = patient(name: "Outro", recordID: "pt_0198f700-0000-7000-8000-000000000099")
        #expect(throws: PatientAIIssue.self) {
            try PatientWikiContext.make(patient: otherPatient, entries: [], corrections: "")
        }
    }

    @Test("coverage separates provisional and unreadable sources and never uses import date as last visit")
    func coverageAndVisit() throws {
        let visit = entry("enc_0198f700-0000-7000-8000-000000000001", "content/notes/final/visit.md", "2026-01-01T12:00:00Z")
        let draft = entry("enc_0198f700-0000-7000-8000-000000000002", "content/notes/drafts/draft.md", "2026-02-01T12:00:00Z")
        let unreadable = entry("asset_0198f700-0000-7000-8000-000000000003", "raw/image.pdf", "2026-03-01T12:00:00Z", issue: "Sem texto")
        let context = try PatientWikiContext.make(patient: patient(name: "Sintético"),
            entries: [visit, draft, unreadable], corrections: "")
        #expect(context.exclusions.drafts == 1)
        #expect(context.exclusions.unavailable == 1)
        #expect(context.input.contains("Último atendimento finalizado elegível: 2026-01-01T12:00:00Z [F1]"))
        #expect(!context.input.contains("2026-03-01"))
    }

    @Test("structured generation renders only cited sections and a separate overview")
    func generation() throws {
        let result = try PatientWikiGeneration.decode(valid, sourceCount: 2)
        #expect(result.overviewText == "Contexto sintético documentado.")
        #expect(result.markdown.contains("Contexto sintético documentado. [F1]"))
        #expect(result.markdown.contains("## Medicamentos e tratamentos"))
        #expect(!result.markdown.contains("## Exames"))
        #expect(result.markdown.contains("Uso relatado na fonte. [F2]"))
    }

    @Test("overview accepts 20 words with whitespace and accents, then rejects the 21st")
    func overviewWordLimit() throws {
        let words = [
            "João", "mantém", "quadro", "clínico", "estável", "sem", "dor", "e", "com", "seguimento",
            "ativo", "hoje", "pela", "equipe", "médica", "do", "Solo", "em", "avaliação", "regular"
        ]
        let twenty = words.enumerated().map { index, word in
            index.isMultiple(of: 3) ? word + "\u{00A0}" : word
        }.joined(separator: "  ")
        let accepted = try PatientWikiGeneration.decode(
            try validJSON(overview: twenty), sourceCount: 2)
        #expect(accepted.overviewText == twenty)
        #expect(!accepted.overviewText.contains("[F1]"))

        let twentyOne = twenty + " agora"
        #expect(throws: PatientWikiGenerationIssue.overviewTooLong(wordCount: 21, maximum: 20)) {
            try PatientWikiGeneration.decode(
                try validJSON(overview: twentyOne), sourceCount: 2)
        }
    }

    @Test("unknown, duplicate, empty and forged citations cannot be published")
    func invalidGenerations() {
        for text in [
            valid.replacingOccurrences(of: "F2", with: "F3"),
            valid.replacingOccurrences(of: "[\"F2\"]", with: "[\"F2\",\"F2\"]"),
            valid.replacingOccurrences(of: "[\"F2\"]", with: "[]"),
            valid.replacingOccurrences(of: "Uso relatado na fonte.", with: "Fato falso [F99]"),
            valid.replacingOccurrences(of: "medications", with: "new_diagnosis"),
            valid.replacingOccurrences(of: "Contexto sintético documentado.", with: String(repeating: "x", count: 501)),
            "não é JSON"
        ] {
            #expect(throws: OpenAITextIssue.invalidResponse) {
                try PatientWikiGeneration.decode(text, sourceCount: 2)
            }
        }
    }

    private let valid = #"{"facts":[],"overview":{"text":"Contexto sintético documentado.","sources":["F1"]},"sections":[{"topic":"medications","paragraphs":[{"text":"Uso relatado na fonte.","sources":["F2"]}]}]}"#

    private func validJSON(overview: String) throws -> String {
        let object: [String: Any] = [
            "facts": [],
            "overview": ["text": overview, "sources": ["F1"]],
            "sections": [[
                "topic": "medications",
                "paragraphs": [["text": "Uso relatado na fonte.", "sources": ["F2"]]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func patient(name: String, recordID: String? = nil) -> PatientSummary {
        let id = "pt_0198f700-0000-7000-8000-000000000091"
        let record = PatientRecord(schema: "openpep/patient@1", patientID: recordID ?? id, status: .active,
            fullName: name, preferredName: nil, birthDate: "1990-01-01",
            contacts: [PatientContact(type: .email, value: "omit-contact-synthetic", authorizedForCare: true)],
            identifiers: [PatientIdentifier(type: .other, value: "omit-id-synthetic")], alerts: [],
            createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-01T12:00:00Z", archivedAt: nil,
            extensions: ["x_openpep_registration": .mapping(["notes": .string("omit-extension-synthetic")])])
        return PatientSummary(patientID: id, url: URL(fileURLWithPath: "/synthetic/wiki"), record: record,
                              rawAssets: [], encounters: [])
    }

    private func entry(_ id: String, _ path: String, _ date: String, issue: String? = nil) -> PatientHistoryEntry {
        PatientHistoryEntry(id: id, title: "Fonte sintética", timestamp: date, status: "Sintético",
                            text: "Conteúdo sintético", source: path, assetID: nil, issue: issue)
    }
}
