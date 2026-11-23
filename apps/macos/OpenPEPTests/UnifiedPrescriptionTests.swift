// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import OpenPEP

struct UnifiedPrescriptionTests {
    func patient() -> PatientSummary {
        PatientSummary(patientID: "pt_0198f5c2-0000-7000-8000-000000000001", url: URL(fileURLWithPath: "/synthetic"), record: nil, rawAssets: [], encounters: [])
    }
    func composition() throws -> UnifiedPrescription {
        var result = try UnifiedPrescription(patient: patient(), text: "")
        result.draft.prescriber = .init(nome: "Médico Sintético", crm: "000001", uf: "SP", cpf: "52998224725")
        return result
    }
    @Test func mixedListRoutesEachRestrictedPresentationAndCombinesSimpleItems() throws {
        let catalog = try CockpitMedicationCatalog.load()
        var list = try composition()
        list.draft.medications = [.init(nome: "Item comum sintético A", quantidade: "1", posologia: "Texto livre A."), .init(nome: "Item comum sintético B", quantidade: "2", posologia: "Texto livre B.")]
        for name in ["clonazepam", "amoxicilina", "sertralina", "clonazepam"] {
            let medication = CockpitPrescription.Medication()
            list.draft.medications.append(medication)
            let entry = try #require(catalog.search(name, type: "").first)
            try list.choose(entry, for: medication.id)
            list.draft.medications[list.draft.medications.count - 1].posologia = "Posologia sintética para revisão."
        }
        let docs = try list.documents(catalog: catalog)
        #expect(docs.count == 5)
        #expect(docs[0].tipo == "SIMPLE" && docs[0].medications.count == 2)
        #expect(docs.dropFirst().map(\.tipo) == ["NRB", "RET", "RCE", "NRB"])
        #expect(docs.dropFirst().allSatisfy { $0.medications.count == 1 })
        #expect(Set(docs.map(\.id)).count == 5)
        #expect(try list.documents(catalog: catalog).map(\.id) == docs.map(\.id))
    }
    @Test func unknownPresentationOfKnownControlledDrugCannotFallBackToSimple() throws {
        let catalog = try CockpitMedicationCatalog.load()
        var list = try composition()
        list.draft.medications = [.init(nome: "Tramadol 50 mg", posologia: "Texto livre.")]
        #expect(throws: (any Error).self) { try list.documents(catalog: catalog) }
        let entry = try #require(catalog.entries.first { $0.keys.contains("tramadol") && $0.concentration == "50 mg" })
        try list.choose(entry, for: list.draft.medications[0].id)
        list.draft.medications[0].posologia = "Texto livre revisado."
        #expect(try list.documents(catalog: catalog)[0].tipo == "RCE")
        list.draft.medications[0].concentracao = "999 mg"
        #expect(throws: (any Error).self) { try list.documents(catalog: catalog) }
        list.draft.medications[0].concentracao = entry.concentration
        list.draft.medications[0].recipeOverride = "NRB"
        #expect(try list.documents(catalog: catalog)[0].tipo == "NRB")
        let reopened = try UnifiedPrescription(patient: patient(), text: list.text)
        #expect(reopened.draft.medications[0].recipeOverride == "NRB")
        list.draft.medications[0].posologia = "Tomar __ unidades."
        #expect(throws: (any Error).self) { try list.documents(catalog: catalog) }
    }
    @Test func snapshotPreservesFreeTextAndNeverUsesGenericPrintPath() throws {
        var list = try composition()
        let literal = "Tomar conforme plano revisto, às 8h.\nNão alterar este texto."
        list.draft.medications[0] = .init(nome: "Item sintético", posologia: literal)
        let saved = list.text
        #expect(saved.contains(literal))
        #expect(UnifiedPrescription.clinicalText(saved).contains(literal))
        #expect(!UnifiedPrescription.clinicalText(saved).contains(UnifiedPrescription.marker))
        #expect(!ClinicalTextPresentation.clean(saved).contains(UnifiedPrescription.marker))
        let source = PatientHistoryEntry(id: "synthetic-source", title: "Receita sintética", timestamp: "2026-10-11T00:00:00Z",
            status: "Final", text: saved, source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)
        let ai = try PatientAIContext.make(patient: patient(), entries: [source], corrections: "")
        let wiki = try PatientWikiContext.make(patient: patient(), entries: [source], corrections: "")
        #expect(ai.input.contains(literal) && wiki.input.contains(literal))
        #expect(!ai.input.contains(UnifiedPrescription.marker) && !wiki.input.contains(UnifiedPrescription.marker))
        #expect(try UnifiedPrescription(patient: patient(), text: saved) == list)
        let legacy = try UnifiedPrescription(patient: patient(), text: "Receita anterior, preservar literalmente.")
        #expect(legacy.legacyText == "Receita anterior, preservar literalmente.")
        #expect(throws: (any Error).self) { try legacy.documents(catalog: CockpitMedicationCatalog.load()) }
        #expect(throws: (any Error).self) { try UnifiedPrescription(patient: patient(), text: UnifiedPrescription.marker + "invalid -->") }
        #expect(throws: (any Error).self) { try ClinicalDocumentPDF.make(title: "Receituário", patientName: "Sintético", professional: "", body: saved) }
        var body = try LinearConsultationPage(body: "Consulta sintética.").replacing(.medication, text: saved)
        body = try LinearConsultationPage(body: body).replacing(.guidance, text: "Orientação sintética.")
        let previews = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Sintético")
        #expect(previews.count == 1 && previews[0].section == .guidance)
    }
    @Test func simpleListPaginatesWithoutLosingMedicationOrDosage() throws {
        var list = try composition()
        list.draft.medications = (1...35).map { .init(nome: "Item sintético \($0)", quantidade: "1", posologia: "Orientação literal \($0). " + String(repeating: "Texto para ensaio. ", count: 8)) }
        let docs = try list.documents(catalog: CockpitMedicationCatalog.load())
        #expect(docs.count == 1)
        let data = try ClinicalDocumentPDF.make(title: "Receita simples", patientName: "Paciente Sintético", professional: "Médico Sintético", body: UnifiedPrescription.medicationText(docs[0].medications))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Item sintético 35") == true)
        #expect(pdf.string?.contains("Orientação literal 1.") == true)
        #expect(pdf.string?.contains("Orientação literal 35.") == true)
    }
    @MainActor @Test func allRequiredDataIsCheckedBeforeReturningAnyDocument() async throws {
        let catalog = try CockpitMedicationCatalog.load()
        let renderer = CockpitPDFRenderer()
        var list = try composition()
        list.draft.paciente = .init(nome: "Paciente Sintético", documento: "52998224725", endereco: "Rua Sintética, 100", cidade: "São Paulo", uf: "SP", nascimento: "1990-01-02")
        list.draft.emitente = .init(endereco: "Rua Sintética, 200", cidade: "São Paulo", uf: "SP")
        list.draft.medications = [.init(nome: "Item comum sintético", posologia: "Texto livre de ensaio."), .init()]
        let entry = try #require(catalog.search("amoxicilina", type: "RET").first)
        try list.choose(entry, for: list.draft.medications[1].id)
        list.draft.medications[1].posologia = "Texto sintético, sem orientação clínica."
        do {
            _ = try await list.reviewedDocuments(catalog: catalog, renderer: renderer)
            Issue.record("Deveria pedir o campo obrigatório ausente antes de liberar qualquer documento.")
        } catch { #expect(error.localizedDescription.contains("sexo")) }
        #expect(!list.locked)
        list.draft.paciente.sexo = "F"
        let documents = try await list.reviewedDocuments(catalog: catalog, renderer: renderer)
        #expect(documents.map(\.tipo) == ["SIMPLE", "RET"])
        #expect(!list.locked)
    }
    @Test func fixturesAndLegacyPendingDocumentKeepTheirIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appending(path: "fixtures/prescription-composer-v1")
        for name in ["valid/list.md", "valid/legacy.md"] {
            _ = try UnifiedPrescription(patient: patient(), text: String(contentsOf: root.appending(path: name), encoding: .utf8))
        }
        for name in ["invalid/duplicate-items.md", "invalid/broken-snapshot.md"] {
            let text = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            #expect(throws: (any Error).self) { try UnifiedPrescription(patient: patient(), text: text) }
        }
        var resumed = try composition()
        resumed.draft.medications = [.init(nome: "Item sintético", posologia: "Texto de ensaio."), .init(nome: "Segundo item sintético", posologia: "Texto de ensaio.")]
        resumed.locked = true; resumed.resumedDocumentID = resumed.draft.id
        let reopened = try UnifiedPrescription(patient: patient(), text: resumed.text)
        let documents = try reopened.documents(catalog: CockpitMedicationCatalog.load())
        #expect(documents.count == 1 && documents[0].id == resumed.draft.id)
        #expect(documents[0].medications.count == 2)
        let proposal = try reopened.proposal(for: patient())
        #expect(!proposal.locked && proposal.resumedDocumentID == nil)
        #expect(proposal.draft.id != resumed.draft.id)
        #expect(Set(proposal.draft.medications.map(\.id)).isDisjoint(with: resumed.draft.medications.map(\.id)))
        #expect(proposal.draft.medications.map(\.posologia) == resumed.draft.medications.map(\.posologia))
    }
    @Test func patientAddressAndOtherKnownFieldsArePrefilledWithoutGuessing() throws {
        let original = patient()
        let record = PatientRecord(schema: "openpep-patient-v1", patientID: original.patientID, status: .active,
            fullName: "Paciente Sintética", preferredName: nil, birthDate: "1990-01-02",
            contacts: [.init(type: .phone, value: "+5511000000000", authorizedForCare: false)],
            identifiers: [.init(type: .cpf, value: "52998224725")], alerts: [], createdAt: "2026-10-11T00:00:00Z",
            updatedAt: "2026-10-11T00:00:00Z", archivedAt: nil,
            extensions: ["x_openpep_registration": .mapping([
                "street": .string("Rua Sintética"), "number": .string("123"), "complement": .string("Apto 4"),
                "district": .string("Bairro de Ensaio"), "city": .string("Cidade Sintética"), "state": .string("sp"), "postal_code": .string("00000-000")])])
        let registered = PatientSummary(patientID: original.patientID, url: original.url, record: record, rawAssets: [], encounters: [])
        let draft = CockpitPrescription(patient: registered)
        #expect(draft.paciente.endereco == "Rua Sintética, 123, Apto 4, Bairro de Ensaio, 00000-000")
        #expect(draft.paciente.cidade == "Cidade Sintética" && draft.paciente.uf == "SP")
        #expect(draft.paciente.documento == "52998224725" && draft.paciente.nascimento == "1990-01-02")
        #expect(draft.paciente.telefone == "+5511000000000" && draft.paciente.sexo.isEmpty)
        #expect(CockpitPrescription(patient: original).paciente.endereco.isEmpty)
    }
}


extension UnifiedPrescriptionTests {
    @MainActor @Test func renderUnifiedFormForInspection() throws {
        var list = try composition()
        let catalog = try CockpitMedicationCatalog.load()
        let entry = try #require(catalog.entries.first { $0.keys.contains("clonazepam") && $0.form == "comprimido" })
        try list.choose(entry, for: list.draft.medications[0].id)
        list.draft.medications[0].posologia = "Posologia sintética para avaliação da interface. Texto livre revisado pelo profissional."
        list.draft.medications[0].quantidade = "30"
        list.draft.medications.append(.init(nome: "Medicamento comum sintético", quantidade: "1", posologia: "Segunda orientação de ensaio, livremente editável."))
        let editor = UnifiedPrescriptionEditor(text: .constant(list.text), patient: patient(), encounterID: nil, authorizationURL: nil,
            onArchive: { _ in throw ConsultationFieldsError.ambiguous })
        let view = NSHostingView(rootView: editor.padding(24).frame(width: 860, height: 900, alignment: .topLeading)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); view.appearance = NSAppearance(named: .aqua)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/openpep-unified-prescription.png"), options: .atomic)
    }
}
