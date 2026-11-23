// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientWikiFactEvidenceNormalizationTests {
    @Test("evidence matching tolerates canonical Unicode composition and whitespace")
    func canonicalCompositionAndWhitespace() throws {
        let context = try context(text: "Paciente relata café\u{00A0}\ncom leite.")
        let draft = PatientWikiFactDraft(kind: .problem, label: "Café com leite",
            text: "Relato sintético.", source: "F1", quote: "Paciente relata cafe\u{301} com leite.")

        let facts = try PatientWikiFact.bind([draft], to: context)
        #expect(facts.count == 1)
        #expect(facts[0].matches(context.entries))
    }

    @Test("evidence matching still rejects changed number, negation, and unavailable source")
    func clinicalMeaningAndSourceRemainStrict() throws {
        let context = try context(text: "Peso 72 kg. Paciente nega febre.")

        var number = weight()
        number.value = "73"
        number.quote = "Peso 73 kg."
        var numberDiagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bind([number], to: context,
                diagnostic: { numberDiagnostic = $0 })
        }
        #expect(numberDiagnostic?.code == .quoteMismatch)

        let negation = PatientWikiFactDraft(kind: .problem, label: "Febre",
            text: "Relato sintético.", source: "F1",
            quote: "Paciente não nega febre.")
        var negationDiagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bind([negation], to: context,
                diagnostic: { negationDiagnostic = $0 })
        }
        #expect(negationDiagnostic?.code == .quoteMismatch)

        var unavailable = weight()
        unavailable.source = "F9"
        var sourceDiagnostic: PatientWikiFactBindingDiagnostic?
        #expect(throws: OpenAITextIssue.invalidResponse) {
            try PatientWikiFact.bind([unavailable], to: context,
                diagnostic: { sourceDiagnostic = $0 })
        }
        #expect(sourceDiagnostic?.code == .sourceReference)
    }

    @Test("IPS record dates accept finalized encounter headers only in the documented domains")
    func ipsEncounterDates() throws {
        let text = "Cefaleias recorrentes. Relata caminhada. Alergia relatada. Peso 72 kg."
        let source = try context(text: text)
        for kind in [PatientWikiFactKind.problem, .allergy, .socialHistory, .measurement] {
            var draft = kind == .measurement ? weight() : PatientWikiFactDraft(kind: kind,
                label: "Relato sintético", text: text, source: "F1", quote: text, date: "2026-09-01")
            draft.ips = .init(socialDomain: kind == .socialHistory ? "activity" : "")
            #expect(try PatientWikiFact.bind([draft], to: source).count == 1)
            for path in ["raw/import.txt", "patient.yaml", "content/notes/addenda/synthetic.md"] {
                let imported = try context(text: text, sourcePath: path)
                #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([draft], to: imported) }
            }
            draft.date = "2026-08-31"
            #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([draft], to: source) }
        }
    }

    @Test("encounter date never supplies event, medication or next dates; explicit dates still bind")
    func ipsEventDatesRemainStrict() throws {
        for kind in [PatientWikiFactKind.medication, .procedure, .result, .screening, .immunization] {
            var draft = PatientWikiFactDraft(kind: kind, label: "Registro sintético", text: "Registro sintético.",
                source: "F1", quote: "Registro sintético.", date: "2026-09-01", ips: .init())
            let source = try context(text: draft.quote)
            #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([draft], to: source) }
            let dated = try context(text: draft.quote + " Data clínica: 01/09/2026.")
            #expect(try PatientWikiFact.bind([draft], to: dated).count == 1)
            if kind == .screening || kind == .immunization {
                draft.date = ""; draft.ips?.nextDate = "2026-09-01"
                #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([draft], to: source) }
            }
        }
    }

    private let patientID = "pt_0198f700-0000-7000-8000-000000000191"

    private func context(text: String, sourcePath: String = "content/notes/final/synthetic.md") throws -> PatientWikiContext {
        let record = PatientRecord(schema: "openpep/patient@1", patientID: patientID,
            status: .active, fullName: "Pessoa Sintética da Evidência", preferredName: nil,
            birthDate: nil, contacts: [], identifiers: [], alerts: [],
            createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-01T12:00:00Z",
            archivedAt: nil, extensions: [:])
        let patient = PatientSummary(patientID: patientID,
            url: URL(fileURLWithPath: "/synthetic/" + patientID), record: record,
            rawAssets: [], encounters: [])
        let source = PatientHistoryEntry(
            id: "enc_0198f700-0000-7000-8000-000000000191",
            title: "Consulta sintética", timestamp: "2026-09-01T12:00:00Z",
            status: "Finalizada", text: text,
            source: sourcePath, assetID: nil, issue: nil)
        return try PatientWikiContext.make(patient: patient, entries: [source], corrections: "")
    }

    private func weight() -> PatientWikiFactDraft {
        PatientWikiFactDraft(kind: .measurement, label: "Peso", text: "Peso registrado.",
            source: "F1", quote: "Peso 72 kg.", date: "2026-09-01",
            measurement: "weight", value: "72", unit: "kg")
    }
}
