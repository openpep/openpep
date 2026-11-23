// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import OpenPEP

struct ConsultationSummaryInsertionServiceTests {
    @Test("Swift accepts and rejects the persisted clinical-note@2 fixtures")
    func validatesV2Fixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "fixtures/clinical-draft-v2")
        let validURL = root.appending(path: "valid/reviewed-summary/draft.md")
        let parsed = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: validURL), source: validURL.path
        )
        #expect(parsed.metadata.schema == "openpep/clinical-note@2")
        #expect(parsed.metadata.aiAssistance.used)
        let nestedExtension = try ClinicalDocumentValidator.validateDraft(
            data: Data(try String(contentsOf: validURL, encoding: .utf8)
                .replacingOccurrences(
                    of: "  chunk_count: 2",
                    with: "  chunk_count: 2\n  x_review_note: synthetic"
                ).utf8),
            source: validURL.path
        )
        #expect(nestedExtension.metadata.schema == "openpep/clinical-note@2")
        let matchingEncounter = EncounterMetadata(
            encounterID: parsed.metadata.encounterID,
            patientID: parsed.metadata.patientID,
            appointmentID: nil,
            status: "in_progress",
            modality: "in_person",
            startedAt: "2026-09-05T10:00:00Z",
            createdBy: parsed.metadata.authorID,
            templateID: nil,
            templateVersion: nil,
            telemedicine: nil
        )
        try ClinicalDocumentValidator.bind(
            encounter: matchingEncounter,
            draft: parsed.metadata,
            expectedPatientID: parsed.metadata.patientID
        )
        let mismatchedReviewer = try ClinicalDocumentValidator.validateDraft(
            data: Data(try String(contentsOf: validURL, encoding: .utf8)
                .replacingOccurrences(
                    of: "reviewed_by: usr_0198f4a0-0000-7000-8000-000000000201",
                    with: "reviewed_by: usr_0198f4a0-0000-7000-8000-000000000202"
                ).utf8),
            source: validURL.path
        )
        #expect(throws: VaultValidationIssue.self) {
            try ClinicalDocumentValidator.bind(
                encounter: matchingEncounter,
                draft: mismatchedReviewer.metadata,
                expectedPatientID: parsed.metadata.patientID
            )
        }
        let invalidURL = root.appending(path: "invalid/missing-reviewer/draft.md")
        #expect(throws: VaultValidationIssue.self) {
            _ = try ClinicalDocumentValidator.validateDraft(
                data: Data(contentsOf: invalidURL), source: invalidURL.path
            )
        }
    }

    @Test("requires the recoverable AI source, encounter binding, and matching hash")
    func bindsAISourceSemantics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let validURL = root.appending(path: "fixtures/clinical-draft-v2/valid/reviewed-summary/draft.md")
        let draft = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: validURL), source: validURL.path
        ).metadata
        let source = RawAssetSummary(
            assetID: draft.sourceIDs[0],
            encounterID: draft.encounterID,
            originalName: "fonte.txt",
            importedAt: "2026-09-05T10:04:00Z",
            mediaType: "text/plain",
            fileExtension: "txt",
            sizeBytes: 1,
            sha256: draft.aiAssistance.sourceSHA256!,
            source: "local_import",
            inspectionResult: "not_inspected",
            originalURL: URL(fileURLWithPath: "/tmp/fonte-sintetica.txt")
        )
        try ClinicalDocumentValidator.bindAISource(
            draft: draft, encounterID: draft.encounterID, assets: [source]
        )
        for (assets, rule) in [
            ([], "clinical_document.ai_source_missing"),
            ([RawAssetSummary(
                assetID: source.assetID, encounterID: "enc_0198f5d1-0000-7000-8000-000000000202",
                originalName: source.originalName, importedAt: source.importedAt,
                mediaType: source.mediaType, fileExtension: source.fileExtension,
                sizeBytes: source.sizeBytes, sha256: source.sha256, source: source.source,
                inspectionResult: source.inspectionResult, originalURL: source.originalURL
            )], "clinical_document.ai_source_encounter_mismatch"),
            ([RawAssetSummary(
                assetID: source.assetID, encounterID: source.encounterID,
                originalName: source.originalName, importedAt: source.importedAt,
                mediaType: source.mediaType, fileExtension: source.fileExtension,
                sizeBytes: source.sizeBytes, sha256: String(repeating: "b", count: 64), source: source.source,
                inspectionResult: source.inspectionResult, originalURL: source.originalURL
            )], "clinical_document.ai_source_hash_mismatch"),
        ] as [([RawAssetSummary], String)] {
            do {
                try ClinicalDocumentValidator.bindAISource(
                    draft: draft, encounterID: draft.encounterID, assets: assets
                )
                Issue.record("deveria rejeitar \(rule)")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == rule)
            }
        }
    }

    @Test("persists a reviewed proposal with a recoverable source and finalizes it")
    func insertsReopensAndFinalizes() throws {
        try withFixture { fixture in
            let result = try ConsultationSummaryInsertionService().insert(
                proposal,
                into: fixture.encounter,
                patient: fixture.patient,
                deviceID: fixture.vault.manifest.deviceID,
                reviewedBy: authorID,
                sourceIdentity: RawAssetCreationIdentity(assetID: assetID),
                updatedAt: reviewedAt
            )
            #expect(result.draft.metadata.schema == "openpep/clinical-note@2")
            #expect(result.draft.metadata.sourceIDs == [assetID])
            #expect(result.draft.metadata.aiAssistance.generationID == generationID)
            #expect(try String(contentsOf: result.source.originalURL, encoding: .utf8) == proposal.provenance.sourceArtifactText)

            var reopened = try VaultReader().open(fixture.vault.url)
            let reopenedPatient = reopened.patients[0]
            #expect(reopenedPatient.encounters[0].draft.metadata.schema == "openpep/clinical-note@2")
            #expect(reopenedPatient.rawAssets.first?.encounterID == encounterID)

            _ = try ClinicalFinalizer().finalize(
                patient: reopenedPatient,
                encounter: reopenedPatient.encounters[0],
                identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000211"),
                finalizedAt: reviewedAt.addingTimeInterval(60)
            )
            reopened = try VaultReader().open(fixture.vault.url)
            guard case .verified = reopened.patients[0].encounters[0].finalizationStatus else {
                Issue.record("a nota assistida deveria finalizar após releitura")
                return
            }
            let audit = try String(
                contentsOf: reopened.patients[0].url.appending(path: ".openpep/audit.ndjson"),
                encoding: .utf8
            )
            #expect(audit.contains(assetID))
            let exportURL = fixture.vault.url.deletingLastPathComponent().appending(
                path: "exportacao-resumo", directoryHint: .isDirectory
            )
            let exported = try ClinicalExportService().export(
                scope: .encounter(patientID: patientID, encounterID: encounterID),
                from: fixture.vault.url,
                to: exportURL
            )
            #expect(exported.documentCount == 1)
            let exportedFiles = try FileManager.default.subpathsOfDirectory(atPath: exportURL.path)
            #expect(exportedFiles.contains { $0.hasSuffix("\(assetID).txt") })
        }
    }

    @Test("a stale draft snapshot cannot insert after finalization")
    func refusesStaleSnapshotAfterFinalization() throws {
        try withFixture { fixture in
            _ = try ClinicalFinalizer().finalize(
                patient: fixture.patient,
                encounter: fixture.encounter,
                identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000212"),
                finalizedAt: reviewedAt
            )
            #expect(throws: VaultValidationIssue.self) {
                _ = try ConsultationSummaryInsertionService().insert(
                    proposal,
                    into: fixture.encounter,
                    patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    reviewedBy: authorID,
                    sourceIdentity: RawAssetCreationIdentity(assetID: assetID),
                    updatedAt: reviewedAt.addingTimeInterval(60)
                )
            }
            let reopened = try VaultReader().open(fixture.vault.url)
            #expect(reopened.patients[0].encounters[0].draft.metadata.schema == "openpep/clinical-note@1")
            #expect(reopened.patients[0].rawAssets.isEmpty)
        }
    }

    @Test("rolls back both source and draft when publication is interrupted")
    func rollsBackPublication() throws {
        try withFixture { fixture in
            let previous = try Data(contentsOf: fixture.encounter.draft.url)
            let service = ConsultationSummaryInsertionService(faultInjector: { step in
                if step == .draftPublished { throw SummarySyntheticFailure() }
            })
            #expect(throws: SummarySyntheticFailure.self) {
                _ = try service.insert(
                    proposal,
                    into: fixture.encounter,
                    patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    reviewedBy: authorID,
                    sourceIdentity: RawAssetCreationIdentity(assetID: assetID),
                    updatedAt: reviewedAt
                )
            }
            #expect(try Data(contentsOf: fixture.encounter.draft.url) == previous)
            #expect(try VaultReader().open(fixture.vault.url).patients[0].rawAssets.isEmpty)
        }
    }

    @Test("preserves a concurrent draft, backup, and source when rollback is ambiguous")
    func preservesAmbiguousRollbackEvidence() throws {
        try withFixture { fixture in
            let concurrentData = Data("alteração sintética concorrente\n".utf8)
            let service = ConsultationSummaryInsertionService(faultInjector: { step in
                if step == .draftPublished {
                    try concurrentData.write(to: fixture.encounter.draft.url, options: .atomic)
                    throw SummarySyntheticFailure()
                }
            })
            do {
                _ = try service.insert(
                    proposal,
                    into: fixture.encounter,
                    patient: fixture.patient,
                    deviceID: fixture.vault.manifest.deviceID,
                    reviewedBy: authorID,
                    sourceIdentity: RawAssetCreationIdentity(assetID: assetID),
                    updatedAt: reviewedAt
                )
                Issue.record("a restauração ambígua deveria falhar")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.rollback_failed")
            }
            #expect(try Data(contentsOf: fixture.encounter.draft.url) == concurrentData)
            let draftDirectory = fixture.encounter.draft.url.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: draftDirectory.path)
            #expect(names.contains { $0.hasPrefix(".openpep-ai-summary-backup-") })
            let rawFiles = try FileManager.default.subpathsOfDirectory(
                atPath: fixture.patient.url.appending(path: "raw").path
            )
            #expect(rawFiles.contains { $0.hasSuffix("\(assetID).txt") })
        }
    }

    private var authorID: String { "usr_0198f4a0-0000-7000-8000-000000000211" }
    private var patientID: String { "pt_0198f5c2-0000-7000-8000-000000000211" }
    private var encounterID: String { "enc_0198f5d1-0000-7000-8000-000000000211" }
    private var noteID: String { "note_0198f5d3-0000-7000-8000-000000000211" }
    private var assetID: String { "asset_0198f5d7-0000-7000-8000-000000000211" }
    private var generationID: String { "gen_0198f5d8-0000-7000-8000-000000000211" }
    private var generatedAt: Date { Date(timeIntervalSince1970: 1_788_585_840) }
    private var reviewedAt: Date { generatedAt.addingTimeInterval(60) }

    private var proposal: ConsultationSummaryProposal {
        let chunks = [
            ConsultationSummaryProvenance.SourceChunk(
                label: "trecho 1 de 1",
                text: "Paciente sintético nega febre."
            ),
        ]
        let artifact = chunks.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n\n") + "\n"
        let hash = SHA256.hash(data: Data(artifact.utf8)).map { String(format: "%02x", $0) }.joined()
        return ConsultationSummaryProposal(
            text: "- Nega febre [trecho 1 de 1].",
            provenance: ConsultationSummaryProvenance(
                generationID: generationID,
                sourceSHA256: hash,
                sourceTranscript: "Paciente sintético nega febre.",
                localeIdentifier: "pt-BR",
                sourceChunks: chunks,
                generatedAt: generatedAt
            )
        )
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "openpep-ai-summary-tests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let vault = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-0000-7000-8000-000000000211",
                deviceID: "dev_0198f5c1-0000-7000-8000-000000000211"
            ),
            createdAt: generatedAt.addingTimeInterval(-300)
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético do Resumo",
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

private struct SummarySyntheticFailure: Error {}
