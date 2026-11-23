// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import OpenPEP

@MainActor struct PatientQuestionServiceTests {
    @Test func verifiesSourcesCorrectionsAndRejectsChangedOrInventedSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "patient-question-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try VaultCreator().create(in: directory, identity: .init(
            vaultID: "vlt_0198f5c0-0000-7000-8000-000000000321",
            deviceID: "dev_0198f5c1-0000-7000-8000-000000000321"), createdAt: Date())
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-000000000321"),
            input: .init(fullName: "Ana Fictícia", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []))
        let context = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
            vaultURL: vault.url, authorizationURL: vault.url, insertionEncounter: nil)
        let service = PatientQuestionService()
        do {
            _ = try await service.answer(question: "Creatinina?", context: context) { _, _ in
                Issue.record("No sources must not request a response"); return syntheticAssistantAnswer().result
            }
            Issue.record("Expected no sources")
        } catch PatientAIIssue.noSources {}
        let sourceURL = directory.appending(path: "Exame-sintetico.txt")
        try "Coleta 01/09/2026. Creatinina 1,0 mg/dL; ureia 35 mg/dL.".write(to: sourceURL, atomically: true, encoding: .utf8)
        _ = try GeneralDocumentImporter().importDocument(from: sourceURL, into: patient, encounterID: nil,
            deviceID: vault.manifest.deviceID, identity: .init(assetID: "asset_0198f5d2-0000-7000-8000-000000000321"), importedAt: Date())
        _ = try ClinicalDraftCreator().create(in: patient, identity: .init(
            encounterID: "enc_0198f5c3-0000-7000-8000-000000000321",
            noteID: "note_0198f5c4-0000-7000-8000-000000000321",
            syntheticActorID: "usr_0198f5c5-0000-7000-8000-000000000321"), startedAt: Date())
        let draftPatient = try VaultReader().open(vault.url).patients[0]
        let savedDraft = try ClinicalDraftSaver().save(encounter: draftPatient.encounters[0], patientID: patient.patientID,
            body: "RASCUNHO_SINTETICO_NAO_ENVIAR", updatedAt: Date())
        let draftBytes = try Data(contentsOf: savedDraft.url)
        let corrections = try PatientWikiStore().saveCorrections(for: patient, markdown: "Correção humana sintética", expectedData: nil)
        let result = try await service.answer(question: "Qual a última creatinina?", context: context) { input, instructions in
            #expect(input.contains("[F1]") && input.contains("1,0 mg/dL") && input.contains("Correção humana sintética"))
            #expect(!input.contains("RASCUNHO_SINTETICO_NAO_ENVIAR"))
            #expect(instructions.contains("Data de importação não é data de exame"))
            return syntheticAssistantAnswer().result
        }
        #expect(try Data(contentsOf: savedDraft.url) == draftBytes)
        #expect(result.entries.count == 1 && result.corrections == corrections.markdown)
        do {
            _ = try await service.answer(question: "Creatinina?", context: context) { _, _ in
                .init(text: "Resultado [F99]", model: "synthetic", responseID: "synthetic")
            }
            Issue.record("Invented source accepted")
        } catch OpenAITextIssue.invalidResponse {}
        do {
            _ = try await service.answer(question: "Creatinina?", context: context) { _, _ in
                _ = try PatientWikiStore().saveCorrections(for: patient, markdown: "Correção alterada", expectedData: corrections.persistedData)
                return syntheticAssistantAnswer().result
            }
            Issue.record("Changed corrections accepted")
        } catch PatientAIIssue.changed {}
        let current = try VaultReader().open(vault.url).patients[0]
        do {
            _ = try await service.answer(question: "Creatinina?", context: context) { _, _ in
                try FileManager.default.removeItem(at: current.rawAssets[0].originalURL)
                return syntheticAssistantAnswer().result
            }
            Issue.record("Removed source accepted")
        } catch {}
    }
}
