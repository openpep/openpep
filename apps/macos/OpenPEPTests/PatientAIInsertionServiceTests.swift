// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import OpenPEP

@Suite("PATIENT-AI-001 repeated accepted proposals")
struct PatientAIInsertionServiceTests {
    @Test("Swift reads the two-generation clinical-note@3 fixture")
    func validatesV3Fixture() throws {
        let root = repositoryRoot.appending(path: "fixtures/clinical-draft-v3")
        let validURL = root.appending(path: "valid/two-generations/draft.md")
        let parsed = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: validURL),
            source: validURL.path
        )
        #expect(parsed.metadata.schema == "openpep/clinical-note@3")
        #expect(parsed.metadata.aiAssistance.generations.count == 2)
        #expect(parsed.metadata.aiAssistance.generations[1].engine == "openai/responses")
        #expect(parsed.metadata.aiAssistance.generations.map(\.sourceID) == parsed.metadata.sourceIDs)

        let invalidURL = root.appending(path: "invalid/duplicate-generation/draft.md")
        do {
            _ = try ClinicalDocumentValidator.validateDraft(
                data: Data(contentsOf: invalidURL),
                source: invalidURL.path
            )
            Issue.record("a geração duplicada deveria ser recusada")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.duplicate_generation")
        }

        let mismatchURL = root.appending(path: "invalid/provenance-mismatch/draft.md")
        do {
            _ = try ClinicalDocumentValidator.validateDraft(
                data: Data(contentsOf: mismatchURL),
                source: mismatchURL.path
            )
            Issue.record("o perfil de proveniência divergente deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.ai_provenance_profile")
        }
    }

    @Test("Swift reads progressive-summary clinical-note@4 fixtures")
    func validatesV4Fixture() throws {
        let root = repositoryRoot.appending(path: "fixtures/clinical-draft-v4")
        let validURL = root.appending(path: "valid/two-generations/draft.md")
        let parsed = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: validURL),
            source: validURL.path
        )
        #expect(parsed.metadata.schema == "openpep/clinical-note@4")
        #expect(parsed.metadata.aiAssistance.generations.count == 2)
        #expect(parsed.metadata.aiAssistance.generations.map(\.sourceID) == parsed.metadata.sourceIDs)
        #expect(parsed.metadata.aiAssistance.generations[0].model == nil)
        #expect(parsed.metadata.aiAssistance.generations[1].model == "gpt-4o")

        for name in ["openai-missing-response", "apple-with-model", "mismatched-sources"] {
            let invalidURL = root.appending(path: "invalid/\(name)/draft.md")
            do {
                _ = try ClinicalDocumentValidator.validateDraft(
                    data: Data(contentsOf: invalidURL),
                    source: invalidURL.path
                )
                Issue.record("\(name) deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect([
                    "clinical_document.ai_provenance_profile",
                    "clinical_document.ai_source_set_mismatch",
                ].contains(issue.rule))
            }
        }
    }

    @Test("inserts twice, preserves both sources, refuses a duplicate, and finalizes")
    func insertsRepeatedProposalsAndFinalizes() throws {
        try withFixture { fixture in
            var patient = fixture.patient
            var encounter = fixture.encounter
            let first = try PatientAIInsertionService().insert(
                result: response("1"),
                sourceText: "Pergunta sintética 1\n\nFonte sintética integral 1\n",
                acceptedText: "Primeira proposta sintética editada.",
                generationID: firstGenerationID,
                promptVersion: AIPromptCatalog.patientHistoryOpenAI.id,
                into: encounter,
                patient: patient,
                deviceID: fixture.vault.manifest.deviceID,
                updatedAt: acceptedAt
            )
            #expect(first.metadata.schema == "openpep/clinical-note@3")
            #expect(first.metadata.aiAssistance.generations.count == 1)
            #expect(first.metadata.aiAssistance.generations[0].promptVersion == AIPromptCatalog.patientHistoryOpenAI.id)
            #expect(first.body.contains("Primeira proposta sintética editada."))

            var reopened = try VaultReader().open(fixture.vault.url)
            patient = reopened.patients[0]
            encounter = patient.encounters[0]
            let second = try PatientAIInsertionService().insert(
                result: response("2"),
                sourceText: "Pergunta sintética 2\n\nFonte sintética integral 2\nCorreção sintética\n",
                acceptedText: "Segunda proposta sintética aceita.",
                generationID: secondGenerationID,
                into: encounter,
                patient: patient,
                deviceID: fixture.vault.manifest.deviceID,
                updatedAt: acceptedAt.addingTimeInterval(60)
            )
            #expect(second.metadata.sourceIDs.count == 2)
            #expect(second.metadata.aiAssistance.generations.map(\.generationID) == [
                firstGenerationID, secondGenerationID,
            ])
            #expect(second.metadata.aiAssistance.generations.map(\.model) == [
                "gpt-5.6-sol-synthetic-1", "gpt-5.6-sol-synthetic-2",
            ])

            reopened = try VaultReader().open(fixture.vault.url)
            patient = reopened.patients[0]
            encounter = patient.encounters[0]
            #expect(patient.rawAssets.count == 2)
            let sourceTexts = try patient.rawAssets.map {
                try String(contentsOf: $0.originalURL, encoding: .utf8)
            }
            #expect(sourceTexts.contains("Pergunta sintética 1\n\nFonte sintética integral 1\n"))
            #expect(sourceTexts.contains("Pergunta sintética 2\n\nFonte sintética integral 2\nCorreção sintética\n"))
            let beforeDuplicate = encounter.draft.persistedData
            do {
                _ = try PatientAIInsertionService().insert(
                    result: response("2"),
                    sourceText: "Fonte que não deve ser importada",
                    acceptedText: "Texto que não deve ser duplicado",
                    generationID: secondGenerationID,
                    into: encounter,
                    patient: patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    updatedAt: acceptedAt.addingTimeInterval(120)
                )
                Issue.record("a geração repetida deveria ser recusada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "patient_ai.duplicate_generation")
            }
            reopened = try VaultReader().open(fixture.vault.url)
            #expect(reopened.patients[0].encounters[0].draft.persistedData == beforeDuplicate)
            #expect(reopened.patients[0].rawAssets.count == 2)

            _ = try ClinicalFinalizer().finalize(
                patient: reopened.patients[0],
                encounter: reopened.patients[0].encounters[0],
                identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000321"),
                finalizedAt: acceptedAt.addingTimeInterval(180)
            )
            reopened = try VaultReader().open(fixture.vault.url)
            guard case .verified = reopened.patients[0].encounters[0].finalizationStatus else {
                Issue.record("o rascunho @3 deveria finalizar após releitura")
                return
            }
        }
    }

    @Test("migrates clinical-note@2 without losing its local summary provenance")
    func migratesV2Provenance() throws {
        try withFixture { fixture in
            let summary = summaryProposal
            _ = try ConsultationSummaryInsertionService().insert(
                summary,
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                reviewedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(
                    assetID: "asset_0198f5d7-0000-7000-8000-000000000321"
                ),
                updatedAt: acceptedAt
            )
            var reopened = try VaultReader().open(fixture.vault.url)
            let legacyDraftURL = reopened.patients[0].encounters[0].draft.url
            let legacyText = try String(contentsOf: legacyDraftURL, encoding: .utf8)
            let laterEdit = legacyText.replacingOccurrences(
                of: #"(?m)^updated_at:.*$"#,
                with: "updated_at: \(yamlQuoted(timestamp(acceptedAt.addingTimeInterval(30))))",
                options: .regularExpression
            )
            try Data(laterEdit.utf8).write(to: legacyDraftURL, options: [.atomic])
            reopened = try VaultReader().open(fixture.vault.url)
            let saved = try PatientAIInsertionService().insert(
                result: response("3"),
                sourceText: "Pergunta e contexto sintéticos posteriores.",
                acceptedText: "Nova proposta sintética.",
                generationID: secondGenerationID,
                into: reopened.patients[0].encounters[0],
                patient: reopened.patients[0],
                deviceID: fixture.vault.manifest.deviceID,
                updatedAt: acceptedAt.addingTimeInterval(60)
            )
            #expect(saved.metadata.schema == "openpep/clinical-note@3")
            #expect(saved.metadata.aiAssistance.generations.count == 2)
            let legacy = saved.metadata.aiAssistance.generations[0]
            #expect(legacy.generationID == firstGenerationID)
            #expect(legacy.provenanceSchema == ConsultationSummaryProvenance.schema)
            #expect(legacy.engine == ConsultationSummaryProvenance.engine)
            #expect(legacy.promptVersion == ConsultationSummaryProvenance.promptVersion)
            #expect(legacy.chunkCount == 1)
            #expect(legacy.model == nil)
            #expect(legacy.acceptedAt == nil)
            reopened = try VaultReader().open(fixture.vault.url)
            #expect(reopened.patients[0].rawAssets.count == 2)
        }
    }

    @Test("rolls back the new source and draft after an interrupted publication")
    func rollsBackInterruptedPublication() throws {
        try withFixture { fixture in
            let previous = fixture.encounter.draft.persistedData
            let service = PatientAIInsertionService(faultInjector: { step in
                if step == .draftPublished { throw PatientAISyntheticFailure() }
            })
            #expect(throws: PatientAISyntheticFailure.self) {
                _ = try service.insert(
                    result: response("4"),
                    sourceText: "Fonte sintética de rollback.",
                    acceptedText: "Proposta sintética de rollback.",
                    generationID: firstGenerationID,
                    into: fixture.encounter,
                    patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    updatedAt: acceptedAt
                )
            }
            let reopened = try VaultReader().open(fixture.vault.url)
            #expect(reopened.patients[0].encounters[0].draft.persistedData == previous)
            #expect(reopened.patients[0].rawAssets.isEmpty)
        }
    }

    @Test("checks the snapshot immediately before swap and preserves concurrent state")
    func rejectsConcurrentDraftAndFinalChanges() throws {
        try withFixture { fixture in
            let externalDraft = fixture.encounter.draft.persistedData + Data("\nEdição externa sintética.\n".utf8)
            let draftConflict = PatientAIInsertionService(faultInjector: { step in
                if step == .draftTemporaryWritten {
                    try externalDraft.write(to: fixture.encounter.draft.url, options: [.atomic])
                }
            })
            do {
                _ = try draftConflict.insert(
                    result: response("5"), sourceText: "Fonte concorrente sintética.",
                    acceptedText: "Proposta concorrente sintética.", generationID: firstGenerationID,
                    into: fixture.encounter, patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID, updatedAt: acceptedAt
                )
                Issue.record("a edição concorrente deveria impedir a publicação")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "patient_ai.rollback_failed")
            }
            #expect(try Data(contentsOf: fixture.encounter.draft.url) == externalDraft)
            #expect(try rawRegularFiles(in: fixture.patient.url).count == 2)
        }

        try withFixture { fixture in
            let finalURL = fixture.patient.url.appending(path: "content/notes/final/\(noteID).md")
            let finalBytes = Data("finalização concorrente sintética".utf8)
            let finalConflict = PatientAIInsertionService(faultInjector: { step in
                if step == .draftTemporaryWritten {
                    try FileManager.default.createDirectory(
                        at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try finalBytes.write(to: finalURL, options: [.withoutOverwriting])
                }
            })
            do {
                _ = try finalConflict.insert(
                    result: response("6"), sourceText: "Fonte finalizada sintética.",
                    acceptedText: "Proposta finalizada sintética.", generationID: firstGenerationID,
                    into: fixture.encounter, patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID, updatedAt: acceptedAt
                )
                Issue.record("a finalização concorrente deveria impedir a publicação")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "patient_ai.rollback_failed")
            }
            #expect(try Data(contentsOf: finalURL) == finalBytes)
            #expect(try rawRegularFiles(in: fixture.patient.url).count == 2)
        }
    }

    @Test("leaves interrupted recovery files inert and keeps altered source bytes")
    func toleratesRecoveryLeftoverAndPreservesChangedSource() throws {
        try withFixture { fixture in
            let recovery = fixture.vault.url.appending(path: "recovery", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
            let leftover = recovery.appending(path: "clinical-draft-interrupted.md")
            try fixture.encounter.draft.persistedData.write(to: leftover)
            _ = try PatientAIInsertionService().insert(
                result: response("7"), sourceText: "Fonte com recovery sintética.",
                acceptedText: "Proposta com recovery sintética.", generationID: firstGenerationID,
                into: fixture.encounter, patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID, updatedAt: acceptedAt
            )
            #expect(FileManager.default.fileExists(atPath: leftover.path))
            #expect(try VaultReader().open(fixture.vault.url).patients[0].rawAssets.count == 1)
        }

        try withFixture { fixture in
            let altered = Data("fonte alterada externamente\n".utf8)
            let service = PatientAIInsertionService(faultInjector: { step in
                guard step == .draftTemporaryWritten,
                      let source = try rawRegularFiles(in: fixture.patient.url).first(where: {
                          $0.pathExtension == "txt"
                      }) else { return }
                try altered.write(to: source, options: [.atomic])
                throw PatientAISyntheticFailure()
            })
            do {
                _ = try service.insert(
                    result: response("8"), sourceText: "Fonte a preservar sintética.",
                    acceptedText: "Proposta que falha sintética.", generationID: firstGenerationID,
                    into: fixture.encounter, patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID, updatedAt: acceptedAt
                )
                Issue.record("a alteração da fonte deveria tornar o rollback ambíguo")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "patient_ai.rollback_failed")
            }
            let source = try rawRegularFiles(in: fixture.patient.url).first { $0.pathExtension == "txt" }
            #expect(try source.map { try Data(contentsOf: $0) } == altered)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var authorID: String { "usr_0198f4a0-0000-7000-8000-000000000321" }
    private var patientID: String { "pt_0198f5c2-0000-7000-8000-000000000321" }
    private var encounterID: String { "enc_0198f5d1-0000-7000-8000-000000000321" }
    private var noteID: String { "note_0198f5d3-0000-7000-8000-000000000321" }
    private var firstGenerationID: String { "gen_0198f5d8-0000-7000-8000-000000000321" }
    private var secondGenerationID: String { "gen_0198f5d8-0000-7000-8000-000000000322" }
    private var acceptedAt: Date { Date(timeIntervalSince1970: 1_788_586_200) }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func yamlQuoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func rawRegularFiles(in patientURL: URL) throws -> [URL] {
        let raw = patientURL.appending(path: "raw", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: raw, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    private func response(_ suffix: String) -> OpenAITextResult {
        OpenAITextResult(
            text: "Resposta sintética \(suffix)",
            model: "gpt-5.6-sol-synthetic-\(suffix)",
            responseID: "resp_synthetic_\(suffix)"
        )
    }

    private var summaryProposal: ConsultationSummaryProposal {
        let chunks = [ConsultationSummaryProvenance.SourceChunk(
            label: "trecho 1 de 1",
            text: "Paciente sintético sem fatos reais."
        )]
        let artifact = "[trecho 1 de 1]\nPaciente sintético sem fatos reais.\n"
        let hash = SHA256.hash(data: Data(artifact.utf8)).map { String(format: "%02x", $0) }.joined()
        return ConsultationSummaryProposal(
            text: "Resumo sintético aceito.",
            provenance: ConsultationSummaryProvenance(
                generationID: firstGenerationID,
                sourceSHA256: hash,
                sourceTranscript: "Paciente sintético sem fatos reais.",
                localeIdentifier: "pt-BR",
                sourceChunks: chunks,
                generatedAt: acceptedAt.addingTimeInterval(-60)
            )
        )
    }

    private func withFixture(_ body: (PatientAIFixture) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "openpep-patient-ai-tests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let vault = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-0000-7000-8000-000000000321",
                deviceID: "dev_0198f5c1-0000-7000-8000-000000000321"
            ),
            createdAt: acceptedAt.addingTimeInterval(-300)
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético da IA",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: acceptedAt.addingTimeInterval(-240)
        )
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: authorID
            ),
            startedAt: acceptedAt.addingTimeInterval(-180)
        )
        let opened = try VaultReader().open(vault.url)
        try body(PatientAIFixture(
            vault: opened,
            patient: opened.patients[0],
            encounter: opened.patients[0].encounters[0]
        ))
    }
}

private struct PatientAIFixture {
    let vault: VaultSummary
    let patient: PatientSummary
    let encounter: EncounterSummary
}

private struct PatientAISyntheticFailure: Error {}
