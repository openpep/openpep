// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("WIKI-001 patient AI context")
struct PatientAIContextTests {
    @Test("consolidated context excludes drafts while questions can include them explicitly")
    func draftSelectionIsExplicit() throws {
        let final = entry(
            id: "final-synthetic",
            text: "Conduta final sintética.",
            source: "content/notes/final/note-synthetic.md",
            status: "Finalizada"
        )
        let draft = entry(
            id: "draft-synthetic",
            text: "Hipótese ainda em rascunho.",
            source: "content/notes/drafts/note-draft-synthetic.md",
            status: "Rascunho salvo"
        )

        let consolidated = try PatientAIContext.make(
            patient: patient,
            entries: [final, draft],
            corrections: "",
            includeDrafts: false
        )
        #expect(consolidated.entries.map(\.id) == [final.id])
        #expect(consolidated.excludedCount == 1)
        #expect(consolidated.input.contains(final.text))
        #expect(!consolidated.input.contains(draft.text))

        let questionContext = try PatientAIContext.make(
            patient: patient,
            entries: [final, draft],
            corrections: "",
            includeDrafts: true
        )
        #expect(questionContext.entries.map(\.id) == [final.id, draft.id])
        #expect(questionContext.excludedCount == 0)
        #expect(questionContext.input.contains(draft.text))
    }

    @Test("sources with extraction issues never enter the generated input")
    func unavailableSourcesAreExcluded() throws {
        let available = entry(id: "available-synthetic", text: "Texto clínico sintético disponível.")
        let unavailable = entry(
            id: "unavailable-synthetic",
            text: "Texto parcial que não deve ser enviado.",
            source: "raw/2026/09/unavailable-synthetic.pdf",
            status: "Documento guardado",
            issue: "Texto indisponível para uso em IA."
        )

        let context = try PatientAIContext.make(
            patient: patient,
            entries: [available, unavailable],
            corrections: "Preservar correção sintética."
        )

        #expect(context.entries.map(\.id) == [available.id])
        #expect(context.excludedCount == 1)
        #expect(context.input.contains(available.text))
        #expect(!context.input.contains(unavailable.text))
        #expect(context.input.contains("Preservar correção sintética."))
    }

    @Test("draft-bound documents are explicit and AI provenance is never recycled")
    func draftAssetsAndAIProvenanceAreExcluded() throws {
        let encounterID = "enc_0198f700-0000-7000-8000-000000000092"
        let draftAssetID = "asset_0198f700-0000-7000-8000-000000000093"
        let provenanceAssetID = "asset_0198f700-0000-7000-8000-000000000094"
        let patient = patient(
            encounterID: encounterID,
            draftAssetID: draftAssetID,
            provenanceAssetID: provenanceAssetID
        )
        let draftDocument = entry(
            id: draftAssetID,
            text: "Documento provisório ligado ao rascunho.",
            source: "raw/2026/09/draft-document-synthetic.txt",
            status: "Documento da consulta",
            assetID: draftAssetID
        )
        let priorAIProposal = entry(
            id: provenanceAssetID,
            text: "Proposta anterior que não pode alimentar outra geração.",
            source: "raw/2026/09/ai-proposal-synthetic.txt",
            status: "Documento da consulta",
            assetID: provenanceAssetID
        )

        let consolidated = try PatientAIContext.make(
            patient: patient,
            entries: [draftDocument, priorAIProposal],
            corrections: "",
            includeDrafts: false
        )
        #expect(consolidated.entries.isEmpty)
        #expect(consolidated.excludedCount == 2)

        let questionContext = try PatientAIContext.make(
            patient: patient,
            entries: [draftDocument, priorAIProposal],
            corrections: "",
            includeDrafts: true
        )
        #expect(questionContext.entries.map(\.id) == [draftDocument.id])
        #expect(questionContext.excludedCount == 1)
        #expect(questionContext.input.contains(draftDocument.text))
        #expect(!questionContext.input.contains(priorAIProposal.text))
    }

    @Test("fingerprint changes when an otherwise identical asset becomes AI provenance")
    func fingerprintTracksAssetClassification() throws {
        let encounterID = "enc_0198f700-0000-7000-8000-000000000096"
        let selectedAssetID = "asset_0198f700-0000-7000-8000-000000000097"
        let otherAssetID = "asset_0198f700-0000-7000-8000-000000000098"
        let source = entry(
            id: selectedAssetID,
            text: "Fonte sintética com os mesmos campos de histórico.",
            source: "raw/2026/09/classification-synthetic.txt",
            status: "Documento da consulta",
            assetID: selectedAssetID
        )
        let initiallyEligible = try PatientAIContext.make(
            patient: patient(
                encounterID: encounterID,
                draftAssetID: selectedAssetID,
                provenanceAssetID: otherAssetID
            ),
            entries: [source],
            corrections: "",
            includeDrafts: true
        )
        let nowProvenance = try PatientAIContext.make(
            patient: patient(
                encounterID: encounterID,
                draftAssetID: otherAssetID,
                provenanceAssetID: selectedAssetID
            ),
            entries: [source],
            corrections: "",
            includeDrafts: true
        )

        #expect(initiallyEligible.entries.map(\.id) == [source.id])
        #expect(nowProvenance.entries.isEmpty)
        #expect(nowProvenance.fingerprint != initiallyEligible.fingerprint)
    }

    @Test("fingerprint changes with corrections, source, status and deletion")
    func fingerprintTracksEveryRelevantChange() throws {
        let first = entry(id: "entry-one-synthetic", text: "Primeiro fato sintético.")
        let second = entry(id: "entry-two-synthetic", text: "Segundo fato sintético.")
        let entries = [first, second]
        let baseline = try context(entries: entries, corrections: "Correção sintética A.")

        let corrected = try context(entries: entries, corrections: "Correção sintética B.")
        #expect(corrected.fingerprint != baseline.fingerprint)

        let sourceChanged = try context(entries: [first, entry(
            id: second.id,
            text: second.text,
            source: "content/notes/addenda/addendum-synthetic.md",
            status: second.status
        )], corrections: "Correção sintética A.")
        #expect(sourceChanged.fingerprint != baseline.fingerprint)

        let statusChanged = try context(entries: [first, entry(
            id: second.id,
            text: second.text,
            source: second.source,
            status: "Adendo verificado"
        )], corrections: "Correção sintética A.")
        #expect(statusChanged.fingerprint != baseline.fingerprint)

        let deleted = try context(entries: [first], corrections: "Correção sintética A.")
        #expect(deleted.fingerprint != baseline.fingerprint)
    }

    @Test("oversized context is refused instead of truncating an entry")
    func oversizedInputIsRefused() {
        let oversizedText = String(repeating: "x", count: PatientAIContext.maximumCharacters)

        do {
            _ = try PatientAIContext.make(
                patient: patient,
                entries: [entry(id: "oversized-synthetic", text: oversizedText)],
                corrections: ""
            )
            Issue.record("an oversized context should be refused")
        } catch let issue as PatientAIIssue {
            guard case .tooLong = issue else {
                Issue.record("expected tooLong, got \(issue)")
                return
            }
            #expect(issue.errorDescription?.contains("Nenhuma fonte foi cortada") == true)
        } catch {
            Issue.record("expected PatientAIIssue, got \(error)")
        }
    }

    private func context(
        entries: [PatientHistoryEntry],
        corrections: String
    ) throws -> PatientAIContext {
        try PatientAIContext.make(
            patient: patient,
            entries: entries,
            corrections: corrections
        )
    }

    private var patient: PatientSummary {
        PatientSummary(
            patientID: "pt_0198f700-0000-7000-8000-000000000091",
            url: URL(fileURLWithPath: "/synthetic/patient-ai-context"),
            record: nil,
            rawAssets: [],
            encounters: []
        )
    }

    private func patient(
        encounterID: String,
        draftAssetID: String,
        provenanceAssetID: String
    ) -> PatientSummary {
        let patientID = patient.patientID
        let baseURL = patient.url
        let encounter = EncounterSummary(
            metadata: EncounterMetadata(
                encounterID: encounterID,
                patientID: patientID,
                appointmentID: nil,
                status: "in_progress",
                modality: "in_person",
                startedAt: "2026-09-05T12:00:00Z",
                createdBy: "prof_synthetic",
                templateID: nil,
                templateVersion: nil,
                telemedicine: nil
            ),
            url: baseURL.appending(path: "encounters/\(encounterID).md"),
            draft: ClinicalDraftSummary(
                metadata: ClinicalDraftMetadata(
                    noteID: "note_0198f700-0000-7000-8000-000000000095",
                    patientID: patientID,
                    encounterID: encounterID,
                    status: "draft",
                    noteType: "progress",
                    authorID: "prof_synthetic",
                    createdAt: "2026-09-05T12:00:00Z",
                    updatedAt: "2026-09-05T12:00:00Z",
                    sourceIDs: [provenanceAssetID]
                ),
                url: baseURL.appending(path: "content/notes/drafts/note-synthetic.md"),
                body: "Rascunho sintético.",
                persistedData: Data("Rascunho sintético.".utf8)
            ),
            finalizationStatus: .draft
        )
        return PatientSummary(
            patientID: patientID,
            url: baseURL,
            record: nil,
            rawAssets: [
                rawAsset(id: draftAssetID, encounterID: encounterID),
                rawAsset(id: provenanceAssetID, encounterID: encounterID)
            ],
            encounters: [encounter]
        )
    }

    private func rawAsset(id: String, encounterID: String) -> RawAssetSummary {
        RawAssetSummary(
            assetID: id,
            encounterID: encounterID,
            originalName: "\(id).txt",
            importedAt: "2026-09-05T12:00:00Z",
            mediaType: "text/plain",
            fileExtension: "txt",
            sizeBytes: 10,
            sha256: String(repeating: "a", count: 64),
            source: "synthetic_test",
            inspectionResult: "synthetic",
            originalURL: patient.url.appending(path: "raw/\(id).txt")
        )
    }

    private func entry(
        id: String,
        text: String,
        source: String = "content/notes/final/note-synthetic.md",
        status: String = "Finalizada",
        assetID: String? = nil,
        issue: String? = nil
    ) -> PatientHistoryEntry {
        PatientHistoryEntry(
            id: id,
            title: "Registro sintético",
            timestamp: "2026-09-05T12:00:00Z",
            status: status,
            text: text,
            source: source,
            assetID: assetID,
            issue: issue
        )
    }
}
