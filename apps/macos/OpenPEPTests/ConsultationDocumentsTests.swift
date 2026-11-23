// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import OpenPEP

@Suite("Consultation fields, document snapshots and patient history")
struct ConsultationDocumentsTests {
    @Test("round trips multiline fields without changing free text or inferring diagnosis course")
    func roundTrip() throws {
        let free = "## Evolução\n\nTexto livre sintético, sem alterações.\n"
        let fields = sampleFields
        let body = try fields.replacing(in: free)
        let parsed = try ConsultationFields.read(from: body)
        #expect(parsed.markdown == fields.markdown)
        #expect(parsed.items.first?[.course] == "Crônico")
        #expect(parsed.items.first?[.certainty] == "")
        #expect(parsed.items.last?[.detail] == "Linha um.\n\n### título digitado\n- Texto: valor\n    indentação")
        #expect(try parsed.replacing(in: body) == body)
        let cleared = try ConsultationFields().replacing(in: body)
        #expect(cleared.hasPrefix(free))
        #expect(!cleared.contains(ConsultationFields.start))
    }

    @Test("refuses ambiguous manual edits instead of discarding them")
    func ambiguousText() throws {
        let body = sampleFields.markdown
        for bad in [body + body, body.replacingOccurrences(of: ConsultationFields.end, with: ""),
                    body.replacingOccurrences(of: "- Curso: Crônico", with: "Texto clínico que não pode ser apagado"),
                    body.replacingOccurrences(of: "- Curso: Crônico", with: "- Curso: Crônico\n- Curso: Agudo")] {
            #expect(throws: (any Error).self) { try ConsultationFields.read(from: bad) }
            #expect(throws: (any Error).self) { try sampleFields.replacing(in: bad) }
        }
    }

    @Test("external document excludes diagnosis and its internal comment")
    func isolatesDocumentContent() throws {
        let text = try sampleFields.documentText(for: .guidance)
        #expect(text.contains("Linha um"))
        #expect(!text.contains("Diagnóstico sintético"))
        #expect(!text.contains("Comentário interno"))
        #expect(throws: (any Error).self) { try sampleFields.documentText(for: .diagnosis) }
        #expect(throws: (any Error).self) { try sampleFields.documentText(for: .medication) }
    }

    @Test("catalog matches accents and rejects duplicate normalized codes and malformed imports")
    func catalog() throws {
        // Synthetic descriptions intentionally do not assert official clinical terminology.
        let catalog = try LocalDiagnosisCatalog(tsv: "A00\tDescrição sintética\nB00.1\tOutro termo sintético\n")
        #expect(catalog.search("DESCRICAO").map(\.code) == ["A00"])
        #expect(catalog.search("b00 outro").map(\.code) == ["B00.1"])
        #expect(catalog.search("").isEmpty)
        for invalid in ["", "A00\t", "../../a\tTexto", "B001\tUm\nB00.1\tDois", "A00\tA\textra"] {
            #expect(throws: (any Error).self) { try LocalDiagnosisCatalog(tsv: invalid) }
        }
    }

    @Test("PDF paginates the entire reviewed text with extractable beginning and end")
    func paginatesPDF() throws {
        let body = (1...250).map { "Item sintético \($0): informação completa para conferir paginação." }.joined(separator: "\n")
        let data = try ClinicalDocumentPDF.make(title: "Orientações sintéticas", patientName: "Paciente Teste",
                                               professional: "Profissional Sintético", body: body, date: date)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 3)
        let text = try #require(pdf.string)
        for index in 1...250 { #expect(text.contains("Item sintético \(index):")) }
        #expect(text.contains("Paciente Teste"))
        #expect(text.contains("conferir assinatura no arquivo"))
        #expect(throws: (any Error).self) {
            try ClinicalDocumentPDF.make(title: "Vazio", patientName: "Teste", professional: "", body: "  ")
        }
    }

    @Test("fields survive save, finalization and backup restore; PDFs remain searchable from verified history")
    func clinicalRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-documents-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try VaultCreator().create(in: root, identity: VaultCreationIdentity(
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
            deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: date)
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(fullName: "Paciente Sintético dos Documentos", preferredName: nil, birthDate: nil,
                                      contacts: [], identifiers: [], alerts: []), createdAt: date)
        _ = try ClinicalDraftCreator().create(in: patient, identity: ClinicalDraftCreationIdentity(
            encounterID: encounterID, noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"), startedAt: date)
        var current = try VaultReader().open(vault.url)
        let encounter = try #require(current.patients.first?.encounters.first)
        let body = try sampleFields.replacing(in: "Evolução sintética preservada.\n")
        _ = try ClinicalDraftSaver().save(encounter: encounter, patientID: patientID, body: body, updatedAt: date.addingTimeInterval(10))
        // Stale editor cannot overwrite a newer saved body.
        #expect(throws: (any Error).self) {
            try ClinicalDraftSaver().save(encounter: encounter, patientID: patientID, body: "Perda proibida", updatedAt: date.addingTimeInterval(20))
        }
        current = try VaultReader().open(vault.url)
        let savedPatient = try #require(current.patients.first)
        let savedEncounter = try #require(savedPatient.encounters.first)
        let final = try ClinicalFinalizer().finalize(patient: savedPatient, encounter: savedEncounter,
            identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000001"), finalizedAt: date.addingTimeInterval(30))
        #expect(final.finalNote.body == body)
        #expect(try ConsultationFields.read(from: final.finalNote.body).markdown == sampleFields.markdown)
        let pdf = try ClinicalDocumentPDF.make(title: "Orientações", patientName: "Paciente Sintético dos Documentos",
            professional: "", body: "Documento sintético pesquisável. Não há recomendação real.", date: date)
        let source = root.appending(path: "Orientações sintéticas.pdf")
        try pdf.write(to: source)
        _ = try GeneralDocumentImporter().importDocument(from: source, into: savedPatient, encounterID: encounterID,
            deviceID: vault.manifest.deviceID, identity: try RawAssetCreationIdentity.generate(at: date), importedAt: date)
        let snapshot = try PatientHistoryReader().load(patientID: patientID, vaultURL: vault.url, authorizationURL: root)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.contains { $0.status == "Finalizada" && $0.text.contains("Comentário interno") })
        let document = try #require(snapshot.entries.first(where: { $0.isDocument }))
        #expect(document.issue == nil)
        #expect(document.matches("documento pesquisavel"))
        #expect(!document.text.contains("Comentário interno"))
        #expect(throws: (any Error).self) {
            try PatientHistoryReader().load(patientID: "pt_0198f5c2-0000-7000-8000-000000000002", vaultURL: vault.url, authorizationURL: root)
        }
        let backup = root.appending(path: "backup")
        _ = try VaultBackupService().create(from: vault.url, to: backup)
        let restore = root.appending(path: "restored")
        _ = try VaultBackupService().restore(from: backup, to: restore)
        let restored = try PatientHistoryReader().load(patientID: patientID, vaultURL: restore, authorizationURL: root)
        #expect(restored.entries.map(\.text) == snapshot.entries.map(\.text))
        current = try VaultReader().open(vault.url)
        let asset = try #require(current.patients.first?.rawAssets.first)
        try Data("alterado".utf8).write(to: asset.originalURL)
        #expect(throws: (any Error).self) { try PatientHistoryReader.documentText(asset) }
    }

    @Test("favorite Markdown library is portable and rejects symlinks without changing originals")
    func favoriteLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-favorites-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Modelo sintético.md")
        let data = Data((sampleFields.markdown + "\n").utf8)
        try data.write(to: file)
        let favorite = try #require(DoctorDocumentLibrary.read(root).first)
        #expect(favorite.markdown == sampleFields.markdown)
        #expect(favorite.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        var applied = try ConsultationFields.read(from: favorite.markdown)
        applied.items[0][.title] = "Cópia alterada"
        #expect(try Data(contentsOf: file) == data)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Link.md"), withDestinationURL: file)
        #expect(throws: (any Error).self) { try DoctorDocumentLibrary.read(root) }
    }

    @Test("linear areas preserve legacy structured data and edit only the selected area")
    func linearCompatibility() throws {
        var medication = ConsultationFieldItem(kind: .medication)
        medication[.title] = "Medicamento sintético"
        medication[.dose] = "Dose fictícia"
        medication[.route] = "Via declarada"
        medication[.detail] = "Informação a preservar"
        var legacy = sampleFields
        legacy.items.append(medication)
        let original = try legacy.replacing(in: "Consulta sintética anterior.\n")
        let page = try LinearConsultationPage(body: original)
        #expect(page.consultation == "Consulta sintética anterior.\n")
        #expect(page.text(for: .medication)?.contains("Dose: Dose fictícia") == true)
        #expect(page.text(for: .medication)?.contains("Via: Via declarada") == true)
        let updated = try page.replacing(.exam, text: "Solicito:\nExame sintético A\nExame sintético B")
        let reread = try LinearConsultationPage(body: updated)
        #expect(reread.fields.items.first(where: { $0.kind == .medication })?.values == medication.values)
        #expect(reread.text(for: .exam) == "Solicito:\nExame sintético A\nExame sintético B")
        let changedNote = try reread.replacingConsultation(with: "Consulta alterada, sem modificar os documentos.")
        #expect(try LinearConsultationPage(body: changedNote).fields.markdown == reread.fields.markdown)
        let newlines = try reread.replacingConsultation(with: "Primeira linha\n\n")
        #expect(try LinearConsultationPage(body: newlines).consultation == "Primeira linha\n\n")
        let openMedication = try reread.replacing(.medication, text: page.text(for: .medication) ?? "")
        #expect(try LinearConsultationPage(body: openMedication).text(for: .medication) == page.text(for: .medication))
        #expect(throws: (any Error).self) {
            try reread.replacingConsultation(with: ConsultationFields.start)
        }
    }

    @Test("unused areas stay absent and a custom document keeps independent title and free text")
    func linearOptionalFields() throws {
        let page = try LinearConsultationPage(body: "Nota sintética")
        #expect(page.fields.items.isEmpty)
        #expect(page.text(for: .exam) == nil)
        let document = try page.replacing(.custom, text: "Texto livre com **ênfase**.\nOutra linha.", title: "Relatório sintético")
        let reread = try LinearConsultationPage(body: document)
        #expect(reread.customTitle == "Relatório sintético")
        #expect(reread.text(for: .custom) == "Texto livre com **ênfase**.\nOutra linha.")
        #expect(reread.text(for: .medication) == nil)
        let cleared = try reread.replacing(.custom, text: "")
        #expect(try LinearConsultationPage(body: cleared).fields.items.isEmpty)
        #expect(cleared.hasPrefix("Nota sintética"))
    }

    @Test("templates accept plain text, optional Markdown and the earlier template format")
    func freeTextTemplates() throws {
        let plain = try ConsultationTextTemplate.read("Solicito:\nExame sintético", section: .exams)
        #expect(plain.text == "Solicito:\nExame sintético")
        let titled = try ConsultationTextTemplate.read("# Laudo sintético\n\nTexto **editável**.", section: .custom)
        #expect(titled.title == "Laudo sintético")
        #expect(titled.text == "Texto **editável**.")
        #expect(titled.fileText == "# Laudo sintético\n\nTexto **editável**.")
        let old = try ConsultationTextTemplate.read(sampleFields.markdown, section: .guidance)
        #expect(old.text.contains("Linha um"))
        #expect(!old.text.contains("Comentário interno"))
    }

    @Test("PDF supports optional Markdown and numbers every page with the total")
    func markdownAndPageNumbers() throws {
        let body = "## Título sintético\nTexto **marcado** e texto comum.\n- Item sintético\n"
            + (1...120).map { "Linha completa \($0)" }.joined(separator: "\n")
        let data = try ClinicalDocumentPDF.make(title: "Pedido sintético", patientName: "Paciente Sintético", professional: "", body: body)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        for index in 0..<pdf.pageCount {
            #expect(pdf.page(at: index)?.string?.contains("página \(index + 1) de \(pdf.pageCount)") == true)
        }
        #expect(pdf.string?.contains("## Título") == false)
        #expect(pdf.string?.contains("**marcado**") == false)
        #expect(pdf.string?.contains("Texto marcado") == true)
        #expect(pdf.string?.contains("Linha completa 120") == true)
    }

    @Test("renders synthetic form and PDF previews for visual inspection")
    @MainActor
    func renderPreviews() throws {
        let editor = ConsultationFieldsEditor(bodyText: .constant(""), onPrepare: { _, _ in })
        let view = NSHostingView(rootView: editor.padding(24).frame(width: 860, height: 760, alignment: .topLeading)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        view.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/openpep-fields-linear.png"), options: .atomic)
        let pdfData = try ClinicalDocumentPDF.make(title: "Orientações ao paciente", patientName: "Paciente Sintético dos Documentos",
            professional: "Profissional Sintético · registro de ensaio", body: "Texto fictício para conferir a apresentação.\n\nOrientações registradas pelo profissional.\nNenhuma recomendação clínica real.", date: date)
        let page = try #require(PDFDocument(data: pdfData)?.page(at: 0))
        let thumbnail = page.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox)
        let tiff = try #require(thumbnail.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/openpep-document-preview.png"), options: .atomic)
    }

    @Test("renders included diagnoses and filled documents in light and dark appearance")
    @MainActor
    func renderPopulatedFields() throws {
        let fields = ConsultationFields(items: [
            ConsultationFieldItem(kind: .diagnosis, values: [.code: "I10", .title: "Diagnóstico sintético para revisar a interface", .course: "Crônico", .detail: "Comentário referente somente a este diagnóstico."]),
            ConsultationFieldItem(kind: .diagnosis, values: [.code: "E11.9", .title: "Segundo diagnóstico sintético", .course: "Não crônico"]),
            ConsultationFieldItem(kind: .guidance, values: [.detail: "Orientações sintéticas registradas pelo profissional.\nEste campo permanece aberto enquanto contiver texto."])
        ])
        let body = try fields.replacing(in: "Registro sintético do atendimento para avaliação visual.")
        for dark in [false, true] {
            let editor = ConsultationFieldsEditor(bodyText: .constant(body), onPrepare: { _, _ in })
            let view = NSHostingView(rootView: editor.padding(24).frame(width: 860, height: 1160, alignment: .topLeading)
                .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 1160),
                styleMask: [.borderless], backing: .buffered, defer: false)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = appearance
            view.appearance = appearance
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            try image.write(to: URL(fileURLWithPath: dark ? "/tmp/openpep-fields-populated-dark.png" : "/tmp/openpep-fields-populated-light.png"), options: .atomic)
        }
    }

    @Test("bundled Brazilian CID catalog is complete for the recorded edition and works offline")
    func bundledCatalog() throws {
        let catalog = try BundledDiagnosisCatalog.result.get()
        #expect(catalog.entries.count == 14_233)
        #expect(catalog.search("I10").contains { $0.code == "I10" && $0.title.contains("Hipertensão") })
        #expect(catalog.search("hipertensao essencial").contains { $0.code == "I10" })
        #expect(catalog.search("E119").contains { $0.code == "E11.9" })
        #expect(catalog.search("e11.9").contains { $0.code == "E11.9" })
        let source = catalog.entries.map { $0.code + "\t" + $0.title + "\n" }.joined()
        #expect(SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            == "a5a8ae4dfd02186e90bebb1387bab5bff9f6209b37c111e8a69a866fa7b924f1")
    }

    @Test("diagnoses are optional, survive editing and removal, and the latest chronic observation wins")
    func optionalAndChronicDiagnoses() throws {
        let chronic = ConsultationFieldItem(kind: .diagnosis, values: [.code: "I10", .title: "Diagnóstico de ensaio", .course: "Crônico", .detail: "Comentário sintético"])
        let acute = ConsultationFieldItem(kind: .diagnosis, values: [.code: "A00", .title: "Outro diagnóstico de ensaio", .course: "Não crônico"])
        let freeText = "Consulta sintética sem diagnóstico obrigatório.\n"
        let withoutDiagnosis = try ConsultationFields().replacing(in: freeText)
        #expect(try ConsultationFields.read(from: withoutDiagnosis).items.isEmpty)

        let body = try ConsultationFields(items: [chronic, acute]).replacing(in: withoutDiagnosis)
        var edited = try ConsultationFields.read(from: body)
        edited.items[0][.detail] = "Comentário sintético revisado"
        edited.items.removeAll { $0[.code] == "A00" }
        let editedBody = try edited.replacing(in: body)
        let reread = try ConsultationFields.read(from: editedBody)
        #expect(reread.items.map { $0[.code] } == ["I10"])
        #expect(reread.items[0][.detail] == "Comentário sintético revisado")
        #expect(editedBody.hasPrefix(freeText))

        let removedBody = try ConsultationFields().replacing(in: editedBody)
        #expect(try ConsultationFields.read(from: removedBody).items.isEmpty)
        #expect(removedBody.hasPrefix(freeText))

        let previous = ConsultationDiagnoses.chronic(from: [body, body])
        #expect(previous.count == 1)
        #expect(previous.first?[.detail] == "Comentário sintético")
        var noLongerChronic = chronic
        noLongerChronic[.course] = "Não crônico"
        #expect(ConsultationDiagnoses.chronic(from: [body, ConsultationFields(items: [noLongerChronic]).markdown]).isEmpty)
        #expect(ConsultationDiagnoses.chronic(from: ["Texto livre: I10 crônico"]).isEmpty)
    }

    @Test("certificate wording validates days, keeps CID absent by default and requires explicit authorization")
    func certificate() throws {
        let plain = try CertificateWording.make(patientName: "Paciente Sintético", days: "3", starting: date, code: "", authorized: false)
        #expect(plain.contains("3 dias"))
        #expect(!plain.contains("CID"))
        let authorized = try CertificateWording.make(patientName: "Paciente Sintético", days: "1", starting: date, code: "E119", authorized: true)
        #expect(authorized.contains("1 dia,"))
        #expect(authorized.contains("CID-10: E11.9"))
        #expect(authorized.contains("autorização expressa"))
        for days in ["", "0", "-1", "1.5", "3651"] {
            #expect(throws: (any Error).self) {
                try CertificateWording.make(patientName: "Teste", days: days, starting: date, code: "", authorized: false)
            }
        }
        #expect(throws: (any Error).self) {
            try CertificateWording.make(patientName: "Teste", days: "1", starting: date, code: "I10", authorized: false)
        }
        #expect(throws: (any Error).self) {
            try CertificateWording.make(patientName: "Teste", days: "1", starting: date, code: "XYZ", authorized: true)
        }
        let edited = plain + "\nRedação alterada pelo profissional."
        let body = try LinearConsultationPage(body: "").replacing(.certificate, text: edited)
        #expect(try LinearConsultationPage(body: body).text(for: .certificate) == edited)
    }

    @Test("independent source and PDF roundtrip with optional encounter, single history entry, export and backup")
    func independentDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-independent-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try VaultCreator().create(in: root, identity: VaultCreationIdentity(
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
            deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: date)
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(fullName: "Paciente Sintético", preferredName: nil, birthDate: nil,
                contacts: [], identifiers: [], alerts: []), createdAt: date)
        let text = "Texto independente sintético com **ênfase**.\n\nSem recomendação clínica."
        let pdf = try ClinicalDocumentPDF.make(title: "Relatório: \"teste\"", patientName: "Paciente Sintético", professional: "", body: text, date: date)
        let document = try PreparedClinicalDocument(title: "Relatório: \"teste\"", data: pdf, sourceText: text, createdAt: date)
        let result = try ClinicalDocumentArchiver().archive(document, patient: patient, encounterID: nil, deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID, now: date)
        let sourceText = try String(contentsOf: result.source.originalURL, encoding: .utf8)
        #expect(sourceText.contains("encounter_id: null"))
        let reread = try IndependentClinicalDocument.read(sourceText)
        #expect(reread.header.encounter_id == nil)
        #expect(reread.header.patient_id == patientID)
        #expect(reread.header.pdf_asset_id == result.pdf.assetID)
        #expect(reread.header.pdf_sha256 == result.pdf.sha256)
        #expect(reread.body == text)
        var current = try VaultReader().open(vault.url)
        #expect(current.writingAllowed)
        #expect(current.patients.first?.encounters.isEmpty == true)
        #expect(current.patients.first?.rawAssets.count == 2)
        let snapshot = try PatientHistoryReader().load(patientID: patientID, vaultURL: vault.url, authorizationURL: root)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.status == "Documento avulso")
        #expect(snapshot.entries.first?.text == text)
        #expect(snapshot.entries.first?.assetID == result.pdf.assetID)
        let exported = try ClinicalExportService().export(scope: .patient(patientID: patientID), from: vault.url, to: root.appending(path: "export"))
        #expect(exported.documentCount == 2)
        let backup = root.appending(path: "backup")
        _ = try VaultBackupService().create(from: vault.url, to: backup)
        let restoredURL = root.appending(path: "restored")
        _ = try VaultBackupService().restore(from: backup, to: restoredURL)
        let restored = try PatientHistoryReader().load(patientID: patientID, vaultURL: restoredURL, authorizationURL: root)
        #expect(restored.entries.map(\.text) == snapshot.entries.map(\.text))
        // Binding to a nonexistent encounter must fail without new files.
        #expect(throws: (any Error).self) {
            try ClinicalDocumentArchiver().archive(document, patient: patient, encounterID: encounterID, deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID)
        }
        current = try VaultReader().open(vault.url)
        #expect(current.patients.first?.rawAssets.count == 2)
        let freshPatient = try #require(current.patients.first)
        _ = try ClinicalDraftCreator().create(in: freshPatient, identity: ClinicalDraftCreationIdentity(
            encounterID: encounterID, noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"), startedAt: date)
        current = try VaultReader().open(vault.url)
        let withEncounter = try #require(current.patients.first)
        // A different binding is a new preparation; an existing snapshot cannot move between contexts.
        let linkedPreparation = try PreparedClinicalDocument(title: document.title, data: document.data,
            sourceText: document.sourceText, createdAt: date.addingTimeInterval(1))
        let linked = try ClinicalDocumentArchiver().archive(linkedPreparation, patient: withEncounter, encounterID: encounterID,
            deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID, now: date.addingTimeInterval(1))
        #expect(try IndependentClinicalDocument.read(String(contentsOf: linked.source.originalURL, encoding: .utf8)).header.encounter_id == encounterID)
        #expect(try VaultReader().open(vault.url).writingAllowed)
        // Altered source cannot replace the intact PDF's text in history.
        try Data("changed".utf8).write(to: result.source.originalURL)
        let asset = try #require(current.patients.first?.rawAssets.first { $0.assetID == result.source.assetID })
        #expect(throws: (any Error).self) { try PatientHistoryReader.documentText(asset) }
    }

    private var sampleFields: ConsultationFields {
        var diagnosis = ConsultationFieldItem(kind: .diagnosis)
        diagnosis[.title] = "Diagnóstico sintético"
        diagnosis[.code] = "Código declarado pelo médico"
        diagnosis[.course] = "Crônico"
        diagnosis[.detail] = "Comentário interno"
        var guidance = ConsultationFieldItem(kind: .guidance)
        guidance[.title] = "Orientações sintéticas"
        guidance[.detail] = "Linha um.\n\n### título digitado\n- Texto: valor\n    indentação"
        return ConsultationFields(items: [diagnosis, guidance])
    }
    private let date = Date(timeIntervalSince1970: 1_788_110_400)
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let encounterID = "enc_0198f5d1-0000-7000-8000-000000000001"
}
