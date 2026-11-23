// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct EncounterTranscriptInput: Equatable, Sendable {
    let text: String
    let audioSHA256: String
    let localeIdentifier: String
    let operationID: String
}

enum EncounterTranscriptSaveStep: Equatable, Sendable {
    case imported
}

struct EncounterTranscriptStore {
    typealias FaultInjector = (EncounterTranscriptSaveStep) throws -> Void

    private let fileManager: FileManager
    private let importer: GeneralDocumentImporter
    private let faultInjector: FaultInjector?

    init(
        fileManager: FileManager = .default,
        importer: GeneralDocumentImporter = GeneralDocumentImporter(),
        faultInjector: FaultInjector? = nil
    ) {
        self.fileManager = fileManager
        self.importer = importer
        self.faultInjector = faultInjector
    }

    func saveToCurrentEncounter(
        in vaultURL: URL,
        vaultID: String,
        patientID: String,
        encounterID: String,
        input: EncounterTranscriptInput,
        identity: RawAssetCreationIdentity,
        deviceID: String,
        savedAt: Date = Date()
    ) throws -> RawAssetImportResult {
        let currentVault = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard currentVault.writingAllowed,
              currentVault.manifest.vaultID == vaultID,
              let currentPatient = currentVault.patients.first(where: { $0.patientID == patientID }),
              let currentEncounter = currentPatient.encounters.first(where: {
                  $0.metadata.encounterID == encounterID
              }),
              currentEncounter.metadata.patientID == patientID,
              currentEncounter.metadata.trashedAt == nil,
              currentEncounter.finalizationStatus == .draft else {
            throw transcriptIssue(
                "transcript.encounter_changed",
                encounterID,
                "O atendimento mudou, foi finalizado ou descartado. Reabra antes de salvar a transcrição."
            )
        }
        return try save(
            in: currentVault,
            patient: currentPatient,
            encounter: currentEncounter,
            input: input,
            identity: identity,
            deviceID: deviceID,
            savedAt: savedAt
        )
    }

    func save(
        in vault: VaultSummary,
        patient: PatientSummary,
        encounter: EncounterSummary,
        input: EncounterTranscriptInput,
        identity: RawAssetCreationIdentity,
        deviceID: String,
        savedAt: Date = Date()
    ) throws -> RawAssetImportResult {
        try validateBindings(
            vault: vault,
            patient: patient,
            encounter: encounter,
            input: input,
            identity: identity,
            deviceID: deviceID
        )
        let transcriptData = try encodedTranscript(
            input,
            patientID: patient.patientID,
            encounterID: encounter.metadata.encounterID
        )

        let currentBeforeImport = try currentBinding(
            vaultURL: vault.url,
            patient: patient,
            encounter: encounter
        )
        if let existing = try existingResult(
            identity: identity,
            expectedData: transcriptData,
            patient: currentBeforeImport.patient,
            encounterID: encounter.metadata.encounterID,
            logicalName: logicalName(input.operationID)
        ) {
            return existing
        }

        let temporaryDirectory = fileManager.temporaryDirectory.appending(
            path: "openpep-transcript-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let sourceURL = temporaryDirectory.appending(
            path: logicalName(input.operationID),
            directoryHint: .notDirectory
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try transcriptData.write(to: sourceURL, options: [.withoutOverwriting])

        let result = try importer.importDocument(
            from: sourceURL,
            into: currentBeforeImport.patient,
            encounterID: encounter.metadata.encounterID,
            deviceID: deviceID,
            identity: identity,
            importedAt: savedAt
        )
        try faultInjector?(.imported)

        do {
            _ = try currentBinding(vaultURL: vault.url, patient: patient, encounter: encounter)
        } catch {
            // The imported text remains linked to the correct encounter. Removing it
            // here could erase a concurrent user's valid publication.
            throw transcriptIssue(
                "transcript.encounter_changed_after_import",
                encounter.metadata.encounterID,
                "O atendimento mudou durante a gravação. A transcrição vinculada foi preservada; reabra o prontuário antes de continuar."
            )
        }
        return result
    }

    private func currentBinding(
        vaultURL: URL,
        patient: PatientSummary,
        encounter: EncounterSummary
    ) throws -> (patient: PatientSummary, encounter: EncounterSummary) {
        let currentVault = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard currentVault.writingAllowed,
              let currentPatient = currentVault.patients.first(where: {
                  $0.patientID == patient.patientID && $0.url.standardizedFileURL == patient.url.standardizedFileURL
              }),
              let currentEncounter = currentPatient.encounters.first(where: {
                  $0.metadata.encounterID == encounter.metadata.encounterID
              }),
              currentEncounter.url.standardizedFileURL == encounter.url.standardizedFileURL,
              currentEncounter.draft.url.standardizedFileURL == encounter.draft.url.standardizedFileURL,
              currentEncounter.metadata == encounter.metadata,
              currentEncounter.metadata.trashedAt == nil,
              currentEncounter.finalizationStatus == .draft,
              currentEncounter.draft.persistedData == encounter.draft.persistedData else {
            throw transcriptIssue(
                "transcript.encounter_changed",
                encounter.metadata.encounterID,
                "O atendimento mudou, foi finalizado ou descartado. Reabra antes de salvar a transcrição."
            )
        }
        return (currentPatient, currentEncounter)
    }

    private func existingResult(
        identity: RawAssetCreationIdentity,
        expectedData: Data,
        patient: PatientSummary,
        encounterID: String,
        logicalName: String
    ) throws -> RawAssetImportResult? {
        let matching = (patient.rawAssets + patient.trashedRawAssets).filter { $0.assetID == identity.assetID }
        guard !matching.isEmpty else { return nil }
        guard matching.count == 1, let asset = matching.first,
              asset.encounterID == encounterID,
              asset.mediaType == "text/plain",
              asset.fileExtension == "txt",
              asset.originalName == logicalName,
              asset.sizeBytes == expectedData.count,
              asset.sha256 == digest(expectedData),
              try dataIfSafe(at: asset.originalURL) == expectedData else {
            throw transcriptIssue(
                "transcript.identity_conflict",
                identity.assetID,
                "A identidade desta operação já está vinculada a outro conteúdo."
            )
        }
        let sidecarURL = asset.originalURL.deletingLastPathComponent()
            .appending(path: "\(identity.assetID).meta.md", directoryHint: .notDirectory)
        return RawAssetImportResult(
            assetID: identity.assetID,
            originalURL: asset.originalURL,
            sidecarURL: sidecarURL,
            sha256: asset.sha256
        )
    }

    private func validateBindings(
        vault: VaultSummary,
        patient: PatientSummary,
        encounter: EncounterSummary,
        input: EncounterTranscriptInput,
        identity: RawAssetCreationIdentity,
        deviceID: String
    ) throws {
        let expectedPatientURL = vault.url.appending(path: "patients/\(patient.patientID)", directoryHint: .isDirectory)
        guard vault.writingAllowed,
              OpenPEPIdentifier.isPatient(patient.patientID),
              OpenPEPIdentifier.isEncounter(encounter.metadata.encounterID),
              OpenPEPIdentifier.isAsset(identity.assetID),
              patient.url.standardizedFileURL == expectedPatientURL.standardizedFileURL,
              encounter.metadata.patientID == patient.patientID,
              encounter.metadata.trashedAt == nil,
              encounter.finalizationStatus == .draft,
              isSafeIdentifier(deviceID, maximum: 200),
              isCanonicalOperationID(input.operationID),
              isSafeIdentifier(input.localeIdentifier, maximum: 100),
              input.audioSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw transcriptIssue(
                "transcript.invalid_input",
                encounter.metadata.encounterID,
                "Os vínculos ou metadados da transcrição são inválidos."
            )
        }
    }

    private func encodedTranscript(
        _ input: EncounterTranscriptInput,
        patientID: String,
        encounterID: String
    ) throws -> Data {
        let normalized = input.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }),
              normalized.utf8.count <= 5 * 1_024 * 1_024 else {
            throw transcriptIssue(
                "transcript.invalid_text",
                encounterID,
                "A transcrição deve conter texto UTF-8 de até 5 MiB."
            )
        }
        let text = """
        Transcrição local do atendimento

        Motor: SpeechTranscriber
        Localidade: \(input.localeIdentifier)
        SHA-256 do áudio: \(input.audioSHA256)
        Operação: \(input.operationID)
        Paciente: \(patientID)
        Atendimento: \(encounterID)

        ---

        \(normalized)
        """ + "\n"
        return Data(text.utf8)
    }

    private func logicalName(_ operationID: String) -> String {
        "transcricao-\(operationID).txt"
    }

    private func dataIfSafe(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw transcriptIssue("filesystem.regular_file", url.path, "A transcrição persistida não é um arquivo regular seguro.")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isCanonicalOperationID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private func isSafeIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
            && value == value.precomposedStringWithCanonicalMapping
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

private func transcriptIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
