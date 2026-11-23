// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct StandaloneDocumentView: View {
    let patientName: String
    var patient: PatientSummary? = nil
    var initialDocumentSection: ConsultationTextSection = .guidance
    let onArchive: (PreparedClinicalDocument) throws -> URL
    let onClose: () -> Void
    var vaultAuthorizationURL: URL? = nil
    @State private var bodyText = ""
    @State private var prepared: PreparedClinicalDocument?
    @State private var lastPreparation: PreparedClinicalDocument?
    @State private var confirmsClose = false

    init(patientName: String, patient: PatientSummary? = nil, initialBodyText: String = "",
         initialDocumentSection: ConsultationTextSection = .guidance,
         onArchive: @escaping (PreparedClinicalDocument) throws -> URL, onClose: @escaping () -> Void,
         vaultAuthorizationURL: URL? = nil) {
        self.patientName = patientName; self.patient = patient
        self.initialDocumentSection = initialDocumentSection
        self.onArchive = onArchive; self.onClose = onClose
        self.vaultAuthorizationURL = vaultAuthorizationURL
        _bodyText = State(initialValue: initialBodyText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Documentos").font(.title2)
                    Text(patientName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar") {
                    if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onClose() }
                    else { confirmsClose = true }
                }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                ConsultationFieldsEditor(bodyText: $bodyText, onPrepare: { title, text in
                    let document: PreparedClinicalDocument
                    if let cached = lastPreparation,
                       cached.title == title,
                       cached.sourceText == text,
                       cached.doctorIdentity == DoctorProfileStore.load().documentIdentity {
                        document = cached
                    } else {
                        let now = Date()
                        let data = try ClinicalDocumentPDF.make(
                            title: title,
                            patientName: patientName,
                            professional: DocumentProfessionalSettings.signature,
                            body: text,
                            doctorIdentity: DoctorProfileStore.load().documentIdentity,
                            date: now
                        )
                        document = try PreparedClinicalDocument(
                            title: title,
                            data: data,
                            sourceText: text,
                            professional: DocumentProfessionalSettings.signature,
                            doctorIdentity: DoctorProfileStore.load().documentIdentity,
                            createdAt: now
                        )
                        lastPreparation = document
                    }
                    _ = try onArchive(document)
                    prepared = document
                }, includesConsultation: false, patientName: patientName,
                   initialDocumentSection: initialDocumentSection,
                   previousPatient: patient, onDelivered: onClose,
                   onApprove: { documents in
                       let current = try ConsultationDocumentPreview.make(bodyText: bodyText, patientName: patientName,
                           professional: DocumentProfessionalSettings.signature, doctorIdentity: DoctorProfileStore.load().documentIdentity)
                       guard DocumentReviewSelection.matches(documents, current: current) else { throw ConsultationFieldsError.ambiguous }
                       return try documents.map { try onArchive($0.prepared) }
                   }, onFinish: onClose, cockpitAuthorizationURL: vaultAuthorizationURL, onCockpitArchive: onArchive)
                .padding(.vertical, 4)
            }
        }.padding(24).frame(minWidth: 560, idealWidth: 900, minHeight: 540, idealHeight: 740)
        .interactiveDismissDisabled(!bodyText.isEmpty)
        .sheet(item: $prepared) { document in
            PreparedDocumentView(document: document, isArchived: true, onClose: { prepared = nil })
        }
        .confirmationDialog("Fechar a redação? Documentos já guardados permanecem no prontuário; textos não guardados serão descartados.", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("Fechar redação", role: .destructive, action: onClose)
            Button("Continuar editando", role: .cancel) {}
        }
    }
}
