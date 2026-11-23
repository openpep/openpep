// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct RawAssetDocumentResolver {
    func resolve(
        patientID: String,
        assetID: String,
        in vaultURL: URL
    ) throws -> RawAssetSummary {
        guard OpenPEPIdentifier.isPatient(patientID) else {
            throw VaultValidationIssue(
                rule: "document_preview.invalid_patient_id",
                path: patientID,
                message: "O paciente selecionado não possui um identificador seguro."
            )
        }
        guard OpenPEPIdentifier.isAsset(assetID) else {
            throw VaultValidationIssue(
                rule: "document_preview.invalid_asset_id",
                path: assetID,
                message: "O documento selecionado não possui um identificador seguro."
            )
        }

        let refreshed = try VaultReader().open(vaultURL)
        guard let patient = refreshed.patients.first(where: { $0.patientID == patientID }),
              let asset = patient.rawAssets.first(where: { $0.assetID == assetID }) else {
            throw VaultValidationIssue(
                rule: "document_preview.not_found",
                path: assetID,
                message: "O documento não foi encontrado no paciente selecionado após reler o vault."
            )
        }
        return asset
    }

    func resolvePreview(
        patientID: String,
        assetID: String,
        in vaultURL: URL
    ) throws -> URL {
        let asset = try resolve(patientID: patientID, assetID: assetID, in: vaultURL)
        let supported: Set<String> = ["application/pdf", "image/png", "image/jpeg", "text/plain"]
        guard supported.contains(asset.mediaType),
              asset.fileExtension == asset.originalURL.pathExtension.lowercased() else {
            throw VaultValidationIssue(
                rule: "document_preview.unsupported_type",
                path: asset.assetID,
                message: "O Quick Look aceita PDF, PNG, JPEG e texto importados e verificados."
            )
        }
        return asset.originalURL
    }
}
