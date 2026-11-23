// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct FinalClinicalNoteMetadata: Equatable, Sendable {
    let noteID: String
    let patientID: String
    let encounterID: String
    let authorID: String
    let createdAt: String
    let updatedAt: String
    let finalizedAt: String
    let draftSHA256: String
}

struct FinalClinicalNoteSummary: Equatable, Sendable {
    let metadata: FinalClinicalNoteMetadata
    let url: URL
    let body: String
    let persistedData: Data
    let sha256: String
}

struct ClinicalAddendumMetadata: Equatable, Sendable {
    let addendumID: String
    let noteID: String
    let patientID: String
    let encounterID: String
    let authorID: String
    let createdAt: String
    let reason: String
    let finalSHA256: String
}

struct ClinicalAddendumSummary: Equatable, Sendable {
    let metadata: ClinicalAddendumMetadata
    let url: URL
    let body: String
    let persistedData: Data
    let sha256: String
}

struct EncounterFinalizationSummary: Equatable, Sendable {
    let finalNote: FinalClinicalNoteSummary
    let addenda: [ClinicalAddendumSummary]
}

enum EncounterFinalizationStatus: Equatable, Sendable {
    case draft
    case verified(EncounterFinalizationSummary)
    case altered(String)
}

struct FinalizationIdentity: Equatable, Sendable {
    let eventID: String

    static func generate(at date: Date = Date()) throws -> FinalizationIdentity {
        FinalizationIdentity(eventID: "evt_\(try UUIDv7.generate(at: date))")
    }
}

struct AddendumIdentity: Equatable, Sendable {
    let addendumID: String
    let eventID: String

    static func generate(at date: Date = Date()) throws -> AddendumIdentity {
        AddendumIdentity(
            addendumID: "add_\(try UUIDv7.generate(at: date))",
            eventID: "evt_\(try UUIDv7.generate(at: date.addingTimeInterval(0.001)))"
        )
    }
}

enum FinalizationStep: Equatable, Sendable {
    case temporaryArtifactWritten
    case artifactPublished
    case auditAppended
}

private struct LocalAuditAsset: Codable, Equatable, Sendable {
    let assetID: String
    let relativePath: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case relativePath = "relative_path"
        case sha256
    }
}

private struct LocalAuditEvent: Codable, Equatable, Sendable {
    let schema: String
    let eventID: String
    let eventType: String
    let patientID: String
    let encounterID: String
    let noteID: String
    let addendumID: String?
    let actorID: String
    let occurredAt: String
    let artifactPath: String
    let artifactSHA256: String
    let relatedAssets: [LocalAuditAsset]

    enum CodingKeys: String, CodingKey {
        case schema
        case eventID = "event_id"
        case eventType = "event_type"
        case patientID = "patient_id"
        case encounterID = "encounter_id"
        case noteID = "note_id"
        case addendumID = "addendum_id"
        case actorID = "actor_id"
        case occurredAt = "occurred_at"
        case artifactPath = "artifact_path"
        case artifactSHA256 = "artifact_sha256"
        case relatedAssets = "related_assets"
    }
}

struct ClinicalFinalizer {
    typealias FaultInjector = (FinalizationStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func finalize(
        patient: PatientSummary,
        encounter: EncounterSummary,
        identity: FinalizationIdentity,
        finalizedAt: Date
    ) throws -> EncounterFinalizationSummary {
        guard encounter.metadata.trashedAt == nil else {
            throw finalIssue(
                "finalization.trashed",
                encounter.metadata.encounterID,
                "Um rascunho na lixeira deve ser restaurado antes de ser finalizado."
            )
        }
        guard encounter.finalizationStatus == .draft else {
            throw finalIssue("finalization.already_final", encounter.metadata.encounterID, "A consulta já possui nota final.")
        }
        guard validEventID(identity.eventID) else {
            throw finalIssue("finalization.invalid_id", identity.eventID, "O identificador do evento não é seguro.")
        }
        let finalized = try coordinated(patient: patient) {
            try finalizeUncoordinated(
                patient: patient,
                encounter: encounter,
                identity: identity,
                finalizedAt: finalizedAt
            )
        }
        PatientClinicalChange.post(for: patient)
        return finalized
    }

    private func finalizeUncoordinated(
        patient: PatientSummary,
        encounter: EncounterSummary,
        identity: FinalizationIdentity,
        finalizedAt: Date
    ) throws -> EncounterFinalizationSummary {
        try validatePatientAndDraft(patient: patient, encounter: encounter)
        let notesURL = patient.url.appending(path: "content/notes", directoryHint: .isDirectory)
        let finalDirectory = notesURL.appending(path: "final", directoryHint: .isDirectory)
        let finalURL = finalDirectory.appending(path: "\(encounter.draft.metadata.noteID).md")
        let auditURL = patient.url.appending(path: ".openpep/audit.ndjson")
        try requireSafeDirectory(notesURL)
        try ensureSafeDirectory(finalDirectory)
        try requireSafeDirectory(auditURL.deletingLastPathComponent())
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw finalIssue("finalization.destination_exists", finalURL.path, "A nota final já existe e não será substituída.")
        }

        let draftSHA = digest(encounter.draft.persistedData)
        let finalData = Data(finalText(
            draft: encounter.draft,
            finalizedAt: finalizedAt,
            draftSHA256: draftSHA
        ).utf8)
        _ = try FinalizationDocumentValidator.validateFinal(data: finalData, source: finalURL.path)
        let finalSHA = digest(finalData)
        let relatedAssets = try patient.rawAssets
            .filter { $0.encounterID == encounter.metadata.encounterID }
            .sorted { $0.assetID < $1.assetID }
            .map { try verifiedAuditAsset($0, patientURL: patient.url) }
        let event = LocalAuditEvent(
            schema: "openpep/local-audit-event@1",
            eventID: identity.eventID,
            eventType: "note_finalized",
            patientID: patient.patientID,
            encounterID: encounter.metadata.encounterID,
            noteID: encounter.draft.metadata.noteID,
            addendumID: nil,
            actorID: encounter.draft.metadata.authorID,
            occurredAt: finalTimestamp(finalizedAt),
            artifactPath: "content/notes/final/\(encounter.draft.metadata.noteID).md",
            artifactSHA256: finalSHA,
            relatedAssets: relatedAssets
        )
        let eventData = try encodedEvent(event)
        try validateEvent(event, patientID: patient.patientID)

        let temporary = finalDirectory.appending(path: ".openpep-final-\(UUID().uuidString.lowercased())")
        var artifactPublished = false
        var auditAppended = false
        defer {
            if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
            if artifactPublished, !auditAppended, fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
            }
        }
        try finalData.write(to: temporary, options: [.withoutOverwriting])
        _ = try FinalizationDocumentValidator.validateFinal(data: Data(contentsOf: temporary), source: finalURL.path)
        try faultInjector?(.temporaryArtifactWritten)
        try fileManager.moveItem(at: temporary, to: finalURL)
        artifactPublished = true
        try faultInjector?(.artifactPublished)
        try append(eventData, to: auditURL)
        auditAppended = true
        try faultInjector?(.auditAppended)

        let reopenedStatuses = try FinalizationInspector(fileManager: fileManager).statuses(
            patientURL: patient.url,
            patientID: patient.patientID,
            encounterNoteIDs: Dictionary(uniqueKeysWithValues: patient.encounters.map {
                ($0.metadata.encounterID, $0.draft.metadata.noteID)
            })
        )
        let reopenedStatus = reopenedStatuses[encounter.metadata.encounterID] ?? .draft
        if case let .altered(message) = reopenedStatus {
            throw finalIssue("finalization.reopen", finalURL.path, message)
        }
        guard case let .verified(summary) = reopenedStatus else {
            throw finalIssue("finalization.reopen", finalURL.path, "A nota final não pôde ser verificada após a escrita.")
        }
        return summary
    }

    private func validatePatientAndDraft(patient: PatientSummary, encounter: EncounterSummary) throws {
        guard patient.patientID == encounter.metadata.patientID,
              patient.encounters.contains(where: { $0.metadata.encounterID == encounter.metadata.encounterID }) else {
            throw finalIssue("finalization.patient_binding", encounter.metadata.encounterID, "A consulta não pertence ao paciente.")
        }
        try requireSafeRegularFile(encounter.url)
        try requireSafeRegularFile(encounter.draft.url)
        let encounterData = try Data(contentsOf: encounter.url)
        let reopenedEncounter = try ClinicalDocumentValidator.validateEncounter(data: encounterData, source: encounter.url.path)
        guard reopenedEncounter.trashedAt == nil else {
            throw finalIssue(
                "finalization.trashed",
                encounter.url.path,
                "Um rascunho na lixeira deve ser restaurado antes de ser finalizado."
            )
        }
        let draftData = try Data(contentsOf: encounter.draft.url)
        let reopenedDraft = try ClinicalDocumentValidator.validateDraft(data: draftData, source: encounter.draft.url.path)
        guard reopenedEncounter == encounter.metadata,
              draftData == encounter.draft.persistedData,
              reopenedDraft.metadata == encounter.draft.metadata else {
            throw finalIssue("finalization.revision_conflict", encounter.draft.url.path, "O rascunho mudou. Reabra antes de finalizar.")
        }
        try ClinicalDocumentValidator.bind(
            encounter: reopenedEncounter,
            draft: reopenedDraft.metadata,
            expectedPatientID: patient.patientID
        )
        try ClinicalDocumentValidator.bindAISource(
            draft: reopenedDraft.metadata,
            encounterID: reopenedEncounter.encounterID,
            assets: patient.rawAssets
        )
        let workURL = patient.url.appending(
            path: "content/\(ProgressiveConsultationWorkStore.directoryName)/\(encounter.metadata.encounterID).json"
        )
        if fileManager.fileExists(atPath: workURL.path) {
            let work = try ProgressiveConsultationWorkStore(fileManager: fileManager).decode(
                data: Data(contentsOf: workURL, options: [.mappedIfSafe])
            )
            let vaultURL = patient.url.deletingLastPathComponent().deletingLastPathComponent()
            let manifestURL = vaultURL.appending(path: "vault.yaml")
            let vaultID = try VaultManifestValidator.validate(
                data: Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                source: manifestURL.path
            ).vaultID
            guard work.vaultID == vaultID,
                  work.patientID == patient.patientID,
                  work.encounterID == encounter.metadata.encounterID else {
                throw finalIssue("finalization.progressive_binding", workURL.path,
                                 "O acompanhamento pertence a outra consulta.")
            }
            let activeStates: [ConsultationWorkStatus] = [.preparing, .recording, .transcribing, .draining]
            guard !activeStates.contains(work.status), work.pendingRanges.isEmpty else {
                throw finalIssue(
                    "finalization.progressive_pending",
                    workURL.path,
                    "Conclua ou revise os trechos pendentes da transcrição antes de finalizar a consulta."
                )
            }
        }
    }

    private func finalText(draft: ClinicalDraftSummary, finalizedAt: Date, draftSHA256: String) -> String {
        let metadata = draft.metadata
        let frontmatter = """
        schema: openpep/clinical-note-final@1
        note_id: \(metadata.noteID)
        patient_id: \(metadata.patientID)
        encounter_id: \(metadata.encounterID)
        status: final
        note_type: \(metadata.noteType)
        author_id: \(metadata.authorID)
        created_at: \(finalQuoted(metadata.createdAt))
        updated_at: \(finalQuoted(metadata.updatedAt))
        finalized_at: \(finalQuoted(finalTimestamp(finalizedAt)))
        draft_sha256: \(draftSHA256)
        x_actor_assurance: local_device_owner_authentication
        """
        return "---\n" + frontmatter + "\n---\n\n" + draft.body
    }

    private func verifiedAuditAsset(_ asset: RawAssetSummary, patientURL: URL) throws -> LocalAuditAsset {
        try requireSafeRegularFile(asset.originalURL)
        let data = try Data(contentsOf: asset.originalURL, options: [.mappedIfSafe])
        guard data.count == asset.sizeBytes, digest(data) == asset.sha256 else {
            throw finalIssue("finalization.asset_hash_mismatch", asset.assetID, "Um documento relacionado foi alterado fora do aplicativo.")
        }
        let storedPath = relativePath(asset.originalURL, under: patientURL)
        guard !storedPath.isEmpty else {
            throw finalIssue("finalization.asset_path", asset.assetID, "O documento relacionado está fora do diretório do paciente.")
        }
        return LocalAuditAsset(
            assetID: asset.assetID,
            relativePath: storedPath,
            sha256: asset.sha256
        )
    }

    private func coordinated<T>(patient: PatientSummary, operation: () throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: patient.url,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            do { outcome = .success(try operation()) }
            catch { outcome = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw finalIssue("filesystem.coordination", patient.url.path, "A escrita coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func append(_ eventData: Data, to auditURL: URL) throws {
        if !fileManager.fileExists(atPath: auditURL.path) {
            guard fileManager.createFile(atPath: auditURL.path, contents: nil) else {
                throw finalIssue("finalization.audit_create", auditURL.path, "O audit log não pôde ser criado.")
            }
        }
        try requireSafeRegularFile(auditURL)
        try appendAuditLine(eventData, to: auditURL)
    }
}

struct ClinicalAddendumWriter {
    typealias FaultInjector = (FinalizationStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func add(
        patient: PatientSummary,
        encounter: EncounterSummary,
        identity: AddendumIdentity,
        reason: String,
        body: String,
        createdAt: Date
    ) throws -> EncounterFinalizationSummary {
        guard case let .verified(current) = encounter.finalizationStatus else {
            throw finalIssue("addendum.final_required", encounter.metadata.encounterID, "O adendo exige uma nota final íntegra.")
        }
        let normalizedReason = normalizeSingleLine(reason)
        let normalizedBody = normalizeFinalBody(body)
        guard !normalizedReason.isEmpty, normalizedReason.count <= 500 else {
            throw finalIssue("addendum.reason", "/reason", "Informe um motivo com até 500 caracteres.")
        }
        guard !normalizedBody.isEmpty, normalizedBody.utf8.count <= 1_048_576 else {
            throw finalIssue("addendum.body", "/body", "Informe o texto do adendo com até 1 MiB.")
        }
        guard validAddendumID(identity.addendumID), validEventID(identity.eventID) else {
            throw finalIssue("addendum.invalid_id", identity.addendumID, "O identificador do adendo não é seguro.")
        }

        var result: Result<EncounterFinalizationSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: patient.url, options: .forMerging, error: &coordinationError) { _ in
            do {
                result = .success(try addUncoordinated(
                    patient: patient,
                    encounter: encounter,
                    current: current,
                    identity: identity,
                    reason: normalizedReason,
                    body: normalizedBody,
                    createdAt: createdAt
                ))
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw finalIssue("filesystem.coordination", patient.url.path, "A escrita coordenada não foi concluída.") }
        let saved = try result.get()
        PatientClinicalChange.post(for: patient)
        return saved
    }

    private func addUncoordinated(
        patient: PatientSummary,
        encounter: EncounterSummary,
        current: EncounterFinalizationSummary,
        identity: AddendumIdentity,
        reason: String,
        body: String,
        createdAt: Date
    ) throws -> EncounterFinalizationSummary {
        try requireSafeRegularFile(current.finalNote.url)
        let currentFinalData = try Data(contentsOf: current.finalNote.url)
        guard currentFinalData == current.finalNote.persistedData,
              digest(currentFinalData) == current.finalNote.sha256 else {
            throw finalIssue("addendum.final_hash_mismatch", current.finalNote.url.path, "A nota final foi alterada fora do aplicativo.")
        }
        let notesURL = patient.url.appending(path: "content/notes", directoryHint: .isDirectory)
        let directory = notesURL.appending(path: "addenda", directoryHint: .isDirectory)
        try requireSafeDirectory(notesURL)
        try ensureSafeDirectory(directory)
        let url = directory.appending(path: "\(identity.addendumID).md")
        let auditURL = patient.url.appending(path: ".openpep/audit.ndjson")
        try requireSafeDirectory(auditURL.deletingLastPathComponent())
        guard !fileManager.fileExists(atPath: url.path) else {
            throw finalIssue("addendum.destination_exists", url.path, "O adendo já existe e não será substituído.")
        }
        let data = Data(addendumText(
            identity: identity,
            encounter: encounter,
            final: current.finalNote,
            reason: reason,
            body: body,
            createdAt: createdAt
        ).utf8)
        _ = try FinalizationDocumentValidator.validateAddendum(data: data, source: url.path)
        let sha = digest(data)
        let event = LocalAuditEvent(
            schema: "openpep/local-audit-event@1",
            eventID: identity.eventID,
            eventType: "note_addended",
            patientID: patient.patientID,
            encounterID: encounter.metadata.encounterID,
            noteID: current.finalNote.metadata.noteID,
            addendumID: identity.addendumID,
            actorID: encounter.draft.metadata.authorID,
            occurredAt: finalTimestamp(createdAt),
            artifactPath: "content/notes/addenda/\(identity.addendumID).md",
            artifactSHA256: sha,
            relatedAssets: []
        )
        try validateEvent(event, patientID: patient.patientID)
        let eventData = try encodedEvent(event)

        let temporary = directory.appending(path: ".openpep-addendum-\(UUID().uuidString.lowercased())")
        var published = false
        var appended = false
        defer {
            if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
            if published, !appended, fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
        try data.write(to: temporary, options: [.withoutOverwriting])
        _ = try FinalizationDocumentValidator.validateAddendum(data: Data(contentsOf: temporary), source: url.path)
        try faultInjector?(.temporaryArtifactWritten)
        try fileManager.moveItem(at: temporary, to: url)
        published = true
        try faultInjector?(.artifactPublished)
        try appendAudit(eventData, to: auditURL)
        appended = true
        try faultInjector?(.auditAppended)

        let reopenedStatuses = try FinalizationInspector(fileManager: fileManager).statuses(
            patientURL: patient.url,
            patientID: patient.patientID,
            encounterNoteIDs: Dictionary(uniqueKeysWithValues: patient.encounters.map {
                ($0.metadata.encounterID, $0.draft.metadata.noteID)
            })
        )
        let reopenedStatus = reopenedStatuses[encounter.metadata.encounterID] ?? .draft
        if case let .altered(message) = reopenedStatus {
            throw finalIssue("addendum.reopen", url.path, message)
        }
        guard case let .verified(reopened) = reopenedStatus else {
            throw finalIssue("addendum.reopen", url.path, "O adendo não pôde ser verificado após a escrita.")
        }
        return reopened
    }

    private func addendumText(
        identity: AddendumIdentity,
        encounter: EncounterSummary,
        final: FinalClinicalNoteSummary,
        reason: String,
        body: String,
        createdAt: Date
    ) -> String {
        let metadata = """
        schema: openpep/clinical-addendum@1
        addendum_id: \(identity.addendumID)
        note_id: \(final.metadata.noteID)
        patient_id: \(encounter.metadata.patientID)
        encounter_id: \(encounter.metadata.encounterID)
        author_id: \(encounter.draft.metadata.authorID)
        created_at: \(finalQuoted(finalTimestamp(createdAt)))
        reason: \(finalQuoted(reason))
        final_sha256: \(final.sha256)
        x_actor_assurance: local_device_owner_authentication
        """
        return "---\n" + metadata + "\n---\n\n" + body
    }

    private func appendAudit(_ data: Data, to url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw finalIssue("addendum.audit_missing", url.path, "O audit log da nota final está ausente.")
        }
        try requireSafeRegularFile(url)
        try appendAuditLine(data, to: url)
    }
}

enum FinalizationDocumentValidator {
    static func validateFinal(data: Data, source: String) throws -> (FinalClinicalNoteMetadata, String) {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: source)
        let root = try mapping(document.metadata)
        let fields = [
            "schema", "note_id", "patient_id", "encounter_id", "status", "note_type",
            "author_id", "created_at", "updated_at", "finalized_at", "draft_sha256",
            "x_actor_assurance",
        ]
        try exactFields(root, fields: fields)
        try require(string(root, "schema") == "openpep/clinical-note-final@1", "final.schema", "/schema")
        try require(string(root, "status") == "final", "final.status", "/status")
        try require(string(root, "note_type") == "progress", "final.note_type", "/note_type")
        try require(string(root, "x_actor_assurance") == "local_device_owner_authentication", "final.assurance", "/x_actor_assurance")
        let metadata = FinalClinicalNoteMetadata(
            noteID: try identifier(root, "note_id", prefix: "note_"),
            patientID: try identifier(root, "patient_id", prefix: "pt_"),
            encounterID: try identifier(root, "encounter_id", prefix: "enc_"),
            authorID: try identifier(root, "author_id", prefix: "usr_"),
            createdAt: try timestamp(root, "created_at"),
            updatedAt: try timestamp(root, "updated_at"),
            finalizedAt: try timestamp(root, "finalized_at"),
            draftSHA256: try sha(root, "draft_sha256")
        )
        try require(document.body.hasPrefix("\n") && document.body.hasSuffix("\n"), "final.body", "/body")
        return (metadata, String(document.body.dropFirst()))
    }

    static func validateAddendum(data: Data, source: String) throws -> (ClinicalAddendumMetadata, String) {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: source)
        let root = try mapping(document.metadata)
        let fields = [
            "schema", "addendum_id", "note_id", "patient_id", "encounter_id", "author_id",
            "created_at", "reason", "final_sha256", "x_actor_assurance",
        ]
        try exactFields(root, fields: fields)
        try require(string(root, "schema") == "openpep/clinical-addendum@1", "addendum.schema", "/schema")
        try require(string(root, "x_actor_assurance") == "local_device_owner_authentication", "addendum.assurance", "/x_actor_assurance")
        let reason = try string(root, "reason")
        try require(!reason.isEmpty && reason.count <= 500, "addendum.reason", "/reason")
        let addendumID = try string(root, "addendum_id")
        try require(validAddendumID(addendumID), "addendum.id", "/addendum_id")
        let metadata = ClinicalAddendumMetadata(
            addendumID: addendumID,
            noteID: try identifier(root, "note_id", prefix: "note_"),
            patientID: try identifier(root, "patient_id", prefix: "pt_"),
            encounterID: try identifier(root, "encounter_id", prefix: "enc_"),
            authorID: try identifier(root, "author_id", prefix: "usr_"),
            createdAt: try timestamp(root, "created_at"),
            reason: reason,
            finalSHA256: try sha(root, "final_sha256")
        )
        try require(document.body.hasPrefix("\n") && document.body.hasSuffix("\n"), "addendum.body", "/body")
        return (metadata, String(document.body.dropFirst()))
    }

    private static func mapping(_ value: YAMLValue) throws -> [String: YAMLValue] {
        guard case let .mapping(root) = value else { throw finalIssue("final.mapping", "/", "O frontmatter deve ser um mapa.") }
        return root
    }

    private static func exactFields(_ root: [String: YAMLValue], fields: [String]) throws {
        let expected = Set(fields)
        guard Set(root.keys) == expected else { throw finalIssue("final.fields", "/", "Os campos do artefato final divergem do perfil.") }
    }

    private static func string(_ root: [String: YAMLValue], _ key: String) throws -> String {
        guard case let .string(value)? = root[key] else { throw finalIssue("final.type", "/\(key)", "O campo deve ser texto.") }
        return value
    }

    private static func identifier(_ root: [String: YAMLValue], _ key: String, prefix: String) throws -> String {
        let value = try string(root, key)
        try require(validPrefixedUUID(value, prefix: prefix), "final.id", "/\(key)")
        return value
    }

    private static func timestamp(_ root: [String: YAMLValue], _ key: String) throws -> String {
        let value = try string(root, key)
        try require(parseFinalTimestamp(value) != nil, "final.timestamp", "/\(key)")
        return value
    }

    private static func sha(_ root: [String: YAMLValue], _ key: String) throws -> String {
        let value = try string(root, key)
        try require(value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "final.sha256", "/\(key)")
        return value
    }

    private static func require(_ condition: Bool, _ rule: String, _ path: String) throws {
        guard condition else { throw finalIssue(rule, path, "O valor não atende ao perfil FINAL-001.") }
    }
}

struct FinalizationInspector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func statuses(
        patientURL: URL,
        patientID: String,
        encounterNoteIDs: [String: String]
    ) throws -> [String: EncounterFinalizationStatus] {
        var result = Dictionary(uniqueKeysWithValues: encounterNoteIDs.keys.map { ($0, EncounterFinalizationStatus.draft) })
        let auditURL = patientURL.appending(path: ".openpep/audit.ndjson")
        guard fileManager.fileExists(atPath: auditURL.path) else {
            guard try artifactPaths(patientURL: patientURL).isEmpty else {
                throw finalIssue("finalization.orphan_artifact", patientURL.path, "Nota final ou adendo sem evento correspondente.")
            }
            return result
        }
        try requireSafeRegularFile(auditURL)
        let data = try Data(contentsOf: auditURL)
        guard data.isEmpty || data.last == 0x0a else {
            throw finalIssue("finalization.audit_truncated", auditURL.path, "A última linha do audit log está incompleta.")
        }
        let events = try data.split(separator: 0x0a).map { line -> LocalAuditEvent in
            guard line.count <= 1_048_576 else { throw finalIssue("finalization.audit_line_size", auditURL.path, "Uma linha do audit log excede 1 MiB.") }
            let event = try JSONDecoder().decode(LocalAuditEvent.self, from: Data(line))
            try validateEvent(event, patientID: patientID)
            return event
        }
        guard Set(events.map(\.eventID)).count == events.count else {
            throw finalIssue("finalization.audit_duplicate", auditURL.path, "O audit log contém event_id duplicado.")
        }
        guard Set(events.map(\.artifactPath)).count == events.count else {
            throw finalIssue("finalization.audit_duplicate", auditURL.path, "O audit log referencia o mesmo artefato mais de uma vez.")
        }
        let recordedArtifacts = Set(events.map(\.artifactPath))
        let storedArtifacts = try artifactPaths(patientURL: patientURL)
        guard recordedArtifacts == storedArtifacts else {
            throw finalIssue("finalization.orphan_artifact", patientURL.path, "Nota final ou adendo sem evento correspondente.")
        }
        for encounterID in encounterNoteIDs.keys {
            result[encounterID] = try status(
                patientURL: patientURL,
                patientID: patientID,
                encounterID: encounterID,
                noteID: encounterNoteIDs[encounterID]!,
                events: events
            )
        }
        let knownEncounters = Set(encounterNoteIDs.keys)
        guard events.allSatisfy({ knownEncounters.contains($0.encounterID) }) else {
            throw finalIssue("finalization.audit_orphan", auditURL.path, "O audit log referencia consulta ausente.")
        }
        return result
    }

    private func status(
        patientURL: URL,
        patientID: String,
        encounterID: String,
        noteID: String,
        events: [LocalAuditEvent]
    ) throws -> EncounterFinalizationStatus {
        let matching = events.filter { $0.encounterID == encounterID }
        let finalEvents = matching.filter { $0.eventType == "note_finalized" }
        guard !finalEvents.isEmpty else {
            return matching.isEmpty ? .draft : .altered("Há eventos de adendo sem uma nota final registrada.")
        }
        guard finalEvents.count == 1, let event = finalEvents.first else {
            return .altered("Há mais de um evento de finalização para esta consulta.")
        }
        do {
            guard event.noteID == noteID, event.addendumID == nil else {
                throw finalIssue("finalization.audit_binding", encounterID, "O evento final diverge do rascunho.")
            }
            let finalURL = try safeArtifactURL(event.artifactPath, under: patientURL)
            try requireSafeRegularFile(finalURL)
            let finalData = try Data(contentsOf: finalURL)
            guard digest(finalData) == event.artifactSHA256 else {
                throw finalIssue("finalization.hash_mismatch", event.artifactPath, "A nota final foi alterada fora do aplicativo.")
            }
            let parsed = try FinalizationDocumentValidator.validateFinal(data: finalData, source: finalURL.path)
            guard parsed.0.patientID == patientID,
                  parsed.0.encounterID == encounterID,
                  parsed.0.noteID == noteID,
                  parsed.0.authorID == event.actorID else {
                throw finalIssue("finalization.binding", event.artifactPath, "A nota final diverge do evento.")
            }
            for asset in event.relatedAssets {
                let assetURL = try safeArtifactURL(asset.relativePath, under: patientURL)
                try requireSafeRegularFile(assetURL)
                guard digest(try Data(contentsOf: assetURL, options: [.mappedIfSafe])) == asset.sha256 else {
                    throw finalIssue("finalization.asset_hash_mismatch", asset.assetID, "Um documento relacionado foi alterado fora do aplicativo.")
                }
            }
            let finalSummary = FinalClinicalNoteSummary(
                metadata: parsed.0,
                url: finalURL,
                body: parsed.1,
                persistedData: finalData,
                sha256: event.artifactSHA256
            )
            let addenda = try matching.filter { $0.eventType == "note_addended" }.map { addendumEvent -> ClinicalAddendumSummary in
                guard let addendumID = addendumEvent.addendumID,
                      addendumEvent.noteID == noteID,
                      addendumEvent.actorID == event.actorID else {
                    throw finalIssue("addendum.audit_binding", encounterID, "Um evento de adendo diverge da nota final.")
                }
                let url = try safeArtifactURL(addendumEvent.artifactPath, under: patientURL)
                try requireSafeRegularFile(url)
                let data = try Data(contentsOf: url)
                guard digest(data) == addendumEvent.artifactSHA256 else {
                    throw finalIssue("addendum.hash_mismatch", addendumEvent.artifactPath, "Um adendo foi alterado fora do aplicativo.")
                }
                let parsedAddendum = try FinalizationDocumentValidator.validateAddendum(data: data, source: url.path)
                guard parsedAddendum.0.addendumID == addendumID,
                      parsedAddendum.0.patientID == patientID,
                      parsedAddendum.0.encounterID == encounterID,
                      parsedAddendum.0.noteID == noteID,
                      parsedAddendum.0.finalSHA256 == event.artifactSHA256 else {
                    throw finalIssue("addendum.binding", addendumEvent.artifactPath, "O adendo diverge da nota final.")
                }
                return ClinicalAddendumSummary(
                    metadata: parsedAddendum.0,
                    url: url,
                    body: parsedAddendum.1,
                    persistedData: data,
                    sha256: addendumEvent.artifactSHA256
                )
            }.sorted { $0.metadata.createdAt < $1.metadata.createdAt }
            return .verified(EncounterFinalizationSummary(finalNote: finalSummary, addenda: addenda))
        } catch {
            return .altered(error.localizedDescription)
        }
    }

    private func artifactPaths(patientURL: URL) throws -> Set<String> {
        var result: Set<String> = []
        for directoryName in ["final", "addenda"] {
            let directory = patientURL.appending(path: "content/notes/\(directoryName)", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try requireSafeDirectory(directory)
            for url in try managedDirectoryEntries(in: directory, fileManager: fileManager) {
                try requireSafeRegularFile(url)
                guard url.pathExtension == "md", !url.lastPathComponent.hasPrefix(".") else {
                    throw finalIssue("finalization.artifact_layout", url.path, "O diretório contém artefato desconhecido.")
                }
                result.insert("content/notes/\(directoryName)/\(url.lastPathComponent)")
            }
        }
        return result
    }
}

private func validateEvent(_ event: LocalAuditEvent, patientID: String) throws {
    guard event.schema == "openpep/local-audit-event@1",
          validEventID(event.eventID),
          ["note_finalized", "note_addended"].contains(event.eventType),
          event.patientID == patientID,
          validPrefixedUUID(event.patientID, prefix: "pt_"),
          validPrefixedUUID(event.encounterID, prefix: "enc_"),
          validPrefixedUUID(event.noteID, prefix: "note_"),
          validPrefixedUUID(event.actorID, prefix: "usr_"),
          parseFinalTimestamp(event.occurredAt) != nil,
          event.artifactSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          !event.artifactPath.hasPrefix("/"), !event.artifactPath.contains("..") else {
        throw finalIssue("finalization.audit_event", event.eventID, "O evento local não atende ao perfil FINAL-001.")
    }
    if event.eventType == "note_finalized" {
        guard event.addendumID == nil,
              event.artifactPath == "content/notes/final/\(event.noteID).md" else {
            throw finalIssue("finalization.audit_event", event.eventID, "O evento final possui caminho ou addendum_id inválido.")
        }
    } else {
        guard let addendumID = event.addendumID,
              validAddendumID(addendumID),
              event.artifactPath == "content/notes/addenda/\(addendumID).md",
              event.relatedAssets.isEmpty else {
            throw finalIssue("finalization.audit_event", event.eventID, "O evento de adendo é inválido.")
        }
    }
    guard Set(event.relatedAssets.map(\.assetID)).count == event.relatedAssets.count,
          event.relatedAssets.allSatisfy({
              OpenPEPIdentifier.isAsset($0.assetID)
                  && !$0.relativePath.hasPrefix("/") && !$0.relativePath.contains("..")
                  && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
          }) else {
        throw finalIssue("finalization.audit_assets", event.eventID, "A lista de documentos relacionados é inválida.")
    }
}

private func encodedEvent(_ event: LocalAuditEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(event)
    data.append(0x0a)
    return data
}

private func appendAuditLine(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let previousEnd = try handle.seekToEnd()
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
    } catch {
        try? handle.truncate(atOffset: previousEnd)
        try? handle.synchronize()
        throw error
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func finalTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func parseFinalTimestamp(_ value: String) -> Date? {
    guard value.hasSuffix("Z") else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let result = formatter.date(from: value) { return result }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func normalizeSingleLine(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func normalizeFinalBody(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .precomposedStringWithCanonicalMapping
    while result.hasSuffix("\n") { result.removeLast() }
    if !result.isEmpty { result.append("\n") }
    return result
}

private func finalQuoted(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func validPrefixedUUID(_ value: String, prefix: String) -> Bool {
    value.range(
        of: "^\(prefix)[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression
    ) != nil
}

private func validEventID(_ value: String) -> Bool { validPrefixedUUID(value, prefix: "evt_") }
private func validAddendumID(_ value: String) -> Bool { validPrefixedUUID(value, prefix: "add_") }

private func relativePath(_ url: URL, under root: URL) -> String {
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    let path = canonicalURL.path
    return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : ""
}

private func safeArtifactURL(_ relative: String, under root: URL) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
        throw finalIssue("finalization.path", relative, "O caminho registrado não é seguro.")
    }
    let url = root.appending(path: relative).standardizedFileURL
    guard !relativePath(url, under: root).isEmpty else {
        throw finalIssue("finalization.path", relative, "O caminho sai do diretório do paciente.")
    }
    return url
}

private func ensureSafeDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    try requireSafeDirectory(url)
}

private func requireSafeDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw finalIssue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
    }
}

private func requireSafeRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw finalIssue("filesystem.file", url.path, "Era esperado um arquivo regular sem link simbólico.")
    }
}

private func finalIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
