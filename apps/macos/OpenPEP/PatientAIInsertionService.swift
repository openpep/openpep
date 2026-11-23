// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation

enum PatientAIInsertionStep: Equatable, Sendable {
    case draftTemporaryWritten
    case draftPublished
}

struct PatientAIInsertionService {
    private let fileManager: FileManager
    private let documentImporter: GeneralDocumentImporter
    private let faultInjector: ((PatientAIInsertionStep) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        faultInjector: ((PatientAIInsertionStep) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        documentImporter = GeneralDocumentImporter(fileManager: fileManager)
        self.faultInjector = faultInjector
    }

    func insert(
        result: OpenAITextResult,
        sourceText: String,
        acceptedText: String,
        generationID: String,
        promptVersion: String? = nil,
        into encounter: EncounterSummary,
        patient: PatientSummary,
        deviceID: String,
        updatedAt: Date = Date()
    ) throws -> ClinicalDraftSummary {
        guard encounter.finalizationStatus == .draft else {
            throw patientAIIssue("patient_ai.final_note", encounter.draft.metadata.noteID,
                                 "A proposta só pode ser inserida em um rascunho.")
        }
        guard patient.patientID == encounter.metadata.patientID,
              patient.patientID == encounter.draft.metadata.patientID else {
            throw patientAIIssue("patient_ai.patient_mismatch", patient.patientID,
                                 "A consulta pertence a outro paciente.")
        }
        let normalizedAccepted = normalizedBody(acceptedText)
        guard !normalizedAccepted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              acceptedText.count <= 500_000 else {
            throw patientAIIssue("patient_ai.accepted_text", "/body", "A proposta aceita está vazia ou excede o limite.")
        }
        guard !sourceText.isEmpty, sourceText.count <= 2_000_000 else {
            throw patientAIIssue("patient_ai.source", "/source", "A fonte está vazia ou excede o limite.")
        }
        guard matches(generationID, #"^gen_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#) else {
            throw patientAIIssue("patient_ai.generation_id", generationID, "O identificador da geração não é válido.")
        }
        guard isSafeProviderValue(result.model), isSafeProviderValue(result.responseID),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw patientAIIssue("patient_ai.response", "/response", "A resposta da IA não contém proveniência válida.")
        }
        if let promptVersion {
            guard promptVersion == AIPromptCatalog.patientHistoryOpenAI.id else {
                throw patientAIIssue("patient_ai.prompt_version", "/prompt_version",
                                     "A revisão das instruções não é reconhecida para perguntas ao histórico.")
            }
        }
        try rejectDuplicate(generationID, in: encounter.draft.metadata)
        let expectedEncounterData = try Data(contentsOf: encounter.url)
        guard try ClinicalDocumentValidator.validateEncounter(
            data: expectedEncounterData,
            source: encounter.url.path
        ) == encounter.metadata else {
            throw patientAIIssue("clinical_document.revision_conflict", encounter.url.path,
                                 "O atendimento mudou. Reabra antes de inserir a proposta.")
        }

        let sourceData = Data(sourceText.utf8)
        let sourceHash = digest(sourceData)
        let temporarySource = fileManager.temporaryDirectory.appending(
            path: "openpep-patient-ai-source-\(UUID().uuidString.lowercased()).txt"
        )
        try sourceData.write(to: temporarySource, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporarySource) }

        let imported = try documentImporter.importDocument(
            from: temporarySource,
            into: patient,
            encounterID: encounter.metadata.encounterID,
            deviceID: deviceID,
            identity: try RawAssetCreationIdentity.generate(at: updatedAt),
            importedAt: updatedAt
        )
        guard imported.sha256 == sourceHash else {
            try? fileManager.removeItem(at: imported.sidecarURL)
            try? fileManager.removeItem(at: imported.originalURL)
            throw patientAIIssue("patient_ai.source_hash", imported.assetID, "A fonte importada diverge dos bytes aceitos.")
        }
        let importedSidecarData = try Data(contentsOf: imported.sidecarURL)

        var draftCommitted = false
        do {
            let saved = try PatientAIDraftWriter(
                fileManager: fileManager,
                faultInjector: faultInjector
            ).save(
                result: result,
                acceptedText: normalizedAccepted,
                generationID: generationID,
                promptVersion: promptVersion,
                sourceAssetID: imported.assetID,
                sourceSHA256: sourceHash,
                encounter: encounter,
                expectedEncounterData: expectedEncounterData,
                patientID: patient.patientID,
                updatedAt: updatedAt
            )
            draftCommitted = true
            let vaultURL = patient.url.deletingLastPathComponent().deletingLastPathComponent()
            let reopened = try VaultReader().open(vaultURL)
            guard let reopenedPatient = reopened.patients.first(where: { $0.patientID == patient.patientID }),
                  let reopenedEncounter = reopenedPatient.encounters.first(where: {
                      $0.metadata.encounterID == encounter.metadata.encounterID
                  }),
                  reopenedEncounter.draft.metadata == saved.metadata,
                  let source = reopenedPatient.rawAssets.first(where: { $0.assetID == imported.assetID }),
                  source.encounterID == encounter.metadata.encounterID,
                  source.sha256 == sourceHash else {
                throw patientAIIssue("patient_ai.reopen", imported.assetID,
                                     "A fonte da proposta não pôde ser verificada após a escrita.")
            }
            return saved
        } catch {
            let rollbackIsAmbiguous = (error as? VaultValidationIssue)?.rule == "clinical_document.rollback_failed"
            if !draftCommitted && !rollbackIsAmbiguous {
                do {
                    try removeImportedSource(
                        imported,
                        expectedOriginalData: sourceData,
                        expectedSidecarData: importedSidecarData,
                        patient: patient,
                        encounter: encounter,
                        expectedEncounterData: expectedEncounterData
                    )
                } catch {
                    throw patientAIIssue(
                        "patient_ai.rollback_failed",
                        imported.originalURL.path,
                        "A inserção falhou e a fonte residual não pôde ser removida. Preserve o arquivo para diagnóstico."
                    )
                }
            }
            throw error
        }
    }

    private func removeImportedSource(
        _ imported: RawAssetImportResult,
        expectedOriginalData: Data,
        expectedSidecarData: Data,
        patient: PatientSummary,
        encounter: EncounterSummary,
        expectedEncounterData: Data
    ) throws {
        var outcome: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: patient.url, options: .forMerging, error: &coordinationError) { _ in
            do {
                let originalValues = try imported.originalURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                let sidecarValues = try imported.sidecarURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                let encounterValues = try encounter.url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                let draftValues = try encounter.draft.url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                let finalURL = patient.url.appending(
                    path: "content/notes/final/\(encounter.draft.metadata.noteID).md"
                )
                guard originalValues.isRegularFile == true,
                      originalValues.isSymbolicLink != true,
                      sidecarValues.isRegularFile == true,
                      sidecarValues.isSymbolicLink != true,
                      encounterValues.isRegularFile == true,
                      encounterValues.isSymbolicLink != true,
                      draftValues.isRegularFile == true,
                      draftValues.isSymbolicLink != true,
                      !fileManager.fileExists(atPath: finalURL.path),
                      try Data(contentsOf: encounter.url) == expectedEncounterData,
                      try Data(contentsOf: encounter.draft.url) == encounter.draft.persistedData,
                      try Data(contentsOf: imported.originalURL) == expectedOriginalData,
                      try Data(contentsOf: imported.sidecarURL) == expectedSidecarData else {
                    throw patientAIIssue(
                        "patient_ai.rollback_failed",
                        imported.originalURL.path,
                        "O atendimento ou a fonte mudou durante a inserção; o ativo foi preservado para diagnóstico."
                    )
                }
                try fileManager.removeItem(at: imported.sidecarURL)
                try fileManager.removeItem(at: imported.originalURL)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw patientAIIssue("filesystem.coordination", patient.url.path,
                                 "A limpeza coordenada da fonte não foi concluída.")
        }
        try outcome.get()
    }

    private func rejectDuplicate(_ generationID: String, in draft: ClinicalDraftMetadata) throws {
        let duplicate = draft.aiAssistance.generationID == generationID ||
            draft.aiAssistance.generations.contains(where: { $0.generationID == generationID })
        guard !duplicate else {
            throw patientAIIssue("patient_ai.duplicate_generation", generationID,
                                 "Esta geração já foi aceita no rascunho.")
        }
    }

    private func isSafeProviderValue(_ value: String) -> Bool {
        guard (1...256).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedBody(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        while value.hasSuffix("\n") { value.removeLast() }
        if !value.isEmpty { value.append("\n") }
        return value
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private struct PatientAIDraftWriter {
    let fileManager: FileManager
    let faultInjector: ((PatientAIInsertionStep) throws -> Void)?

    func save(
        result: OpenAITextResult,
        acceptedText: String,
        generationID: String,
        promptVersion: String?,
        sourceAssetID: String,
        sourceSHA256: String,
        encounter: EncounterSummary,
        expectedEncounterData: Data,
        patientID: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        var outcome: Result<ClinicalDraftSummary, Error>?
        var coordinationError: NSError?
        let patientURL = encounter.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vaultURL = patientURL.deletingLastPathComponent().deletingLastPathComponent()
        NSFileCoordinator().coordinate(writingItemAt: vaultURL, options: .forMerging, error: &coordinationError) { _ in
            do {
                outcome = .success(try saveUncoordinated(
                    result: result,
                    acceptedText: acceptedText,
                    generationID: generationID,
                    promptVersion: promptVersion,
                    sourceAssetID: sourceAssetID,
                    sourceSHA256: sourceSHA256,
                    encounter: encounter,
                    expectedEncounterData: expectedEncounterData,
                    patientID: patientID,
                    updatedAt: updatedAt
                ))
            } catch { outcome = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw patientAIIssue("filesystem.coordination", encounter.draft.url.path,
                                 "A inserção coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func saveUncoordinated(
        result: OpenAITextResult,
        acceptedText: String,
        generationID: String,
        promptVersion: String?,
        sourceAssetID: String,
        sourceSHA256: String,
        encounter: EncounterSummary,
        expectedEncounterData: Data,
        patientID: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        let encounterURL = encounter.url
        let draftURL = encounter.draft.url
        try requireRegularFile(encounterURL)
        try requireRegularFile(draftURL)
        let encountersURL = encounterURL.deletingLastPathComponent()
        let contentURL = encountersURL.deletingLastPathComponent()
        let draftsURL = draftURL.deletingLastPathComponent()
        let notesURL = draftsURL.deletingLastPathComponent()
        guard encountersURL.lastPathComponent == "encounters",
              draftsURL.lastPathComponent == "drafts",
              notesURL.lastPathComponent == "notes",
              contentURL == notesURL.deletingLastPathComponent() else {
            throw patientAIIssue("clinical_document.layout", draftURL.path,
                                 "Os arquivos clínicos não estão sob a estrutura esperada.")
        }
        for directory in [contentURL, encountersURL, notesURL, draftsURL] { try requireDirectory(directory) }
        let finalURL = notesURL.appending(path: "final/\(encounter.draft.metadata.noteID).md")
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw patientAIIssue("patient_ai.final_note", finalURL.path,
                                 "A consulta foi finalizada. A proposta não será inserida.")
        }

        let encounterData = try Data(contentsOf: encounterURL)
        let reopenedEncounter = try ClinicalDocumentValidator.validateEncounter(data: encounterData, source: encounterURL.path)
        let previousData = try Data(contentsOf: draftURL)
        let previous = try ClinicalDocumentValidator.validateDraft(data: previousData, source: draftURL.path)
        guard encounterData == expectedEncounterData,
              reopenedEncounter == encounter.metadata,
              previousData == encounter.draft.persistedData,
              previous.metadata == encounter.draft.metadata else {
            throw patientAIIssue("clinical_document.revision_conflict", draftURL.path,
                                 "O rascunho mudou. Reabra antes de inserir a proposta.")
        }
        try ClinicalDocumentValidator.bind(
            encounter: reopenedEncounter,
            draft: previous.metadata,
            expectedPatientID: patientID
        )
        guard ["openpep/clinical-note@1", "openpep/clinical-note@2", "openpep/clinical-note@3", "openpep/clinical-note@4"]
            .contains(previous.metadata.schema) else {
            throw patientAIIssue("clinical_document.writer_representation", draftURL.path,
                                 "O rascunho não usa uma versão editável por este writer.")
        }
        let existing = try existingGenerations(in: previous)
        guard !existing.contains(where: { $0.generationID == generationID }) else {
            throw patientAIIssue("patient_ai.duplicate_generation", generationID,
                                 "Esta geração já foi aceita no rascunho.")
        }
        guard existing.count < 100 else {
            throw patientAIIssue("patient_ai.generation_limit", "/ai_assistance/generations",
                                 "O rascunho atingiu o limite de propostas aceitas.")
        }
        guard let createdAt = ISO8601DateFormatter().date(from: previous.metadata.createdAt),
              let previousUpdatedAt = ISO8601DateFormatter().date(from: previous.metadata.updatedAt),
              updatedAt >= createdAt,
              updatedAt >= previousUpdatedAt else {
            throw patientAIIssue("clinical_document.updated_at", "/updated_at",
                                 "updated_at não pode anteceder o rascunho atual.")
        }

        let generation = ClinicalAIGeneration(
            generationID: generationID,
            acceptedBy: previous.metadata.authorID,
            acceptedAt: timestamp(updatedAt),
            sourceID: sourceAssetID,
            sourceSHA256: sourceSHA256,
            provenanceSchema: "openpep/patient-ai-provenance@1",
            engine: "openai/responses",
            model: result.model,
            responseID: result.responseID,
            promptVersion: promptVersion,
            locale: "pt-BR",
            generatedAt: nil,
            chunkCount: nil
        )
        let generations = existing + [generation]
        let sources = generations.map(\.sourceID)
        var frontmatter = previous.frontmatter
        frontmatter = try replacingTopLevelBlock(
            "source_ids",
            in: frontmatter,
            with: sourceMetadata(sources)
        )
        frontmatter = try replacingTopLevelBlock(
            "ai_assistance",
            in: frontmatter,
            with: assistanceMetadata(generations)
        )
        let targetSchema = previous.metadata.schema == "openpep/clinical-note@4"
            ? "openpep/clinical-note@4"
            : "openpep/clinical-note@3"
        frontmatter = frontmatter.replacingOccurrences(
            of: #"(?m)^schema: openpep/clinical-note@[1234]$"#,
            with: "schema: \(targetSchema)",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"(?m)^updated_at:.*$"#,
            with: "updated_at: \(quoted(timestamp(updatedAt)))",
            options: .regularExpression
        )
        let priorBody = normalizedBody(previous.body)
        let separator = priorBody.isEmpty ? "" : "\n"
        let body = priorBody + separator + "## Proposta por IA aceita\n\n" + acceptedText
        let candidateData = Data(("---\n" + frontmatter + "---\n\n" + body).utf8)
        let candidate = try ClinicalDocumentValidator.validateDraft(data: candidateData, source: draftURL.path)
        try ClinicalDocumentValidator.bind(
            encounter: reopenedEncounter,
            draft: candidate.metadata,
            expectedPatientID: patientID
        )

        let patientURL = contentURL.deletingLastPathComponent()
        let vaultURL = patientURL.deletingLastPathComponent().deletingLastPathComponent()
        let recovery = try recoveryDirectory(in: vaultURL)
        let staged = recovery.appending(path: "clinical-draft-\(UUID().uuidString.lowercased()).md")
        var swapped = false
        var preserveRecovery = false
        defer {
            if !preserveRecovery, fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
        }
        try candidateData.write(to: staged, options: [.withoutOverwriting])
        let stagedDraft = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: staged), source: draftURL.path
        )
        guard stagedDraft.metadata == candidate.metadata else {
            throw patientAIIssue("clinical_document.reopen_mismatch", staged.path,
                                 "O candidato preparado diverge do rascunho validado.")
        }
        try faultInjector?(.draftTemporaryWritten)
        try requireRegularFile(encounterURL)
        try requireRegularFile(draftURL)
        let currentEncounterData = try Data(contentsOf: encounterURL)
        let currentDraftData = try Data(contentsOf: draftURL)
        guard currentEncounterData == encounterData,
              currentDraftData == previousData else {
            throw patientAIIssue("clinical_document.revision_conflict", draftURL.path,
                                 "O encontro ou o rascunho mudou durante a inserção.")
        }
        let currentEncounter = try ClinicalDocumentValidator.validateEncounter(
            data: currentEncounterData,
            source: encounterURL.path
        )
        guard currentEncounter.trashedAt == nil,
              !fileManager.fileExists(atPath: finalURL.path) else {
            throw patientAIIssue("patient_ai.final_note", finalURL.path,
                                 "A consulta foi finalizada ou movida para a lixeira. A proposta não será inserida.")
        }
        do {
            try atomicSwap(draftURL, staged)
            swapped = true
            try faultInjector?(.draftPublished)
            let reopenedData = try Data(contentsOf: draftURL)
            let reopened = try ClinicalDocumentValidator.validateDraft(data: reopenedData, source: draftURL.path)
            guard reopenedData == candidateData,
                  try Data(contentsOf: staged) == previousData else {
                throw patientAIIssue("clinical_document.revision_conflict", draftURL.path,
                                     "O rascunho mudou durante a inserção.")
            }
            try fileManager.removeItem(at: staged)
            return ClinicalDraftSummary(
                metadata: reopened.metadata,
                url: draftURL,
                body: reopened.body,
                persistedData: reopenedData
            )
        } catch {
            if swapped {
                do {
                    guard try Data(contentsOf: draftURL) == candidateData,
                          try Data(contentsOf: staged) == previousData else {
                        throw patientAIIssue(
                            "clinical_document.rollback_failed",
                            staged.path,
                            "O rascunho mudou durante a restauração; a cópia anterior foi preservada em recovery."
                        )
                    }
                    try atomicSwap(draftURL, staged)
                } catch let rollbackError {
                    preserveRecovery = true
                    if (rollbackError as? VaultValidationIssue)?.rule == "clinical_document.rollback_failed" {
                        throw rollbackError
                    }
                    throw patientAIIssue("clinical_document.rollback_failed", staged.path,
                                         "A restauração falhou; a cópia anterior foi preservada em recovery.")
                }
            }
            throw error
        }
    }

    private func existingGenerations(in draft: ParsedClinicalDraft) throws -> [ClinicalAIGeneration] {
        switch draft.metadata.schema {
        case "openpep/clinical-note@1":
            try rejectNestedExtensions(in: draft.frontmatter)
            return []
        case "openpep/clinical-note@2":
            guard let generationID = draft.metadata.aiAssistance.generationID,
                  let acceptedBy = draft.metadata.aiAssistance.reviewedBy,
                  let sourceID = draft.metadata.sourceIDs.first,
                  let sourceSHA256 = draft.metadata.aiAssistance.sourceSHA256,
                  let provenance = draft.metadata.aiAssistance.provenanceSchema,
                  let engine = draft.metadata.aiAssistance.engine else {
                throw patientAIIssue("clinical_document.writer_representation", draft.metadata.noteID,
                                     "A proveniência anterior não pôde ser preservada.")
            }
            try rejectNestedExtensions(in: draft.frontmatter)
            return [ClinicalAIGeneration(
                generationID: generationID,
                acceptedBy: acceptedBy,
                acceptedAt: nil,
                sourceID: sourceID,
                sourceSHA256: sourceSHA256,
                provenanceSchema: provenance,
                engine: engine,
                model: nil,
                responseID: nil,
                promptVersion: draft.metadata.aiAssistance.promptVersion,
                locale: draft.metadata.aiAssistance.locale,
                generatedAt: draft.metadata.aiAssistance.generatedAt,
                chunkCount: draft.metadata.aiAssistance.chunkCount
            )]
        case "openpep/clinical-note@3", "openpep/clinical-note@4":
            try rejectNestedExtensions(in: draft.frontmatter)
            return draft.metadata.aiAssistance.generations
        default:
            throw patientAIIssue("clinical_document.writer_representation", draft.metadata.noteID,
                                 "A versão do rascunho não pode receber esta proposta.")
        }
    }

    private func rejectNestedExtensions(in frontmatter: String) throws {
        let data = Data(("---\n" + frontmatter + "---\n").utf8)
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: "/ai_assistance")
        guard case let .mapping(root) = document.metadata,
              case let .mapping(ai)? = root["ai_assistance"] else {
            throw patientAIIssue("clinical_document.writer_representation", "/ai_assistance",
                                 "A proveniência não usa uma representação editável.")
        }
        if containsExtension(in: ai) {
            throw patientAIIssue("clinical_document.writer_representation", "/ai_assistance",
                                 "A proveniência contém extensões que este writer não pode preservar.")
        }
    }

    private func containsExtension(in mapping: [String: YAMLValue]) -> Bool {
        for (key, value) in mapping {
            if key.hasPrefix("x_") { return true }
            switch value {
            case let .mapping(child):
                if containsExtension(in: child) { return true }
            case let .sequence(items):
                for item in items {
                    if case let .mapping(child) = item, containsExtension(in: child) { return true }
                }
            case .null, .boolean, .integer, .string:
                break
            }
        }
        return false
    }

    private func replacingTopLevelBlock(_ key: String, in frontmatter: String, with replacement: String) throws -> String {
        var lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indexes = lines.indices.filter { lines[$0].hasPrefix("\(key):") }
        guard indexes.count == 1, let start = indexes.first else {
            throw patientAIIssue("clinical_document.writer_representation", "/\(key)",
                                 "O rascunho não usa uma representação editável.")
        }
        var end = start + 1
        while end < lines.count && (lines[end].hasPrefix(" ") || lines[end].isEmpty) { end += 1 }
        let replacementLines = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.replaceSubrange(start..<end, with: replacementLines.dropLast())
        return lines.joined(separator: "\n")
    }

    private func sourceMetadata(_ sources: [String]) -> String {
        "source_ids:\n" + sources.map { "  - \($0)\n" }.joined()
    }

    private func assistanceMetadata(_ generations: [ClinicalAIGeneration]) -> String {
        var value = "ai_assistance:\n  used: true\n  generations:\n"
        for generation in generations {
            value += """
                - generation_id: \(generation.generationID)
                  accepted_by: \(generation.acceptedBy)
                  accepted_at: \(nullableQuoted(generation.acceptedAt))
                  source_id: \(generation.sourceID)
                  source_sha256: \(generation.sourceSHA256)
                  provenance_schema: \(generation.provenanceSchema)
                  engine: \(quoted(generation.engine))
                  model: \(nullableQuoted(generation.model))
                  response_id: \(nullableQuoted(generation.responseID))
                  prompt_version: \(nullableQuoted(generation.promptVersion))
                  locale: \(nullableQuoted(generation.locale))
                  generated_at: \(nullableQuoted(generation.generatedAt))
                  chunk_count: \(generation.chunkCount.map(String.init) ?? "null")
            """ + "\n"
        }
        return value
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
            throw patientAIIssue("filesystem.regular_file", url.path,
                                 "O arquivo clínico esperado não está disponível.")
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw patientAIIssue("filesystem.directory", url.path,
                                 "O diretório clínico esperado não está disponível.")
        }
    }

    private func recoveryDirectory(in vaultURL: URL) throws -> URL {
        let recovery = vaultURL.appending(path: "recovery", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: recovery.path) {
            try fileManager.createDirectory(at: recovery, withIntermediateDirectories: false)
        }
        try requireDirectory(recovery)
        return recovery
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
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

    private func nullableQuoted(_ value: String?) -> String {
        value.map(quoted) ?? "null"
    }
}

private func patientAIIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
