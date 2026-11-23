// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Yams

/// A human-readable source snapshot stored as text/plain inside the existing raw envelope.
struct IndependentClinicalDocument {
    struct Header: Codable, Equatable {
        let document_format: String
        let document_id: String
        let patient_id: String
        let encounter_id: String?
        let title: String
        let created_at: String
        let pdf_asset_id: String
        let pdf_sha256: String
    }
    let header: Header
    let body: String

    var text: String {
        get throws {
            var yaml = try YAMLEncoder().encode(header)
            if header.encounter_id == nil { yaml += "encounter_id: null\n" }
            return ("---\n" + yaml + "---\n\n" + body)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .precomposedStringWithCanonicalMapping
        }
    }
    static func read(_ text: String) throws -> Self {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            throw ConsultationFieldsError.ambiguous
        }
        let yaml = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        let header = try YAMLDecoder().decode(Header.self, from: yaml)
        guard header.document_format == "openpep-document-snapshot-v1",
              OpenPEPIdentifier.isPatient(header.patient_id), OpenPEPIdentifier.isAsset(header.pdf_asset_id),
              header.encounter_id.map(OpenPEPIdentifier.isEncounter) ?? true,
              UUID(uuidString: header.document_id) != nil,
              header.pdf_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: header.created_at) != nil else { throw ConsultationFieldsError.ambiguous }
        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return Self(header: header, body: body)
    }
}

enum ClinicalDocumentArchiveStep: Equatable, Sendable {
    case pdfStored
}

struct ClinicalDocumentArchiver {
    typealias FaultInjector = (ClinicalDocumentArchiveStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    /// A retry reuses either asset only when its bytes and binding match this exact preparation.
    func archive(_ document: PreparedClinicalDocument, patient: PatientSummary, encounterID: String?, deviceID: String,
                 expectedVaultID: String, now: Date = Date()) throws -> (pdf: RawAssetImportResult, source: RawAssetImportResult) {
        guard !document.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConsultationFieldsError.emptyDocument
        }
        guard document.pdfIdentity != document.sourceIdentity,
              OpenPEPIdentifier.isAsset(document.pdfIdentity.assetID),
              OpenPEPIdentifier.isAsset(document.sourceIdentity.assetID) else {
            throw archiveIssue(
                "document_archive.identity",
                document.id.uuidString.lowercased(),
                "A preparação deve reservar identificadores distintos e válidos para o PDF e o texto."
            )
        }
        let expectedEncounter: EncounterSummary?
        if let encounterID {
            guard OpenPEPIdentifier.isEncounter(encounterID),
                  let encounter = patient.encounters.first(where: { $0.metadata.encounterID == encounterID }) else {
                throw archiveIssue(
                    "document_archive.encounter_binding",
                    encounterID,
                    "A consulta da preparação não está disponível neste paciente."
                )
            }
            expectedEncounter = encounter
        } else {
            expectedEncounter = nil
        }
        let vaultURL = try validatedVaultURL(for: patient)
        _ = try currentPatient(
            in: vaultURL,
            expected: patient,
            encounterID: encounterID,
            expectedEncounter: expectedEncounter,
            deviceID: deviceID,
            expectedVaultID: expectedVaultID
        )

        let temporary = fileManager.temporaryDirectory.appending(path: "openpep-document-" + UUID().uuidString)
        try fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporary) }
        let safeTitle = String(document.title.map { "/:\n\r".contains($0) ? "-" : $0 }.prefix(100))
        let pdfFile = temporary.appending(path: safeTitle + ".pdf")
        try document.data.write(to: pdfFile, options: .withoutOverwriting)
        let pdfHash = sha256(document.data)
        let source = IndependentClinicalDocument(header: .init(
            document_format: "openpep-document-snapshot-v1",
            document_id: document.id.uuidString.lowercased(),
            patient_id: patient.patientID,
            encounter_id: encounterID,
            title: document.title,
            created_at: ISO8601DateFormatter().string(from: document.createdAt),
            pdf_asset_id: document.pdfIdentity.assetID,
            pdf_sha256: pdfHash
        ), body: document.sourceText)
        let sourceText = try source.text
        _ = try IndependentClinicalDocument.read(sourceText)
        let sourceData = Data(sourceText.utf8)
        let sourceFile = temporary.appending(path: safeTitle + " - texto.txt")
        try sourceData.write(to: sourceFile, options: .withoutOverwriting)

        let pdf = try store(
            sourceURL: pdfFile,
            expectedData: document.data,
            identity: document.pdfIdentity,
            patient: patient,
            encounterID: encounterID,
            expectedEncounter: expectedEncounter,
            deviceID: deviceID,
            expectedVaultID: expectedVaultID,
            importedAt: now,
            vaultURL: vaultURL
        )
        do {
            try faultInjector?(.pdfStored)
            let importedSource = try store(
                sourceURL: sourceFile,
                expectedData: sourceData,
                identity: document.sourceIdentity,
                patient: patient,
                encounterID: encounterID,
                expectedEncounter: expectedEncounter,
                deviceID: deviceID,
                expectedVaultID: expectedVaultID,
                importedAt: now,
                vaultURL: vaultURL
            )
            let reopened = try currentPatient(
                in: vaultURL,
                expected: patient,
                encounterID: encounterID,
                expectedEncounter: expectedEncounter,
                deviceID: deviceID,
                expectedVaultID: expectedVaultID
            )
            let reopenedPDF = try existingResult(
                identity: document.pdfIdentity,
                expectedData: document.data,
                originalName: pdfFile.lastPathComponent,
                mediaType: "application/pdf",
                fileExtension: "pdf",
                patient: reopened,
                encounterID: encounterID,
                deviceID: deviceID
            )
            let reopenedSource = try existingResult(
                identity: document.sourceIdentity,
                expectedData: sourceData,
                originalName: sourceFile.lastPathComponent,
                mediaType: "text/plain",
                fileExtension: "txt",
                patient: reopened,
                encounterID: encounterID,
                deviceID: deviceID
            )
            guard reopenedPDF == pdf, reopenedSource == importedSource else {
                throw archiveIssue(
                    "document_archive.reopen_mismatch",
                    document.id.uuidString.lowercased(),
                    "Os documentos reabertos divergem da preparação guardada."
                )
            }
            return (reopenedPDF, reopenedSource)
        } catch {
            throw VaultValidationIssue(
                rule: "document.source_publication",
                path: pdf.assetID,
                message: "O PDF foi guardado, mas não foi possível confirmar a guarda completa: \(error.localizedDescription). O texto continua no editor; clique em Preparar PDF novamente."
            )
        }
    }

    private func store(
        sourceURL: URL,
        expectedData: Data,
        identity: RawAssetCreationIdentity,
        patient: PatientSummary,
        encounterID: String?,
        expectedEncounter: EncounterSummary?,
        deviceID: String,
        expectedVaultID: String,
        importedAt: Date,
        vaultURL: URL
    ) throws -> RawAssetImportResult {
        let descriptor = try DocumentImportDescriptor.inspect(data: expectedData, sourceURL: sourceURL)
        var current = try currentPatient(
            in: vaultURL,
            expected: patient,
            encounterID: encounterID,
            expectedEncounter: expectedEncounter,
            deviceID: deviceID,
            expectedVaultID: expectedVaultID
        )
        if current.rawAssets.contains(where: { $0.assetID == identity.assetID }) {
            return try existingResult(
                identity: identity,
                expectedData: expectedData,
                originalName: sourceURL.lastPathComponent,
                mediaType: descriptor.mediaType,
                fileExtension: descriptor.fileExtension,
                patient: current,
                encounterID: encounterID,
                deviceID: deviceID
            )
        }
        do {
            _ = try GeneralDocumentImporter(fileManager: fileManager).importDocument(
                from: sourceURL,
                into: current,
                encounterID: encounterID,
                deviceID: deviceID,
                identity: identity,
                importedAt: importedAt
            )
        } catch {
            current = try currentPatient(
                in: vaultURL,
                expected: patient,
                encounterID: encounterID,
                expectedEncounter: expectedEncounter,
                deviceID: deviceID,
                expectedVaultID: expectedVaultID
            )
            guard current.rawAssets.contains(where: { $0.assetID == identity.assetID }) else { throw error }
        }
        current = try currentPatient(
            in: vaultURL,
            expected: patient,
            encounterID: encounterID,
            expectedEncounter: expectedEncounter,
            deviceID: deviceID,
            expectedVaultID: expectedVaultID
        )
        return try existingResult(
            identity: identity,
            expectedData: expectedData,
            originalName: sourceURL.lastPathComponent,
            mediaType: descriptor.mediaType,
            fileExtension: descriptor.fileExtension,
            patient: current,
            encounterID: encounterID,
            deviceID: deviceID
        )
    }

    private func currentPatient(
        in vaultURL: URL,
        expected patient: PatientSummary,
        encounterID: String?,
        expectedEncounter: EncounterSummary?,
        deviceID: String,
        expectedVaultID: String
    ) throws -> PatientSummary {
        let vault = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard vault.writingAllowed else {
            throw archiveIssue(
                "document_archive.read_only",
                vaultURL.path,
                "O prontuário está somente para leitura."
            )
        }
        guard vault.manifest.vaultID == expectedVaultID,
              vault.manifest.deviceID == deviceID else {
            throw archiveIssue(
                "document_archive.vault_changed",
                vaultURL.path,
                "A identidade do prontuário mudou. Reabra antes de guardar."
            )
        }
        guard let current = vault.patients.first(where: { $0.patientID == patient.patientID }),
              current.url.standardizedFileURL == patient.url.standardizedFileURL,
              current.record == patient.record else {
            throw archiveIssue(
                "document_archive.patient_changed",
                patient.patientID,
                "O prontuário ou o cadastro do paciente mudou. Reabra antes de guardar."
            )
        }
        if let encounterID {
            guard let expectedEncounter,
                  current.encounters.first(where: { $0.metadata.encounterID == encounterID }) == expectedEncounter else {
                throw archiveIssue(
                    "document_archive.encounter_changed",
                    encounterID,
                    "A consulta mudou ou não está mais disponível. Reabra antes de guardar."
                )
            }
        }
        return current
    }

    private func existingResult(
        identity: RawAssetCreationIdentity,
        expectedData: Data,
        originalName: String,
        mediaType: String,
        fileExtension: String,
        patient: PatientSummary,
        encounterID: String?,
        deviceID: String
    ) throws -> RawAssetImportResult {
        guard let asset = patient.rawAssets.first(where: { $0.assetID == identity.assetID }) else {
            throw archiveIssue(
                "document_archive.asset_missing",
                identity.assetID,
                "O documento guardado não foi localizado ao reabrir o prontuário."
            )
        }
        let expectedHash = sha256(expectedData)
        let sidecarURL = asset.originalURL.deletingLastPathComponent().appending(path: "\(identity.assetID).meta.md")
        let sidecar = try VaultManifestValidator.validateRawAssetSidecar(
            data: Data(contentsOf: sidecarURL),
            source: sidecarURL.path
        )
        let storedData = try Data(contentsOf: asset.originalURL)
        guard storedData == expectedData,
              asset.encounterID == encounterID,
              asset.originalName == originalName,
              asset.mediaType == mediaType,
              asset.fileExtension == fileExtension,
              asset.sizeBytes == expectedData.count,
              asset.sha256 == expectedHash,
              sidecar.assetID == identity.assetID,
              sidecar.patientID == patient.patientID,
              sidecar.encounterID == encounterID,
              sidecar.originalName == originalName,
              sidecar.mediaType == mediaType,
              sidecar.fileExtension == fileExtension,
              sidecar.sizeBytes == expectedData.count,
              sidecar.sha256 == expectedHash,
              sidecar.deviceID == deviceID else {
            throw archiveIssue(
                "document_archive.identity_conflict",
                identity.assetID,
                "O identificador da preparação já pertence a outro conteúdo ou vínculo."
            )
        }
        return RawAssetImportResult(
            assetID: identity.assetID,
            originalURL: asset.originalURL,
            sidecarURL: sidecarURL,
            sha256: expectedHash
        )
    }

    private func validatedVaultURL(for patient: PatientSummary) throws -> URL {
        let patientsURL = patient.url.deletingLastPathComponent()
        guard patient.url.lastPathComponent == patient.patientID,
              patientsURL.lastPathComponent == "patients" else {
            throw archiveIssue(
                "document_archive.patient_path",
                patient.url.path,
                "O diretório do paciente não pertence ao layout esperado do prontuário."
            )
        }
        return patientsURL.deletingLastPathComponent()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func archiveIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
        VaultValidationIssue(rule: rule, path: path, message: message)
    }
}
