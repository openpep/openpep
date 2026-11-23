// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import PDFKit
import Testing
@testable import OpenPEP

struct DocumentWorkflowTests {
    let csv = #"""
    Publicada em 01/09/2026;;;;;;;
    SUBSTÂNCIA;PRODUTO;APRESENTAÇÃO;LABORATÓRIO;CÓDIGO GGREM;REGISTRO;CLASSE TERAPÊUTICA;ATC
    SUBSTÂNCIA DE ENSAIO;PRODUTO FICTÍCIO;"10 MG; 20 COMPRIMIDOS";"LAB ""DE ENSAIO""";0001;0002;CLASSE LOCAL;
    """#

    @Test func catalogMetadataAndPrescriptionRoundTrip() throws {
        let catalog = try MedicationCatalog(csv: csv)
        let entry = try #require(catalog.search("ficticio comprimidos").first)
        #expect(entry.presentation == "10 MG; 20 COMPRIMIDOS")
        #expect(entry.laboratory == "LAB \"DE ENSAIO\"")
        #expect(entry.metadata.atc == nil)
        #expect(entry.metadata.therapeuticClassCMED == "CLASSE LOCAL")
        var prescription = PrescriptionPage(text: "")
        #expect(!prescription.compounded && !prescription.special && !prescription.legacy)
        prescription.medications = [.init(name: entry.prescriptionName, dosage: "Posologia de ensaio.\nSegundo parágrafo.", metadata: entry.metadata)]
        let restored = PrescriptionPage(text: prescription.text)
        #expect(restored.text == prescription.text)
        #expect(restored.medications.first?.metadata?.ggrem == "0001")
        #expect(restored.medications.first?.metadata?.atc == nil)
        #expect(restored.medications.first?.dosage == prescription.medications.first?.dosage)
        var incomplete = prescription
        incomplete.medications[0].dosage = ""
        let incompleteBody = try LinearConsultationPage(body: "").replacing(.medication, text: incomplete.text)
        #expect(throws: (any Error).self) {
            try ConsultationDocumentPreview.make(bodyText: incompleteBody, patientName: "Pessoa de Ensaio")
        }
        let pdf = try ClinicalDocumentPDF.make(title: "Receita", patientName: "Pessoa de Ensaio", professional: "", body: prescription.text)
        let pdfText = try #require(PDFDocument(data: pdf)?.string)
        #expect(pdfText.contains("PRODUTO FICTÍCIO"))
        #expect(pdfText.contains("Posologia de ensaio."))
        #expect(!pdfText.contains("openpep:cmed") && !pdfText.contains("0001"))
        var compounded = PrescriptionPage(text: "")
        compounded.special = true; compounded.compounded = true; compounded.freeText = "Fórmula de ensaio."
        #expect(PrescriptionPage(text: compounded.text).compounded)
        #expect(PrescriptionPage(text: compounded.text).special)
        #expect(PrescriptionPage(text: "Texto antigo\nsem estrutura").text == "Texto antigo\nsem estrutura")
    }

    @Test func separatePagesAndApprovalInvalidation() throws {
        let text = DocumentPages.joining(["Exame de ensaio A", "Exame de ensaio B", ""])
        let body = try LinearConsultationPage(body: "Nota interna").replacing(.exam, text: text)
        let restored = try #require(LinearConsultationPage(body: body).text(for: .exam))
        #expect(DocumentPages.split(restored).count == 3)
        let previews = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Pessoa de Ensaio")
        let preview = try #require(previews.first)
        let pdf = try #require(PDFDocument(data: preview.data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Exame de ensaio A") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Exame de ensaio B") == false)
        #expect(pdf.page(at: 1)?.string?.contains("Exame de ensaio B") == true)
        #expect(!((pdf.string ?? "").contains("page-break")))
        #expect(preview.prepared.data == preview.data)
        let same = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Pessoa de Ensaio")
        #expect(same.first?.fingerprint == preview.fingerprint)
        let edited = try LinearConsultationPage(body: body).replacing(.exam, text: text + " edição")
        #expect(try ConsultationDocumentPreview.make(bodyText: edited, patientName: "Pessoa de Ensaio").first?.fingerprint != preview.fingerprint)
        #expect(try ConsultationDocumentPreview.make(bodyText: body, patientName: "Outra Pessoa").first?.fingerprint != preview.fingerprint)
        var identity = DoctorProfileStore.load().documentIdentity
        let previous = DocumentReviewRecord.fingerprint(section: .exams, text: text, patientName: "A", identity: identity)
        identity.signatureText = "Outro médico de ensaio"
        #expect(DocumentReviewRecord.fingerprint(section: .exams, text: text, patientName: "A", identity: identity) != previous)
        #expect(MedicationCatalog.refreshIsDue(lastDownloaded: nil))
        #expect(!MedicationCatalog.refreshIsDue(lastDownloaded: Date()))
        #expect(MedicationCatalog.refreshIsDue(lastDownloaded: Date().addingTimeInterval(-31 * 86400)))
    }

    @Test func approvalRecordAndReviewedBytesSurviveReopenAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-review-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let encounterID = "enc_0198f5c4-0000-7000-8000-000000000001"
        let vault = try VaultCreator().create(in: root, identity: VaultCreationIdentity(
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
            deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: date)
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: PatientCreationIdentity(patientID: "pt_0198f5c2-0000-7000-8000-000000000001"),
            input: PatientRecordInput(fullName: "Pessoa de Ensaio", preferredName: nil, birthDate: nil,
                                      contacts: [], identifiers: [], alerts: []), createdAt: date)
        _ = try ClinicalDraftCreator().create(in: patient, identity: ClinicalDraftCreationIdentity(
            encounterID: encounterID, noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"), startedAt: date)
        let current = try VaultReader().open(vault.url)
        let currentPatient = try #require(current.patients.first)
        let body = try LinearConsultationPage(body: "Nota interna").replacing(.guidance, text: "Orientação de ensaio")
        let previews = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Pessoa de Ensaio")
        let preview = try #require(previews.first)
        let archived = try ClinicalDocumentArchiver().archive(preview.prepared, patient: currentPatient, encounterID: encounterID,
            deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID)
        #expect(try Data(contentsOf: archived.pdf.originalURL) == preview.data)
        let record = DocumentReviewRecord(fingerprints: [preview.section.rawValue: preview.fingerprint])
        try record.save(patient: currentPatient, encounterID: encounterID)
        #expect(try VaultReader().open(vault.url).writingAllowed)
        #expect(DocumentReviewRecord.read(patient: currentPatient, encounterID: encounterID).fingerprints == record.fingerprints)
        let backup = root.appending(path: "backup"), restoredURL = root.appending(path: "restored")
        _ = try VaultBackupService().create(from: vault.url, to: backup)
        _ = try VaultBackupService().restore(from: backup, to: restoredURL)
        let restoredVault = try VaultReader().open(restoredURL)
        let restoredPatient = try #require(restoredVault.patients.first)
        #expect(DocumentReviewRecord.read(patient: restoredPatient, encounterID: encounterID).fingerprints == record.fingerprints)
        let invalid = DocumentReviewRecord(fingerprints: ["guidance": "não é digest"])
        try JSONEncoder().encode(invalid).write(to: DocumentReviewRecord.url(patient: restoredPatient, encounterID: encounterID))
        #expect(throws: (any Error).self) {
            try DocumentReviewRecord.inspect(directory: restoredPatient.url.appending(path: "content/document-reviews"), encounterIDs: [encounterID])
        }
    }

    @Test func actualCMEDWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENPEP_CMED_TEST_FILE"] else { return }
        let catalog = try MedicationCatalog(csv: String(contentsOfFile: path, encoding: .utf8))
        #expect(catalog.entries.count > 10_000)
        #expect(catalog.entries.allSatisfy { !$0.metadata.ggrem.isEmpty && !$0.presentation.isEmpty })
    }
}

extension DocumentWorkflowTests {
    @Test func readablePrescriptionAndPerPageTitles() throws {
        let original = "(320,00+12,50) MG COM REV CT BL AL AL X 28"
        #expect(MedicationPresentation.readable(original) == "(320,00+12,50) mg comprimido revestido")
        #expect(MedicationPresentation.readable("10 MG COM LIB PROL CT BL X 30").contains("liberação prolongada"))
        #expect(MedicationPresentation.readable("10 MG/ML SOL INJ CT AMP 2 ML").contains("2 ML"))
        var simple = PrescriptionPage(text: "")
        simple.medications = [.init(name: "Medicamento de teste 10 mg", dosage: "Posologia de teste.")]
        var special = simple; special.special = true
        let data = try ClinicalDocumentPDF.make(title: "Receituário", patientName: "Pessoa de ensaio", professional: "",
            body: DocumentPages.joining([simple.text, special.text]))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.hasPrefix("Receituário\n") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Receituário Especial") == true)
        #expect(pdf.string?.contains("## Receita") == false)
        #expect(pdf.string?.contains("rascunho") == false)
    }

    @Test func hospitalFilterAndHistoryProvenance() throws {
        let table = "SUBSTÂNCIA;PRODUTO;APRESENTAÇÃO;LABORATÓRIO;CÓDIGO GGREM;RESTRIÇÃO HOSPITALAR\nSUB;Teste A;10 MG COM CT X 10;Lab;01;Não\nSUB;Teste B;10 MG COM CT X 10;Lab;02;Sim"
        let catalog = try MedicationCatalog(csv: table)
        #expect(catalog.search("Teste", includesHospital: false).map(\.name) == ["Teste A"])
        #expect(catalog.search("Teste", includesHospital: true).count == 2)
        let technical = PatientHistoryEntry(id: "asset_test", title: "openpep-progressive-summary-source-test.txt",
            timestamp: "2026-09-07T12:00:00Z", status: "", text: "Fonte de resumo progressivo aceita\nGeração: gen_test", source: "raw/test.txt", assetID: "asset_test", issue: nil)
        #expect(PatientHistoryPresentation.isTechnical(technical))
        let ordinary = PatientHistoryEntry(id: technical.id, title: technical.title, timestamp: technical.timestamp,
            status: "", text: "Relato escrito pelo paciente.", source: technical.source, assetID: technical.assetID, issue: nil)
        #expect(!PatientHistoryPresentation.isTechnical(ordinary))
        let body = try LinearConsultationPage(body: "Relato da consulta.").replacing(.guidance, text: "Documento separado.")
        let note = PatientHistoryEntry(id: "enc_test", title: "Consulta", timestamp: technical.timestamp,
            status: "", text: body, source: "note.md", assetID: nil, issue: nil)
        #expect(PatientHistoryPresentation.text(note) == "Relato da consulta.")
        #expect(note.text.contains("Documento separado."))
    }
}

extension DocumentWorkflowTests {
    @Test func selectionAndEmptyTemplates() throws {
        var body = try LinearConsultationPage(body: "Nota").replacing(.guidance, text: "Orientação")
        body = try LinearConsultationPage(body: body).replacing(.exam, text: "Exame")
        let docs = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Pessoa de ensaio")
        #expect(DocumentReviewSelection.matches([docs[1]], current: docs))
        #expect(!DocumentReviewSelection.matches([], current: docs))
        #expect(!DocumentReviewSelection.matches([docs[0], docs[0]], current: docs))
        let changed = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Outra pessoa")
        #expect(!DocumentReviewSelection.matches([changed[0]], current: docs))
        let subset = try #require(ConsultationDocumentReviewView.combinedPDF([docs[1]]))
        let pdf = try #require(PDFDocument(data: subset))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("Exame") == true)
        #expect(pdf.string?.contains("Orientação") == false)
        #expect(!ConsultationTextTemplate.requiresReplacement(currentText: " \n\t"))
        #expect(ConsultationTextTemplate.requiresReplacement(currentText: "Orientação"))
        var rx = PrescriptionPage(text: "")
        rx.medications = [.init(name: "Medicamento fictício", dosage: "")]
        let throughNote = try LinearConsultationPage(body: "").replacing(.medication, text: rx.text)
        let restored = PrescriptionPage(text: try #require(LinearConsultationPage(body: throughNote).text(for: .medication)))
        #expect(!restored.legacy)
        #expect(restored.medications.count == 1)
        #expect(restored.medications[0].dosage.isEmpty)
    }

    @Test func displayStripsMetadataButKeepsClinicalText() throws {
        let original = "### Medicamento\n\n- Texto / comentários: ## Receita simples\n\n### Produto fictício\n<!--\nopenpep:cmed:abc123\n-->\nPosologia de ensaio\n<!-- /openpep:consultation-fields -->"
        let clean = ClinicalTextPresentation.clean(original)
        #expect(!clean.contains("openpep:") && !clean.contains("abc123") && !clean.contains("###"))
        #expect(clean.contains("Produto fictício") && clean.contains("Posologia de ensaio"))
        #expect(original.contains("abc123"))
        let long = String(repeating: "Conteúdo de teste. ", count: 5000)
        #expect(PatientHistoryPresentation.preview(long).count == 1201)
        #expect(PatientHistoryPresentation.preview(long).hasSuffix("…"))
        let suggestions = ConsultationDiagnoses.suggestions(body: "CID J00. Tosse sem outro diagnóstico definido.", patient: nil)
        #expect(suggestions.map { $0[.code] } == ["J00"])
        #expect(ConsultationDiagnoses.suggestions(body: "Paciente com tosse", patient: nil).isEmpty)
    }

    @Test func resendPreservesBytesReissueCreatesNewDateAndCertificateCannotReissue() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-reuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z"))
        let vault = try VaultCreator().create(in: root, identity: VaultCreationIdentity(
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f", deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: date)
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: PatientCreationIdentity(patientID: "pt_0198f5c2-0000-7000-8000-000000000001"),
            input: PatientRecordInput(fullName: "Pessoa de Ensaio", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []), createdAt: date)
        let context = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName, vaultURL: vault.url, authorizationURL: root)
        let body = try LinearConsultationPage(body: "").replacing(.guidance, text: "Orientação a preservar.")
        let preview = try #require(ConsultationDocumentPreview.make(bodyText: body, patientName: patient.displayName, date: date).first)
        let archived = try ClinicalDocumentArchiver().archive(preview.prepared, patient: patient, encounterID: nil,
            deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID)
        let entries = try PatientHistoryReader().load(patientID: patient.patientID, vaultURL: vault.url, authorizationURL: root).entries
        let entry = try #require(entries.first { $0.assetID == archived.pdf.assetID })
        let resend = try PatientDocumentReuse.resend(entry: entry, context: context)
        defer { try? FileManager.default.removeItem(at: resend.file.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: resend.file) == preview.data)
        let later = date.addingTimeInterval(86400)
        let reissue = try PatientDocumentReuse.reissue(entry: entry, context: context, date: later)
        #expect(reissue.document.prepared.createdAt == later)
        #expect(reissue.document.sourceText == preview.sourceText)
        #expect(reissue.document.data != preview.data)
        #expect(try Data(contentsOf: archived.pdf.originalURL) == preview.data)
        let certBody = try LinearConsultationPage(body: "").replacing(.certificate, text: CertificateWording.make(patientName: patient.displayName, days: "3", starting: date, code: "", authorized: false))
        let cert = try #require(ConsultationDocumentPreview.make(bodyText: certBody, patientName: patient.displayName, date: date).first)
        let current = try #require(VaultReader().open(vault.url).patients.first)
        let certArchive = try ClinicalDocumentArchiver().archive(cert.prepared, patient: current, encounterID: nil, deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID)
        let certEntry = try #require(PatientHistoryReader().load(patientID: patient.patientID, vaultURL: vault.url, authorizationURL: root).entries.first { $0.assetID == certArchive.pdf.assetID })
        #expect(!PatientHistoryPresentation.canReissue(certEntry))
        #expect(throws: (any Error).self) { try PatientDocumentReuse.reissue(entry: certEntry, context: context) }
        let forged = PatientHistoryEntry(id: certEntry.id, title: "Orientações", timestamp: certEntry.timestamp,
            status: certEntry.status, text: certEntry.text, source: certEntry.source, assetID: certEntry.assetID, issue: nil)
        #expect(throws: (any Error).self) { try PatientDocumentReuse.reissue(entry: forged, context: context) }
        let forDraft = try #require(VaultReader().open(vault.url).patients.first)
        _ = try ClinicalDraftCreator().create(in: forDraft, identity: ClinicalDraftCreationIdentity(
            encounterID: "enc_0198f5c4-0000-7000-8000-000000000001", noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"), startedAt: date)
        let draftPatient = try #require(VaultReader().open(vault.url).patients.first)
        let encounter = try #require(draftPatient.encounters.first)
        var prescription = PrescriptionPage(text: "")
        prescription.medications = [.init(name: "Medicamento de ensaio", dosage: "Posologia de ensaio")]
        let prescriptionBody = try LinearConsultationPage(body: "Consulta de ensaio.").replacing(.medication, text: prescription.text)
        _ = try ClinicalDraftSaver().save(encounter: encounter, patientID: patient.patientID, body: prescriptionBody, updatedAt: date.addingTimeInterval(60))
        let beforeFinal = try #require(VaultReader().open(vault.url).patients.first)
        #expect(PreviousPrescription.from(beforeFinal).isEmpty)
        _ = try ClinicalFinalizer().finalize(patient: beforeFinal, encounter: try #require(beforeFinal.encounters.first),
            identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000003"), finalizedAt: date.addingTimeInterval(120))
        let afterFinal = try #require(VaultReader().open(vault.url).patients.first)
        #expect(PreviousPrescription.from(afterFinal).map(\.text) == [prescription.text])

    }
}
