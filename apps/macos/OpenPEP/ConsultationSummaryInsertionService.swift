// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct ConsultationSummaryInsertionResult: Equatable, Sendable {
    let draft: ClinicalDraftSummary
    let source: RawAssetImportResult
}

enum ConsultationSummaryInsertionStep: Equatable, Sendable {
    case draftTemporaryWritten
    case draftPublished
}

struct ConsultationSummaryInsertionService {
    private let fileManager: FileManager
    private let documentImporter: GeneralDocumentImporter
    private let faultInjector: ((ConsultationSummaryInsertionStep) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        faultInjector: ((ConsultationSummaryInsertionStep) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        documentImporter = GeneralDocumentImporter(fileManager: fileManager)
        self.faultInjector = faultInjector
    }

    func insert(
        _ proposal: ConsultationSummaryProposal,
        into encounter: EncounterSummary,
        patient: PatientSummary,
        deviceID: String,
        reviewedBy: String,
        sourceIdentity: RawAssetCreationIdentity,
        updatedAt: Date
    ) throws -> ConsultationSummaryInsertionResult {
        guard encounter.finalizationStatus == .draft else {
            throw insertionIssue("ai_summary.final_note", encounter.draft.metadata.noteID, "O resumo só pode ser inserido em um rascunho.")
        }
        guard reviewedBy == encounter.draft.metadata.authorID else {
            throw insertionIssue("ai_summary.reviewer", reviewedBy, "O revisor deve ser o autor do rascunho neste perfil sintético.")
        }
        guard encounter.draft.metadata.schema == "openpep/clinical-note@1" else {
            throw insertionIssue("ai_summary.already_assisted", encounter.draft.url.path, "Este rascunho já registra assistência de IA.")
        }
        let sourceData = Data(proposal.provenance.sourceArtifactText.utf8)
        guard digest(sourceData) == proposal.provenance.sourceSHA256 else {
            throw insertionIssue("ai_summary.source_hash", "/ai_assistance/source_sha256", "A fonte diverge da proposta revisada.")
        }

        let temporarySource = fileManager.temporaryDirectory.appending(
            path: "openpep-resumo-fonte-\(UUID().uuidString.lowercased()).txt"
        )
        try sourceData.write(to: temporarySource, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporarySource) }

        let imported = try documentImporter.importDocument(
            from: temporarySource,
            into: patient,
            encounterID: encounter.metadata.encounterID,
            deviceID: deviceID,
            identity: sourceIdentity,
            importedAt: proposal.provenance.generatedAt
        )
        var draftCommitted = false
        do {
            let saved = try AssistedClinicalDraftWriter(fileManager: fileManager, faultInjector: faultInjector).save(
                proposal,
                sourceAssetID: imported.assetID,
                encounter: encounter,
                patientID: patient.patientID,
                reviewedBy: reviewedBy,
                updatedAt: updatedAt
            )
            // The committed draft references the source. Never delete it on a later verification error.
            draftCommitted = true
            let reopened = try VaultReader().open(patient.url.deletingLastPathComponent().deletingLastPathComponent())
            guard let reopenedPatient = reopened.patients.first(where: { $0.patientID == patient.patientID }),
                  let source = reopenedPatient.rawAssets.first(where: { $0.assetID == imported.assetID }),
                  source.encounterID == encounter.metadata.encounterID,
                  source.sha256 == proposal.provenance.sourceSHA256 else {
                throw insertionIssue("ai_summary.reopen", imported.assetID, "A fonte do resumo não pôde ser verificada após a escrita.")
            }
            return ConsultationSummaryInsertionResult(draft: saved, source: imported)
        } catch {
            let rollbackIsAmbiguous = (error as? VaultValidationIssue)?.rule == "clinical_document.rollback_failed"
            if !draftCommitted && !rollbackIsAmbiguous {
                do {
                    try fileManager.removeItem(at: imported.sidecarURL)
                    try fileManager.removeItem(at: imported.originalURL)
                } catch {
                    throw insertionIssue(
                        "ai_summary.rollback_failed",
                        imported.originalURL.path,
                        "A inserção falhou e a fonte residual não pôde ser removida. Preserve o arquivo para diagnóstico."
                    )
                }
            }
            throw error
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct AssistedClinicalDraftWriter {
    let fileManager: FileManager
    let faultInjector: ((ConsultationSummaryInsertionStep) throws -> Void)?

    func save(
        _ proposal: ConsultationSummaryProposal,
        sourceAssetID: String,
        encounter: EncounterSummary,
        patientID: String,
        reviewedBy: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        var result: Result<ClinicalDraftSummary, Error>?
        var coordinationError: NSError?
        let patientURL = encounter.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSFileCoordinator().coordinate(writingItemAt: patientURL, options: .forMerging, error: &coordinationError) { _ in
            do {
                result = .success(try saveUncoordinated(
                    proposal,
                    sourceAssetID: sourceAssetID,
                    encounterURL: encounter.url,
                    draftURL: encounter.draft.url,
                    encounter: encounter,
                    patientID: patientID,
                    reviewedBy: reviewedBy,
                    updatedAt: updatedAt
                ))
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else {
            throw insertionIssue("filesystem.coordination", encounter.draft.url.path, "A inserção coordenada não foi concluída.")
        }
        return try result.get()
    }

    private func saveUncoordinated(
        _ proposal: ConsultationSummaryProposal,
        sourceAssetID: String,
        encounterURL: URL,
        draftURL: URL,
        encounter: EncounterSummary,
        patientID: String,
        reviewedBy: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        try requireRegularFile(encounterURL)
        try requireRegularFile(draftURL)
        let encountersURL = encounterURL.deletingLastPathComponent()
        let contentURL = encountersURL.deletingLastPathComponent()
        let draftsURL = draftURL.deletingLastPathComponent()
        let notesURL = draftsURL.deletingLastPathComponent()
        guard encountersURL.lastPathComponent == "encounters",
              draftsURL.lastPathComponent == "drafts",
              notesURL.lastPathComponent == "notes",
              contentURL == notesURL.deletingLastPathComponent(),
              encounterURL.deletingPathExtension().lastPathComponent == encounter.metadata.encounterID,
              draftURL.deletingPathExtension().lastPathComponent == encounter.draft.metadata.noteID else {
            throw insertionIssue("clinical_document.layout", draftURL.path, "Os arquivos clínicos não estão sob a estrutura esperada.")
        }
        for directory in [contentURL, encountersURL, notesURL, draftsURL] { try requireDirectory(directory) }
        let finalURL = notesURL.appending(path: "final/\(encounter.draft.metadata.noteID).md")
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw insertionIssue("ai_summary.final_note", finalURL.path, "A consulta foi finalizada. O resumo não será inserido.")
        }
        let encounterData = try Data(contentsOf: encounterURL)
        let reopenedEncounter = try ClinicalDocumentValidator.validateEncounter(data: encounterData, source: encounterURL.path)
        let previousData = try Data(contentsOf: draftURL)
        let previous = try ClinicalDocumentValidator.validateDraft(data: previousData, source: draftURL.path)
        guard reopenedEncounter == encounter.metadata,
              previousData == encounter.draft.persistedData,
              previous.metadata == encounter.draft.metadata else {
            throw insertionIssue("clinical_document.revision_conflict", draftURL.path, "O rascunho mudou. Reabra antes de inserir o resumo.")
        }
        try ClinicalDocumentValidator.bind(encounter: reopenedEncounter, draft: previous.metadata, expectedPatientID: patientID)
        guard previous.metadata.schema == "openpep/clinical-note@1",
              previous.frontmatter.contains("schema: openpep/clinical-note@1\n"),
              previous.frontmatter.contains("source_ids: []\n"),
              previous.frontmatter.contains("ai_assistance:\n  used: false\n  generation_id: null\n  reviewed_by: null\n") else {
            throw insertionIssue("clinical_document.writer_representation", draftURL.path, "O rascunho não usa a representação esperada para migração opt-in.")
        }
        guard updatedAt >= proposal.provenance.generatedAt else {
            throw insertionIssue("clinical_document.updated_at", "/updated_at", "A revisão não pode anteceder a geração.")
        }
        guard let createdAt = ISO8601DateFormatter().date(from: previous.metadata.createdAt),
              let previousUpdatedAt = ISO8601DateFormatter().date(from: previous.metadata.updatedAt),
              updatedAt >= createdAt,
              updatedAt >= previousUpdatedAt else {
            throw insertionIssue("clinical_document.updated_at", "/updated_at", "updated_at não pode anteceder o rascunho atual.")
        }

        let updatedTimestamp = timestamp(updatedAt)
        var frontmatter = previous.frontmatter
            .replacingOccurrences(of: "schema: openpep/clinical-note@1\n", with: "schema: openpep/clinical-note@2\n")
            .replacingOccurrences(of: "source_ids: []\n", with: "source_ids:\n  - \(sourceAssetID)\n")
            .replacingOccurrences(
                of: "ai_assistance:\n  used: false\n  generation_id: null\n  reviewed_by: null\n",
                with: assistedMetadata(proposal, reviewedBy: reviewedBy)
            )
        frontmatter = frontmatter.replacingOccurrences(
            of: #"(?m)^updated_at:.*$"#,
            with: "updated_at: \(quoted(updatedTimestamp))",
            options: .regularExpression
        )
        let priorBody = normalizedBody(previous.body)
        let reviewedProposal = normalizedBody(proposal.text)
        let separator = priorBody.isEmpty ? "" : "\n"
        let body = priorBody + separator + "## Resumo proposto por IA e aceito\n\n" + reviewedProposal
        let candidateData = Data(("---\n" + frontmatter + "---\n\n" + body).utf8)
        let candidate = try ClinicalDocumentValidator.validateDraft(data: candidateData, source: draftURL.path)
        try ClinicalDocumentValidator.bind(encounter: reopenedEncounter, draft: candidate.metadata, expectedPatientID: patientID)

        let temporary = draftURL.deletingLastPathComponent().appending(path: ".openpep-ai-summary-\(UUID().uuidString.lowercased())")
        let backupName = ".openpep-ai-summary-backup-\(UUID().uuidString.lowercased())"
        let backup = draftURL.deletingLastPathComponent().appending(path: backupName)
        var preserveBackup = false
        defer {
            try? fileManager.removeItem(at: temporary)
            if !preserveBackup { try? fileManager.removeItem(at: backup) }
        }
        try candidateData.write(to: temporary, options: [.withoutOverwriting])
        try faultInjector?(.draftTemporaryWritten)
        do {
            _ = try fileManager.replaceItemAt(
                draftURL,
                withItemAt: temporary,
                backupItemName: backupName,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
            )
            try faultInjector?(.draftPublished)
            let reopenedData = try Data(contentsOf: draftURL)
            let reopened = try ClinicalDocumentValidator.validateDraft(data: reopenedData, source: draftURL.path)
            guard reopenedData == candidateData else {
                throw insertionIssue("clinical_document.revision_conflict", draftURL.path, "O rascunho mudou durante a inserção.")
            }
            try fileManager.removeItem(at: backup)
            return ClinicalDraftSummary(metadata: reopened.metadata, url: draftURL, body: reopened.body, persistedData: reopenedData)
        } catch {
            do {
                if fileManager.fileExists(atPath: backup.path) {
                    if fileManager.fileExists(atPath: draftURL.path) {
                        let currentData = try Data(contentsOf: draftURL)
                        if currentData == previousData {
                            try fileManager.removeItem(at: backup)
                        } else if currentData == candidateData {
                            try fileManager.removeItem(at: draftURL)
                            try fileManager.moveItem(at: backup, to: draftURL)
                        } else {
                            preserveBackup = true
                            throw insertionIssue(
                                "clinical_document.rollback_failed",
                                backup.path,
                                "O rascunho mudou durante a restauração; o arquivo atual e o backup foram preservados."
                            )
                        }
                    } else {
                        try fileManager.moveItem(at: backup, to: draftURL)
                    }
                } else {
                    guard fileManager.fileExists(atPath: draftURL.path),
                          try Data(contentsOf: draftURL) == previousData else {
                        throw insertionIssue(
                            "clinical_document.rollback_failed",
                            backup.path,
                            "Não foi possível comprovar a restauração do rascunho anterior."
                        )
                    }
                }
            } catch let rollbackError {
                preserveBackup = true
                if (rollbackError as? VaultValidationIssue)?.rule == "clinical_document.rollback_failed" {
                    throw rollbackError
                }
                throw insertionIssue("clinical_document.rollback_failed", backup.path, "A restauração falhou; o backup remanescente foi preservado.")
            }
            throw error
        }
    }

    private func assistedMetadata(_ proposal: ConsultationSummaryProposal, reviewedBy: String) -> String {
        let provenance = proposal.provenance
        return """
        ai_assistance:
          used: true
          generation_id: \(provenance.generationID)
          reviewed_by: \(reviewedBy)
          provenance_schema: \(ConsultationSummaryProvenance.schema)
          engine: \(quoted(ConsultationSummaryProvenance.engine))
          prompt_version: \(quoted(ConsultationSummaryProvenance.promptVersion))
          locale: pt-BR
          generated_at: \(quoted(timestamp(provenance.generatedAt)))
          source_sha256: \(provenance.sourceSHA256)
          chunk_count: \(provenance.chunkCount)
        """ + "\n"
    }

    private func normalizedBody(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        while value.hasSuffix("\n") { value.removeLast() }
        if !value.isEmpty { value.append("\n") }
        return value
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw insertionIssue("filesystem.regular_file", url.path, "O arquivo clínico esperado não está disponível.")
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw insertionIssue("filesystem.directory", url.path, "O diretório clínico esperado não está disponível.")
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

private func insertionIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
