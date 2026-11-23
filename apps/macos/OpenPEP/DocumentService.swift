// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct DocumentImportDescriptor: Equatable, Sendable {
    static let maximumBytes = 25 * 1_024 * 1_024
    static let maximumBatchCount = 20

    let mediaType: String
    let fileExtension: String
    var inspectionResult: String { mediaType == "application/octet-stream" ? "opaque_file" : "allowed_type_and_signature" }

    static func inspect(data: Data, sourceURL: URL) throws -> DocumentImportDescriptor {
        guard data.count <= maximumBytes else {
            throw documentIssue(
                "document_import.size",
                sourceURL.lastPathComponent,
                "O arquivo deve ter até 25 MiB."
            )
        }
        let ext = sourceURL.pathExtension.lowercased()
        switch ext {
        case "pdf" where data.starts(with: Data("%PDF-".utf8)):
            return DocumentImportDescriptor(mediaType: "application/pdf", fileExtension: ext)
        case "png" where data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])):
            return DocumentImportDescriptor(mediaType: "image/png", fileExtension: ext)
        case "jpg" where data.count >= 3 && data.prefix(3) == Data([0xff, 0xd8, 0xff]),
             "jpeg" where data.count >= 3 && data.prefix(3) == Data([0xff, 0xd8, 0xff]):
            return DocumentImportDescriptor(mediaType: "image/jpeg", fileExtension: ext)
        case "txt" where !data.isEmpty && String(data: data, encoding: .utf8) != nil && !data.contains(0):
            return DocumentImportDescriptor(mediaType: "text/plain", fileExtension: ext)
        default:
            let safeExtension = ext.range(of: "^[a-z0-9]{1,32}$", options: .regularExpression) != nil ? ext : "bin"
            return DocumentImportDescriptor(mediaType: "application/octet-stream", fileExtension: safeExtension)
        }
    }
}

enum GeneralDocumentImportStep: Equatable, Sendable {
    case temporaryFilesWritten
    case originalPublished
}

struct GeneralDocumentImporter {
    typealias FaultInjector = (GeneralDocumentImportStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func importDocument(
        from sourceURL: URL,
        into patient: PatientSummary,
        encounterID: String?,
        deviceID: String,
        identity: RawAssetCreationIdentity,
        importedAt: Date
    ) throws -> RawAssetImportResult {
        guard OpenPEPIdentifier.isPatient(patient.patientID),
              OpenPEPIdentifier.isAsset(identity.assetID) else {
            throw documentIssue("document_import.invalid_id", identity.assetID, "O identificador de destino não é seguro.")
        }
        if let encounterID {
            guard OpenPEPIdentifier.isEncounter(encounterID),
                  patient.encounters.contains(where: { $0.metadata.encounterID == encounterID }) else {
                throw documentIssue(
                    "document_import.encounter_binding",
                    encounterID,
                    "A consulta escolhida não pertence ao paciente."
                )
            }
        }

        let rawURL = patient.url.appending(path: "raw", directoryHint: .isDirectory)
        var outcome: Result<RawAssetImportResult, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: [],
            writingItemAt: rawURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedSource, coordinatedRaw in
            do {
                outcome = .success(try importUncoordinated(
                    from: coordinatedSource,
                    into: coordinatedRaw,
                    patientID: patient.patientID,
                    encounterID: encounterID,
                    deviceID: deviceID,
                    identity: identity,
                    importedAt: importedAt
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw documentIssue("filesystem.coordination", rawURL.path, "A importação coordenada não foi concluída.")
        }
        let saved = try outcome.get()
        // Linked draft attachments become sources only when the encounter is finalized.
        if encounterID == nil || patient.encounters.contains(where: {
            $0.metadata.encounterID == encounterID && $0.finalizationStatus != .draft
        }) {
            PatientClinicalChange.post(for: patient)
        }
        return saved
    }

    private func importUncoordinated(
        from sourceURL: URL,
        into rawURL: URL,
        patientID: String,
        encounterID: String?,
        deviceID: String,
        identity: RawAssetCreationIdentity,
        importedAt: Date
    ) throws -> RawAssetImportResult {
        let rawValues = try rawURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rawValues.isDirectory == true, rawValues.isSymbolicLink != true else {
            throw documentIssue("filesystem.directory", rawURL.path, "raw deve ser um diretório sem link simbólico.")
        }
        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let fileSize = sourceValues.fileSize,
              fileSize >= 0,
              fileSize <= DocumentImportDescriptor.maximumBytes else {
            throw documentIssue(
                "document_import.source",
                sourceURL.lastPathComponent,
                "Escolha um arquivo regular de até 25 MiB, sem link simbólico."
            )
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let descriptor = try DocumentImportDescriptor.inspect(data: data, sourceURL: sourceURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let components = utcComponents(importedAt)
        let yearURL = rawURL.appending(path: components.year, directoryHint: .isDirectory)
        let monthURL = yearURL.appending(path: components.month, directoryHint: .isDirectory)
        let originalName = "\(identity.assetID).\(descriptor.fileExtension)"
        let sidecarName = "\(identity.assetID).meta.md"
        let originalURL = monthURL.appending(path: originalName)
        let sidecarURL = monthURL.appending(path: sidecarName)
        guard !fileManager.fileExists(atPath: originalURL.path),
              !fileManager.fileExists(atPath: sidecarURL.path) else {
            throw documentIssue("raw_asset.destination_exists", identity.assetID, "O arquivo de destino já existe.")
        }

        let temporary = rawURL.appending(
            path: ".openpep-document-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let temporaryOriginal = temporary.appending(path: originalName)
        let temporarySidecar = temporary.appending(path: sidecarName)
        var publicationVerified = false
        defer {
            if !publicationVerified, fileManager.fileExists(atPath: sidecarURL.path) {
                try? fileManager.removeItem(at: sidecarURL)
            }
            if !publicationVerified, fileManager.fileExists(atPath: originalURL.path) {
                try? fileManager.removeItem(at: originalURL)
            }
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        try data.write(to: temporaryOriginal, options: [.withoutOverwriting])
        let sidecarData = Data(sidecarText(
            assetID: identity.assetID,
            patientID: patientID,
            encounterID: encounterID,
            deviceID: deviceID,
            descriptor: descriptor,
            originalName: sourceURL.lastPathComponent,
            sizeBytes: data.count,
            sha256: digest,
            importedAt: importedAt
        ).utf8)
        try sidecarData.write(to: temporarySidecar, options: [.withoutOverwriting])
        _ = try VaultManifestValidator.validateRawAssetSidecar(data: sidecarData)
        try requireDigest(temporaryOriginal, digest)
        try faultInjector?(.temporaryFilesWritten)

        try requireDirectory(yearURL)
        try requireDirectory(monthURL)
        guard !fileManager.fileExists(atPath: originalURL.path),
              !fileManager.fileExists(atPath: sidecarURL.path) else {
            throw documentIssue("raw_asset.destination_exists", identity.assetID, "O arquivo de destino já existe.")
        }
        try fileManager.moveItem(at: temporaryOriginal, to: originalURL)
        try faultInjector?(.originalPublished)
        try fileManager.moveItem(at: temporarySidecar, to: sidecarURL)

        try requireDigest(originalURL, digest)
        _ = try VaultManifestValidator.validateRawAssetSidecar(
            data: Data(contentsOf: sidecarURL),
            source: sidecarURL.path
        )
        publicationVerified = true
        return RawAssetImportResult(
            assetID: identity.assetID,
            originalURL: originalURL,
            sidecarURL: sidecarURL,
            sha256: digest
        )
    }

    private func sidecarText(
        assetID: String,
        patientID: String,
        encounterID: String?,
        deviceID: String,
        descriptor: DocumentImportDescriptor,
        originalName: String,
        sizeBytes: Int,
        sha256: String,
        importedAt: Date
    ) -> String {
        """
        ---
        schema: openpep/raw-asset@1
        asset_id: \(assetID)
        patient_id: \(patientID)
        encounter_id: \(encounterID.map(documentYAMLQuoted) ?? "null")
        media_type: \(descriptor.mediaType)
        file_extension: \(descriptor.mediaType == "application/octet-stream" ? documentYAMLQuoted(descriptor.fileExtension) : descriptor.fileExtension)
        original_name: \(documentYAMLQuoted(originalName.precomposedStringWithCanonicalMapping))
        size_bytes: \(sizeBytes)
        sha256: \(sha256)
        source: file_import
        actor_id: null
        device_id: \(deviceID)
        imported_at: \(documentYAMLQuoted(utcTimestamp(importedAt)))
        quarantine_state: not_scanned
        inspection_result: \(descriptor.inspectionResult)
        ---
        """ + "\n"
    }

    private func requireDigest(_ url: URL, _ expected: String) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw documentIssue("raw_asset.hash_mismatch", url.lastPathComponent, "O SHA-256 diverge do sidecar.")
        }
    }

    private func requireDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw documentIssue(
                "filesystem.directory",
                url.path,
                "O diretório de destino não pode ser substituído por um link simbólico."
            )
        }
    }
}

private func utcComponents(_ date: Date) -> (year: String, month: String) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let value = calendar.dateComponents([.year, .month], from: date)
    return (String(format: "%04d", value.year!), String(format: "%02d", value.month!))
}

private func utcTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func documentYAMLQuoted(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func documentIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
