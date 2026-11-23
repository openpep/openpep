// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// All operations reread the selected patient's vault; no path supplied by the timeline is trusted.
enum PatientDocumentReuse {
    static func resend(entry: PatientHistoryEntry, context: PatientHistoryContext) throws -> (patient: PatientSummary, file: URL) {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(context.vaultURL)
        guard let patient = vault.patients.first(where: { $0.patientID == context.patientID }), !patient.isArchived,
              let asset = patient.rawAssets.first(where: { $0.assetID == entry.assetID }) else { throw ConsultationFieldsError.ambiguous }
        let data = try PatientHistoryReader.verifiedData(asset)
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenPEP-Resend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let name = String(asset.originalName.map { "/:\n\r".contains($0) ? "-" : $0 }.prefix(180))
        let file = directory.appending(path: name.isEmpty ? "Documento" : name)
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (patient, file)
    }

    static func reissue(entry: PatientHistoryEntry, context: PatientHistoryContext, date: Date = Date()) throws -> (patient: PatientSummary, document: ConsultationDocumentPreview) {
        guard PatientHistoryPresentation.canReissue(entry) else { throw ConsultationFieldsError.ambiguous }
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(context.vaultURL)
        guard vault.writingAllowed,
              let patient = vault.patients.first(where: { $0.patientID == context.patientID }), !patient.isArchived,
              let pdf = patient.rawAssets.first(where: { $0.assetID == entry.assetID }), pdf.mediaType == "application/pdf" else { throw ConsultationFieldsError.ambiguous }
        _ = try PatientHistoryReader.verifiedData(pdf)
        for asset in patient.rawAssets where asset.mediaType == "text/plain" && asset.encounterID == pdf.encounterID {
            guard let text = try? PatientHistoryReader.documentText(asset),
                  let source = try? IndependentClinicalDocument.read(text),
                  source.header.patient_id == patient.patientID, source.header.encounter_id == pdf.encounterID,
                  source.header.pdf_asset_id == pdf.assetID, source.header.pdf_sha256 == pdf.sha256 else { continue }
            guard !PatientSearch.normalize(source.header.title).contains("atestado") else { throw ConsultationFieldsError.ambiguous }
            let body = try LinearConsultationPage(body: "").replacing(.custom, text: source.body, title: source.header.title)
            guard let document = try ConsultationDocumentPreview.make(bodyText: body,
                patientName: patient.record?.fullName ?? patient.displayName,
                professional: DocumentProfessionalSettings.signature, doctorIdentity: DoctorProfileStore.load().documentIdentity, date: date).first else { throw ConsultationFieldsError.emptyDocument }
            return (patient, document)
        }
        throw VaultValidationIssue(rule: "document_reissue.source", path: entry.id, message: "A fonte editável deste documento não está disponível. Você pode reenviar o original.")
    }
}
