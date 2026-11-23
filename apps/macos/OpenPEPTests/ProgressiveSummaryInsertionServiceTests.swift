// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("CONSULTATION-LIVE-001/002 progressive summary acceptance")
struct ProgressiveSummaryInsertionServiceTests {
    @Test("adds current and previous prompts, reopens the note and restores it only while unchanged", arguments: ["openpep/progressive-consultation-summary-pt-BR@4", "openpep/progressive-consultation-summary-pt-BR@5"])
    func insertsAndUndoes(prompt: String) throws {
        try withFixture { fixture in
            let result = try ProgressiveSummaryInsertionService().insert(
                block(promptVersion: prompt),
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )
            #expect(result.draft.metadata.schema == "openpep/clinical-note@4")
            #expect(result.draft.metadata.aiAssistance.generations.count == 1)
            #expect(result.draft.body.contains("Bloco sintético aceito."))
            let reopened = try VaultReader().open(fixture.vault.url)
            #expect(reopened.patients[0].encounters[0].draft.body == result.draft.body)
            #expect(try Data(contentsOf: result.source.originalURL) == result.undoToken.sourceOriginalData)
            #expect(try String(contentsOf: result.source.originalURL, encoding: .utf8)
                .contains("Texto efetivamente aceito"))

            let restored = try ProgressiveSummaryInsertionService().undo(result.undoToken)
            #expect(restored.metadata.schema == "openpep/clinical-note@1")
            #expect(restored.body == fixture.encounter.draft.body)
            #expect(FileManager.default.fileExists(atPath: result.source.originalURL.path))
        }
    }

    @Test("accepts the final Apple prompt only with its local engine")
    func bindsFinalApplePromptToEngine() throws {
        try withFixture { fixture in
            let result = try ProgressiveSummaryInsertionService().insert(
                block(
                    promptVersion: AIPromptCatalog.finalConsultationSummaryApple.id,
                    engine: "apple/FoundationModels.SystemLanguageModel",
                    model: nil,
                    responseID: nil
                ),
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )
            #expect(result.draft.metadata.aiAssistance.generations[0].promptVersion
                == AIPromptCatalog.finalConsultationSummaryApple.id)
        }
        try withFixture { fixture in
            #expect(throws: ProgressiveSummaryInsertionIssue.invalidBlock) {
                _ = try ProgressiveSummaryInsertionService().insert(
                    block(promptVersion: AIPromptCatalog.finalConsultationSummaryApple.id),
                    into: fixture.encounter,
                    patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    acceptedBy: authorID,
                    sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                    acceptedAt: acceptedAt
                )
            }
        }
    }

    @Test("refuses repeated acceptance and preserves a changed note on undo")
    func rejectsDuplicateAndStaleUndo() throws {
        try withFixture { fixture in
            let service = ProgressiveSummaryInsertionService()
            let result = try service.insert(
                block(),
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )
            let reopened = try VaultReader().open(fixture.vault.url)
            let patient = reopened.patients[0]
            let encounter = patient.encounters[0]
            do {
                _ = try service.insert(
                    block(),
                    into: encounter,
                    patient: patient,
                    deviceID: reopened.manifest.deviceID,
                    acceptedBy: authorID,
                    sourceIdentity: RawAssetCreationIdentity(assetID: alternateAssetID),
                    acceptedAt: acceptedAt.addingTimeInterval(60)
                )
                Issue.record("a geração repetida deveria ser recusada")
            } catch let error as ProgressiveSummaryInsertionIssue {
                #expect(error == .duplicateGeneration)
            }

            let changed = Data("alteração concorrente sintética\n".utf8)
            try changed.write(to: result.undoToken.draftURL, options: .atomic)
            do {
                _ = try service.undo(result.undoToken)
                Issue.record("o desfazer de uma nota alterada deveria ser recusado")
            } catch let error as ProgressiveSummaryInsertionIssue {
                #expect(error == .undoUnavailable)
            }
            #expect(try Data(contentsOf: result.undoToken.draftURL) == changed)
        }
    }

    @Test("preserves existing @3 generations when promoting the note")
    func promotesV3WithoutDiscardingProvenance() throws {
        try withFixture { fixture in
            _ = try PatientAIInsertionService().insert(
                result: OpenAITextResult(
                    text: "Proposta sintética anterior.",
                    model: "gpt-4o",
                    responseID: "resp_synthetic_previous"
                ),
                sourceText: "Fonte sintética anterior.",
                acceptedText: "Proposta sintética anterior.",
                generationID: previousGenerationID,
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                updatedAt: acceptedAt.addingTimeInterval(-60)
            )
            let reopened = try VaultReader().open(fixture.vault.url)
            let result = try ProgressiveSummaryInsertionService().insert(
                block(),
                into: reopened.patients[0].encounters[0],
                patient: reopened.patients[0],
                deviceID: reopened.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )
            #expect(result.draft.metadata.schema == "openpep/clinical-note@4")
            #expect(result.draft.metadata.aiAssistance.generations.map(\.generationID) == [
                previousGenerationID, progressiveGenerationID,
            ])
            #expect(result.draft.metadata.sourceIDs.count == 2)
        }
    }

    @Test("keeps progressive provenance when another accepted proposal is appended")
    func preservesV4WhenPatientAIIsAcceptedLater() throws {
        try withFixture { fixture in
            _ = try ProgressiveSummaryInsertionService().insert(
                block(),
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )
            let reopened = try VaultReader().open(fixture.vault.url)
            let result = try PatientAIInsertionService().insert(
                result: OpenAITextResult(
                    text: "Proposta sintética posterior.",
                    model: "gpt-4o",
                    responseID: "resp_synthetic_later"
                ),
                sourceText: "Fonte sintética posterior.",
                acceptedText: "Proposta sintética posterior.",
                generationID: previousGenerationID,
                into: reopened.patients[0].encounters[0],
                patient: reopened.patients[0],
                deviceID: reopened.manifest.deviceID,
                updatedAt: acceptedAt.addingTimeInterval(60)
            )
            #expect(result.metadata.schema == "openpep/clinical-note@4")
            #expect(result.metadata.aiAssistance.generations.map(\.generationID) == [
                progressiveGenerationID, previousGenerationID,
            ])
            #expect(result.metadata.sourceIDs.count == 2)
        }
    }

    @Test("accepts a saved summary from the previous prompt version")
    func acceptsPreviousPromptVersion() throws {
        try withFixture { fixture in
            let result = try ProgressiveSummaryInsertionService().insert(
                block(promptVersion: "openpep/progressive-consultation-summary-pt-BR@2"),
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                acceptedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: progressiveAssetID),
                acceptedAt: acceptedAt
            )

            #expect(result.draft.body.contains("Bloco sintético aceito."))
        }
    }

    private var authorID: String { "usr_0198f4a0-0000-7000-8000-000000000411" }
    private var patientID: String { "pt_0198f5c2-0000-7000-8000-000000000411" }
    private var encounterID: String { "enc_0198f5d1-0000-7000-8000-000000000411" }
    private var noteID: String { "note_0198f5d3-0000-7000-8000-000000000411" }
    private var progressiveAssetID: String { "asset_0198f5d7-0000-7000-8000-000000000411" }
    private var alternateAssetID: String { "asset_0198f5d7-0000-7000-8000-000000000412" }
    private var progressiveGenerationID: String { "gen_0198f5d8-0000-7000-8000-000000000411" }
    private var previousGenerationID: String { "gen_0198f5d8-0000-7000-8000-000000000412" }
    private var generatedAt: Date { Date(timeIntervalSince1970: 1_788_585_840) }
    private var acceptedAt: Date { generatedAt.addingTimeInterval(60) }

    private func block(
        promptVersion: String = "openpep/progressive-consultation-summary-pt-BR@3",
        engine: String = "openai/responses",
        model: String? = "gpt-4o",
        responseID: String? = "resp_synthetic_progressive"
    ) -> ConsultationSummaryBlock {
        ConsultationSummaryBlock(
            id: "block_0198f5d9-0000-7000-8000-000000000411",
            kind: .interval,
            range: ConsultationTimeRange(startSeconds: 0, endSeconds: 180, isApproximate: false),
            subject: "Queixa sintética",
            generatedText: "Bloco sintético gerado.",
            editedText: "Bloco sintético aceito.",
            state: .edited,
            generation: ConsultationSummaryGeneration(
                generationID: progressiveGenerationID,
                engine: engine,
                model: model,
                responseID: responseID,
                promptVersion: promptVersion,
                generatedAt: generatedAt,
                source: "Paciente sintético relata melhora e nega febre.",
                segmentReferences: [ConsultationTranscriptSegmentReference(
                    segmentID: "segment_0198f5da-0000-7000-8000-000000000411",
                    revision: 1
                )]
            ),
            acceptance: nil
        )
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "openpep-progressive-summary-tests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let vault = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-0000-7000-8000-000000000411",
                deviceID: "dev_0198f5c1-0000-7000-8000-000000000411"
            ),
            createdAt: generatedAt.addingTimeInterval(-300)
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético Progressivo",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: generatedAt.addingTimeInterval(-240)
        )
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: authorID
            ),
            startedAt: generatedAt.addingTimeInterval(-180)
        )
        let opened = try VaultReader().open(vault.url)
        try body(Fixture(vault: opened, patient: opened.patients[0], encounter: opened.patients[0].encounters[0]))
    }
}

private struct Fixture {
    let vault: VaultSummary
    let patient: PatientSummary
    let encounter: EncounterSummary
}
