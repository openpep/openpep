// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct ProgressiveSummaryUndoToken: Equatable, Sendable {
    let draftURL: URL
    let encounterURL: URL
    let previousDraftData: Data
    let publishedDraftData: Data
    let sourceOriginalURL: URL
    let sourceOriginalData: Data
    let sourceSidecarURL: URL
    let sourceSidecarData: Data
}

struct ProgressiveSummaryInsertionResult: Equatable, Sendable {
    let draft: ClinicalDraftSummary
    let source: RawAssetImportResult
    let undoToken: ProgressiveSummaryUndoToken
}

enum ProgressiveSummaryInsertionIssue: Error, LocalizedError, Equatable, Sendable {
    case invalidBlock
    case duplicateGeneration
    case sourceMismatch
    case revisionConflict
    case undoUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidBlock:
            "O bloco de resumo não contém proveniência suficiente para ser adicionado."
        case .duplicateGeneration:
            "Este bloco já foi adicionado ao rascunho."
        case .sourceMismatch:
            "A fonte preservada do resumo diverge do bloco visível."
        case .revisionConflict:
            "A consulta ou o rascunho mudou. Reabra antes de adicionar o resumo."
        case .undoUnavailable:
            "A nota foi alterada depois da adição. Revise a diferença antes de desfazer."
        }
    }
}

struct ProgressiveSummaryInsertionService {
    private static let provenanceSchema = "openpep/progressive-summary-provenance@1"
    private static let progressivePromptVersions = Set([
        "openpep/progressive-consultation-summary-pt-BR@1",
        "openpep/progressive-consultation-summary-pt-BR@2",
        "openpep/progressive-consultation-summary-pt-BR@3",
        "openpep/progressive-consultation-summary-pt-BR@4",
        "openpep/progressive-consultation-summary-pt-BR@5",
    ])
    private static let appleEngine = "apple/FoundationModels.SystemLanguageModel"
    private static let openAIEngine = "openai/responses"

    private let fileManager: FileManager
    private let documentImporter: GeneralDocumentImporter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        documentImporter = GeneralDocumentImporter(fileManager: fileManager)
    }

    func insert(
        _ block: ConsultationSummaryBlock,
        into encounter: EncounterSummary,
        patient: PatientSummary,
        deviceID: String,
        acceptedBy: String,
        sourceIdentity: RawAssetCreationIdentity,
        acceptedAt: Date = Date()
    ) throws -> ProgressiveSummaryInsertionResult {
        guard encounter.finalizationStatus == .draft,
              patient.patientID == encounter.metadata.patientID,
              acceptedBy == encounter.draft.metadata.authorID else {
            throw issue("progressive_summary.context", encounter.metadata.encounterID,
                        "Abra o rascunho original para adicionar este bloco.")
        }
        try validate(block, acceptedBy: acceptedBy)
        try rejectDuplicate(block.generation.generationID, in: encounter.draft.metadata)

        let expectedEncounterData = try Data(contentsOf: encounter.url)
        let expectedDraftData = encounter.draft.persistedData
        guard try ClinicalDocumentValidator.validateEncounter(
            data: expectedEncounterData, source: encounter.url.path
        ) == encounter.metadata,
        try ClinicalDocumentValidator.validateDraft(
            data: expectedDraftData, source: encounter.draft.url.path
        ).metadata == encounter.draft.metadata else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }

        let sourceData = try snapshotData(for: block, acceptedBy: acceptedBy, acceptedAt: acceptedAt)
        let sourceHash = digest(sourceData)
        let temporaryURL = fileManager.temporaryDirectory.appending(
            path: "openpep-progressive-summary-source-\(UUID().uuidString.lowercased()).txt"
        )
        try sourceData.write(to: temporaryURL, options: [.withoutOverwriting])
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let imported = try documentImporter.importDocument(
            from: temporaryURL,
            into: patient,
            encounterID: encounter.metadata.encounterID,
            deviceID: deviceID,
            identity: sourceIdentity,
            importedAt: acceptedAt
        )
        guard imported.sha256 == sourceHash else {
            throw ProgressiveSummaryInsertionIssue.sourceMismatch
        }
        let sourceOriginalData = try safeData(at: imported.originalURL)
        let sourceSidecarData = try safeData(at: imported.sidecarURL)

        do {
            let published = try publish(
                block: block,
                sourceAssetID: imported.assetID,
                sourceHash: sourceHash,
                acceptedBy: acceptedBy,
                acceptedAt: acceptedAt,
                encounter: encounter,
                patientID: patient.patientID,
                expectedEncounterData: expectedEncounterData,
                expectedDraftData: expectedDraftData
            )
            let vaultURL = patient.url.deletingLastPathComponent().deletingLastPathComponent()
            let reopened = try VaultReader(fileManager: fileManager).open(vaultURL)
            guard let reopenedPatient = reopened.patients.first(where: { $0.patientID == patient.patientID }),
                  let reopenedEncounter = reopenedPatient.encounters.first(where: {
                      $0.metadata.encounterID == encounter.metadata.encounterID
                  }),
                  reopenedEncounter.draft.persistedData == published.persistedData,
                  reopenedEncounter.draft.metadata.schema == "openpep/clinical-note@4",
                  reopenedEncounter.draft.metadata.aiAssistance.generations.contains(where: {
                      $0.generationID == block.generation.generationID &&
                      $0.sourceID == imported.assetID && $0.sourceSHA256 == sourceHash
                  }),
                  let source = reopenedPatient.rawAssets.first(where: { $0.assetID == imported.assetID }),
                  source.encounterID == encounter.metadata.encounterID,
                  source.sha256 == sourceHash else {
                throw issue("progressive_summary.reopen", imported.assetID,
                            "A nota ou a fonte não puderam ser confirmadas após a adição.")
            }
            return ProgressiveSummaryInsertionResult(
                draft: published,
                source: imported,
                undoToken: ProgressiveSummaryUndoToken(
                    draftURL: encounter.draft.url,
                    encounterURL: encounter.url,
                    previousDraftData: expectedDraftData,
                    publishedDraftData: published.persistedData,
                    sourceOriginalURL: imported.originalURL,
                    sourceOriginalData: sourceOriginalData,
                    sourceSidecarURL: imported.sidecarURL,
                    sourceSidecarData: sourceSidecarData
                )
            )
        } catch {
            // The source snapshot is durable evidence once imported. It is deliberately
            // preserved if publication could have completed before an error was observed.
            throw error
        }
    }

    func undo(_ token: ProgressiveSummaryUndoToken) throws -> ClinicalDraftSummary {
        var outcome: Result<ClinicalDraftSummary, Error>?
        var coordinationError: NSError?
        let patientURL = token.encounterURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSFileCoordinator().coordinate(
            writingItemAt: patientURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            do {
                outcome = .success(try undoUncoordinated(token))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ProgressiveSummaryInsertionIssue.undoUnavailable }
        let restored = try outcome.get()
        let vaultURL = token.encounterURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let reopened = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard let patient = reopened.patients.first(where: { $0.patientID == restored.metadata.patientID }),
              let encounter = patient.encounters.first(where: {
                  $0.metadata.encounterID == restored.metadata.encounterID
              }),
              encounter.draft.persistedData == token.previousDraftData else {
            throw ProgressiveSummaryInsertionIssue.undoUnavailable
        }
        return restored
    }

    private func undoUncoordinated(_ token: ProgressiveSummaryUndoToken) throws -> ClinicalDraftSummary {
        try requireRegularFile(token.draftURL)
        try requireRegularFile(token.encounterURL)
        guard try safeData(at: token.draftURL) == token.publishedDraftData else {
            throw ProgressiveSummaryInsertionIssue.undoUnavailable
        }
        let notesURL = token.draftURL.deletingLastPathComponent().deletingLastPathComponent()
        let finalURL = notesURL.appending(path: "final/\(try ClinicalDocumentValidator.validateDraft(data: token.publishedDraftData, source: token.draftURL.path).metadata.noteID).md")
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ProgressiveSummaryInsertionIssue.undoUnavailable
        }
        let restored = try atomicReplace(
            token.draftURL,
            expectedCurrent: token.publishedDraftData,
            replacement: token.previousDraftData
        )
        let parsed = try ClinicalDocumentValidator.validateDraft(data: restored, source: token.draftURL.path)
        guard restored == token.previousDraftData else { throw ProgressiveSummaryInsertionIssue.undoUnavailable }
        return ClinicalDraftSummary(
            metadata: parsed.metadata,
            url: token.draftURL,
            body: parsed.body,
            persistedData: restored
        )
    }

    private func publish(
        block: ConsultationSummaryBlock,
        sourceAssetID: String,
        sourceHash: String,
        acceptedBy: String,
        acceptedAt: Date,
        encounter: EncounterSummary,
        patientID: String,
        expectedEncounterData: Data,
        expectedDraftData: Data
    ) throws -> ClinicalDraftSummary {
        var outcome: Result<ClinicalDraftSummary, Error>?
        var coordinationError: NSError?
        let patientURL = encounter.url.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        NSFileCoordinator().coordinate(
            writingItemAt: patientURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            do {
                outcome = .success(try publishUncoordinated(
                    block: block,
                    sourceAssetID: sourceAssetID,
                    sourceHash: sourceHash,
                    acceptedBy: acceptedBy,
                    acceptedAt: acceptedAt,
                    encounter: encounter,
                    patientID: patientID,
                    expectedEncounterData: expectedEncounterData,
                    expectedDraftData: expectedDraftData
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ProgressiveSummaryInsertionIssue.revisionConflict }
        return try outcome.get()
    }

    private func publishUncoordinated(
        block: ConsultationSummaryBlock,
        sourceAssetID: String,
        sourceHash: String,
        acceptedBy: String,
        acceptedAt: Date,
        encounter: EncounterSummary,
        patientID: String,
        expectedEncounterData: Data,
        expectedDraftData: Data
    ) throws -> ClinicalDraftSummary {
        try requireRegularFile(encounter.url)
        try requireRegularFile(encounter.draft.url)
        let currentEncounterData = try safeData(at: encounter.url)
        let currentDraftData = try safeData(at: encounter.draft.url)
        guard currentEncounterData == expectedEncounterData,
              currentDraftData == expectedDraftData else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
        let currentEncounter = try ClinicalDocumentValidator.validateEncounter(
            data: currentEncounterData, source: encounter.url.path
        )
        let previous = try ClinicalDocumentValidator.validateDraft(
            data: currentDraftData, source: encounter.draft.url.path
        )
        guard currentEncounter == encounter.metadata,
              previous.metadata == encounter.draft.metadata,
              currentEncounter.trashedAt == nil else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
        try ClinicalDocumentValidator.bind(
            encounter: currentEncounter,
            draft: previous.metadata,
            expectedPatientID: patientID
        )
        try rejectDuplicate(block.generation.generationID, in: previous.metadata)
        guard previous.metadata.sourceIDs.count < 100 else {
            throw issue("progressive_summary.source_limit", previous.metadata.noteID,
                        "A nota já atingiu o limite de 100 fontes aceitas.")
        }

        let legacy = try existingGenerations(in: previous)
        let generation = ClinicalAIGeneration(
            generationID: block.generation.generationID,
            acceptedBy: acceptedBy,
            acceptedAt: timestamp(acceptedAt),
            sourceID: sourceAssetID,
            sourceSHA256: sourceHash,
            provenanceSchema: Self.provenanceSchema,
            engine: block.generation.engine,
            model: block.generation.model,
            responseID: block.generation.responseID,
            promptVersion: block.generation.promptVersion,
            locale: "pt-BR",
            generatedAt: timestamp(block.generation.generatedAt),
            chunkCount: block.generation.segmentReferences.count
        )
        let generations = legacy + [generation]
        guard generations.count <= 100 else {
            throw issue("progressive_summary.generation_limit", previous.metadata.noteID,
                        "A nota já atingiu o limite de 100 gerações aceitas.")
        }
        let sources = legacy.map(\.sourceID) + [sourceAssetID]
        let frontmatter = try replacingTopLevelBlock(
            "ai_assistance",
            in: try replacingTopLevelBlock(
                "source_ids",
                in: previous.frontmatter.replacingOccurrences(
                    of: "schema: \(previous.metadata.schema)\n",
                    with: "schema: openpep/clinical-note@4\n"
                ),
                with: sourceMetadata(sources)
            ),
            with: assistanceMetadata(generations)
        ).replacingOccurrences(
            of: "updated_at: \"\(previous.metadata.updatedAt)\"\n",
            with: "updated_at: \"\(timestamp(acceptedAt))\"\n"
        )
        let body = appendedBody(previous.body, block.editedText)
        let candidate = Data(("---\n" + frontmatter + "---\n\n" + body).utf8)
        let parsedCandidate = try ClinicalDocumentValidator.validateDraft(
            data: candidate, source: encounter.draft.url.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: currentEncounter,
            draft: parsedCandidate.metadata,
            expectedPatientID: patientID
        )
        return try atomicPublish(
            at: encounter.draft.url,
            expectedCurrent: expectedDraftData,
            candidate: candidate
        )
    }

    private func atomicPublish(
        at draftURL: URL,
        expectedCurrent: Data,
        candidate: Data
    ) throws -> ClinicalDraftSummary {
        let temporary = draftURL.deletingLastPathComponent().appending(
            path: ".openpep-progressive-summary-\(UUID().uuidString.lowercased())"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try candidate.write(to: temporary, options: [.withoutOverwriting])
        guard try safeData(at: draftURL) == expectedCurrent else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
        _ = try fileManager.replaceItemAt(
            draftURL,
            withItemAt: temporary,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
        let saved = try safeData(at: draftURL)
        guard saved == candidate else { throw ProgressiveSummaryInsertionIssue.revisionConflict }
        let parsed = try ClinicalDocumentValidator.validateDraft(data: saved, source: draftURL.path)
        return ClinicalDraftSummary(metadata: parsed.metadata, url: draftURL, body: parsed.body, persistedData: saved)
    }

    private func atomicReplace(_ url: URL, expectedCurrent: Data, replacement: Data) throws -> Data {
        let temporary = url.deletingLastPathComponent().appending(
            path: ".openpep-progressive-summary-undo-\(UUID().uuidString.lowercased())"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try replacement.write(to: temporary, options: [.withoutOverwriting])
        guard try safeData(at: url) == expectedCurrent else {
            throw ProgressiveSummaryInsertionIssue.undoUnavailable
        }
        _ = try fileManager.replaceItemAt(
            url,
            withItemAt: temporary,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
        return try safeData(at: url)
    }

    private func existingGenerations(in draft: ParsedClinicalDraft) throws -> [ClinicalAIGeneration] {
        switch draft.metadata.schema {
        case "openpep/clinical-note@1":
            return []
        case "openpep/clinical-note@2":
            guard let generationID = draft.metadata.aiAssistance.generationID,
                  let acceptedBy = draft.metadata.aiAssistance.reviewedBy,
                  let sourceID = draft.metadata.sourceIDs.first,
                  let sourceHash = draft.metadata.aiAssistance.sourceSHA256,
                  let provenance = draft.metadata.aiAssistance.provenanceSchema,
                  let engine = draft.metadata.aiAssistance.engine else {
                throw ProgressiveSummaryInsertionIssue.revisionConflict
            }
            return [ClinicalAIGeneration(
                generationID: generationID,
                acceptedBy: acceptedBy,
                acceptedAt: nil,
                sourceID: sourceID,
                sourceSHA256: sourceHash,
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
            return draft.metadata.aiAssistance.generations
        default:
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
    }

    private func validate(_ block: ConsultationSummaryBlock, acceptedBy: String) throws {
        let generation = block.generation
        guard block.state != .added,
              block.state != .needsReview,
              !normalizedBody(block.editedText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              block.editedText.count <= 500_000,
              matches(generation.generationID, "^gen_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
              !generation.source.isEmpty,
              generation.source.count <= 2_000_000,
              !generation.segmentReferences.isEmpty,
              Set(generation.segmentReferences).count == generation.segmentReferences.count,
              generation.segmentReferences.allSatisfy({ !$0.segmentID.isEmpty && $0.revision > 0 }),
              (Self.progressivePromptVersions.contains(generation.promptVersion) ||
                (generation.promptVersion == AIPromptCatalog.finalConsultationSummaryApple.id &&
                 generation.engine == Self.appleEngine)),
              ((generation.engine == Self.appleEngine &&
                generation.model == nil && generation.responseID == nil) ||
               (generation.engine == Self.openAIEngine &&
                isSafeProviderValue(generation.model) && isSafeProviderValue(generation.responseID))),
              matches(acceptedBy, "^usr_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") else {
            throw ProgressiveSummaryInsertionIssue.invalidBlock
        }
    }

    private func snapshotData(
        for block: ConsultationSummaryBlock,
        acceptedBy: String,
        acceptedAt: Date
    ) throws -> Data {
        let references = block.generation.segmentReferences.map {
            "- segment_id: \($0.segmentID)\n  revision: \($0.revision)"
        }.joined(separator: "\n")
        let text = """
        Fonte de resumo progressivo aceita

        Geração: \(block.generation.generationID)
        Motor: \(block.generation.engine)
        Modelo: \(block.generation.model ?? "local")
        Resposta: \(block.generation.responseID ?? "não aplicável")
        Prompt: \(block.generation.promptVersion)
        Gerado em: \(timestamp(block.generation.generatedAt))
        Aceito por: \(acceptedBy)
        Aceito em: \(timestamp(acceptedAt))
        Intervalo: \(block.range.startSeconds)–\(block.range.endSeconds)s\(block.range.isApproximate ? " aproximado" : "")

        Referências de segmentos:
        \(references)

        --- Fonte estabilizada ---

        \(block.generation.source)

        --- Texto efetivamente aceito ---

        \(normalizedBody(block.editedText))
        """
        return Data(text.precomposedStringWithCanonicalMapping.utf8)
    }

    private func rejectDuplicate(_ generationID: String, in draft: ClinicalDraftMetadata) throws {
        guard draft.aiAssistance.generationID != generationID,
              !draft.aiAssistance.generations.contains(where: { $0.generationID == generationID }) else {
            throw ProgressiveSummaryInsertionIssue.duplicateGeneration
        }
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

    private func appendedBody(_ previous: String, _ accepted: String) -> String {
        let prior = normalizedBody(previous)
        let addition = normalizedBody(accepted)
        return prior.isEmpty ? addition : prior + "\n" + addition
    }

    private func replacingTopLevelBlock(_ key: String, in frontmatter: String, with replacement: String) throws -> String {
        var lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indexes = lines.indices.filter { lines[$0].hasPrefix("\(key):") }
        guard indexes.count == 1, let start = indexes.first else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
        var end = start + 1
        while end < lines.count && (lines[end].hasPrefix(" ") || lines[end].isEmpty) { end += 1 }
        let replacementLines = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.replaceSubrange(start..<end, with: replacementLines.dropLast())
        return lines.joined(separator: "\n")
    }

    private func safeData(at url: URL) throws -> Data {
        try requireRegularFile(url)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw issue("filesystem.regular_file", url.path, "O arquivo clínico esperado não está disponível.")
        }
    }

    private func normalizedBody(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        while value.hasSuffix("\n") { value.removeLast() }
        if !value.isEmpty { value.append("\n") }
        return value
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSafeProviderValue(_ value: String?) -> Bool {
        guard let value, (1...256).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
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

private func issue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
