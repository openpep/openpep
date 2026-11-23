// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct DocumentImportBatchItem: Equatable, Sendable {
    let sourceURL: URL
    let identity: RawAssetCreationIdentity
}

struct DocumentImportBatchCompletion: Equatable, Sendable {
    let item: DocumentImportBatchItem
    let result: RawAssetImportResult
}

struct DocumentImportBatchFailure: Error, Equatable, LocalizedError, Sendable {
    let rule: String
    let path: String
    let message: String

    var errorDescription: String? { message }
}

struct DocumentImportBatchResult: Equatable, Sendable {
    let completed: [DocumentImportBatchCompletion]
    let pending: [DocumentImportBatchItem]
    let failure: DocumentImportBatchFailure?

    var succeeded: Bool { failure == nil && pending.isEmpty }
}

enum DocumentImportBatchStep: Equatable, Sendable {
    case itemPublished(String)
}

struct DocumentImportBatch: Sendable {
    typealias FaultInjector = @Sendable (DocumentImportBatchStep) throws -> Void

    private let faultInjector: FaultInjector?
    private var fileManager: FileManager { FileManager() }

    init(faultInjector: FaultInjector? = nil) {
        self.faultInjector = faultInjector
    }

    nonisolated func run(
        items: [DocumentImportBatchItem],
        in vaultURL: URL,
        expectedVaultID: String,
        patientID: String,
        encounterID: String?,
        importedAt: Date = Date()
    ) -> DocumentImportBatchResult {
        let expectedDeviceID: String
        do {
            try validateBatch(items, patientID: patientID, encounterID: encounterID)
            expectedDeviceID = try currentDestination(
                vaultURL: vaultURL,
                expectedVaultID: expectedVaultID,
                patientID: patientID,
                encounterID: encounterID,
                expectedDeviceID: nil
            ).deviceID
        } catch {
            return DocumentImportBatchResult(
                completed: [],
                pending: items,
                failure: failure(from: error, path: vaultURL.path)
            )
        }

        var completed: [DocumentImportBatchCompletion] = []
        for (index, item) in items.enumerated() {
            do {
                let imported = try store(
                    item,
                    vaultURL: vaultURL,
                    expectedVaultID: expectedVaultID,
                    patientID: patientID,
                    encounterID: encounterID,
                    expectedDeviceID: expectedDeviceID,
                    importedAt: importedAt
                )
                completed.append(DocumentImportBatchCompletion(item: item, result: imported))
            } catch {
                return DocumentImportBatchResult(
                    completed: completed,
                    pending: Array(items[index...]),
                    failure: failure(from: error, path: item.sourceURL.path)
                )
            }
        }
        return DocumentImportBatchResult(completed: completed, pending: [], failure: nil)
    }

    private nonisolated func store(
        _ item: DocumentImportBatchItem,
        vaultURL: URL,
        expectedVaultID: String,
        patientID: String,
        encounterID: String?,
        expectedDeviceID: String,
        importedAt: Date
    ) throws -> RawAssetImportResult {
        let sourceGranted = item.sourceURL.startAccessingSecurityScopedResource()
        defer { if sourceGranted { item.sourceURL.stopAccessingSecurityScopedResource() } }
        let current = try currentDestination(
            vaultURL: vaultURL,
            expectedVaultID: expectedVaultID,
            patientID: patientID,
            encounterID: encounterID,
            expectedDeviceID: expectedDeviceID
        )
        let source = try sourceSnapshot(item.sourceURL)
        if let existing = try existingResult(
            identity: item.identity,
            source: source,
            patient: current.patient,
            encounterID: encounterID,
            deviceID: current.deviceID
        ) {
            return existing
        }

        do {
            _ = try GeneralDocumentImporter(fileManager: fileManager).importDocument(
                from: item.sourceURL,
                into: current.patient,
                encounterID: encounterID,
                deviceID: current.deviceID,
                identity: item.identity,
                importedAt: importedAt
            )
        } catch {
            let importError = error
            let reopened = try currentDestination(
                vaultURL: vaultURL,
                expectedVaultID: expectedVaultID,
                patientID: patientID,
                encounterID: encounterID,
                expectedDeviceID: expectedDeviceID
            )
            if let existing = try existingResult(
                identity: item.identity,
                source: source,
                patient: reopened.patient,
                encounterID: encounterID,
                deviceID: reopened.deviceID
            ) {
                return existing
            }
            throw importError
        }

        try faultInjector?(.itemPublished(item.identity.assetID))
        let reopened = try currentDestination(
            vaultURL: vaultURL,
            expectedVaultID: expectedVaultID,
            patientID: patientID,
            encounterID: encounterID,
            expectedDeviceID: expectedDeviceID
        )
        guard let result = try existingResult(
            identity: item.identity,
            source: source,
            patient: reopened.patient,
            encounterID: encounterID,
            deviceID: reopened.deviceID
        ) else {
            throw batchIssue(
                "document_import_batch.reopen_missing",
                item.identity.assetID,
                "O documento copiado não foi localizado ao reabrir o prontuário."
            )
        }
        return result
    }

    private nonisolated func currentDestination(
        vaultURL: URL,
        expectedVaultID: String,
        patientID: String,
        encounterID: String?,
        expectedDeviceID: String?
    ) throws -> (patient: PatientSummary, deviceID: String) {
        let vault = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard vault.manifest.vaultID == expectedVaultID else {
            throw batchIssue(
                "document_import_batch.vault_changed",
                vaultURL.path,
                "A identidade do prontuário mudou. Reabra antes de importar."
            )
        }
        if let expectedDeviceID, vault.manifest.deviceID != expectedDeviceID {
            throw batchIssue(
                "document_import_batch.vault_changed",
                vaultURL.path,
                "A identidade do dispositivo do prontuário mudou. Reabra antes de importar."
            )
        }
        guard vault.writingAllowed else {
            throw batchIssue(
                "document_import_batch.read_only",
                vaultURL.path,
                "O prontuário está somente para leitura."
            )
        }
        let expectedPatientURL = vaultURL.appending(
            path: "patients/\(patientID)",
            directoryHint: .isDirectory
        )
        guard let patient = vault.patients.first(where: {
            $0.patientID == patientID
                && $0.url.standardizedFileURL == expectedPatientURL.standardizedFileURL
                && $0.record?.status == .active
        }) else {
            throw batchIssue(
                "document_import_batch.patient_unavailable",
                patientID,
                "O paciente não está disponível ou foi arquivado. Reabra antes de importar."
            )
        }
        if let encounterID {
            guard patient.encounters.contains(where: {
                $0.metadata.encounterID == encounterID
                    && $0.metadata.trashedAt == nil
                    && isAvailableForImport($0.finalizationStatus)
            }),
            !patient.trashedEncounters.contains(where: { $0.metadata.encounterID == encounterID }) else {
                throw batchIssue(
                    "document_import_batch.encounter_unavailable",
                    encounterID,
                    "A consulta não está disponível ou foi descartada. Reabra antes de importar."
                )
            }
        }
        return (patient, vault.manifest.deviceID)
    }

    private nonisolated func sourceSnapshot(_ sourceURL: URL) throws -> (
        data: Data,
        descriptor: DocumentImportDescriptor,
        originalName: String
    ) {
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= DocumentImportDescriptor.maximumBytes else {
            throw batchIssue(
                "document_import.source",
                sourceURL.lastPathComponent,
                "Escolha um arquivo regular de até 25 MiB, sem link simbólico."
            )
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        return (
            data,
            try DocumentImportDescriptor.inspect(data: data, sourceURL: sourceURL),
            sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping
        )
    }

    private nonisolated func isAvailableForImport(_ status: EncounterFinalizationStatus) -> Bool {
        if case .altered = status { return false }
        return true
    }

    private nonisolated func existingResult(
        identity: RawAssetCreationIdentity,
        source: (data: Data, descriptor: DocumentImportDescriptor, originalName: String),
        patient: PatientSummary,
        encounterID: String?,
        deviceID: String
    ) throws -> RawAssetImportResult? {
        let matching = (patient.rawAssets + patient.trashedRawAssets).filter {
            $0.assetID == identity.assetID
        }
        guard !matching.isEmpty else { return nil }
        let expectedHash = digest(source.data)
        guard matching.count == 1,
              let asset = matching.first,
              patient.rawAssets.contains(where: { $0.assetID == identity.assetID }),
              asset.encounterID == encounterID,
              asset.originalName == source.originalName,
              asset.mediaType == source.descriptor.mediaType,
              asset.fileExtension == source.descriptor.fileExtension,
              asset.sizeBytes == source.data.count,
              asset.sha256 == expectedHash,
              try dataIfSafe(at: asset.originalURL) == source.data else {
            throw batchIssue(
                "document_import_batch.identity_conflict",
                identity.assetID,
                "A identidade desta tentativa já pertence a outro conteúdo ou vínculo."
            )
        }
        let sidecarURL = asset.originalURL.deletingLastPathComponent().appending(
            path: "\(identity.assetID).meta.md",
            directoryHint: .notDirectory
        )
        let sidecar = try VaultManifestValidator.validateRawAssetSidecar(
            data: dataIfSafe(at: sidecarURL),
            source: sidecarURL.path
        )
        guard sidecar.assetID == identity.assetID,
              sidecar.patientID == patient.patientID,
              sidecar.encounterID == encounterID,
              sidecar.originalName == source.originalName,
              sidecar.mediaType == source.descriptor.mediaType,
              sidecar.fileExtension == source.descriptor.fileExtension,
              sidecar.sizeBytes == source.data.count,
              sidecar.sha256 == expectedHash,
              sidecar.deviceID == deviceID else {
            throw batchIssue(
                "document_import_batch.identity_conflict",
                identity.assetID,
                "A identidade desta tentativa já pertence a outro conteúdo ou vínculo."
            )
        }
        return RawAssetImportResult(
            assetID: identity.assetID,
            originalURL: asset.originalURL,
            sidecarURL: sidecarURL,
            sha256: expectedHash
        )
    }

    private nonisolated func dataIfSafe(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw batchIssue(
                "document_import_batch.stored_file",
                url.path,
                "O documento guardado deve ser um arquivo regular sem link simbólico."
            )
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private nonisolated func validateBatch(
        _ items: [DocumentImportBatchItem],
        patientID: String,
        encounterID: String?
    ) throws {
        guard !items.isEmpty,
              items.count <= DocumentImportDescriptor.maximumBatchCount,
              OpenPEPIdentifier.isPatient(patientID),
              encounterID.map(OpenPEPIdentifier.isEncounter) ?? true,
              items.allSatisfy({ OpenPEPIdentifier.isAsset($0.identity.assetID) }),
              Set(items.map(\.identity.assetID)).count == items.count else {
            throw batchIssue(
                "document_import_batch.invalid_input",
                patientID,
                "A tentativa de importação contém destino, quantidade ou identificadores inválidos."
            )
        }
    }

    private nonisolated func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func failure(from error: Error, path: String) -> DocumentImportBatchFailure {
        if let issue = error as? VaultValidationIssue {
            return DocumentImportBatchFailure(rule: issue.rule, path: issue.path, message: issue.message)
        }
        if let issue = error as? DocumentImportBatchFailure { return issue }
        return DocumentImportBatchFailure(
            rule: "document_import_batch.failed",
            path: path,
            message: error.localizedDescription
        )
    }

    private nonisolated func batchIssue(
        _ rule: String,
        _ path: String,
        _ message: String
    ) -> DocumentImportBatchFailure {
        DocumentImportBatchFailure(rule: rule, path: path, message: message)
    }
}
