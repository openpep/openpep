// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import PDFKit
import SwiftUI
import Testing

@testable import OpenPEP

struct DocumentWorkspaceTests {
    private func documentBody() throws -> String {
        var body = "Texto clínico interno sintético."
        for section in ConsultationTextSection.documentSections {
            body = try LinearConsultationPage(body: body).replacing(
                section.kind!,
                text: "Conteúdo sintético de \(section.label).", title: section == .custom ? "Declaração sintética" : "")
        }
        return body
    }

    @Test("review orders filled documents and never includes the consultation text")
    func previewContents() throws {
        let body = try documentBody()
        let previews = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Paciente Sintético")
        #expect(previews.map(\.section) == ConsultationTextSection.documentSections)
        #expect(previews.last?.title == "Declaração sintética")
        for preview in previews {
            let text = try #require(PDFDocument(data: preview.data)?.string)
            #expect(text.contains("Conteúdo sintético de \(preview.section.label)."))
            #expect(!text.contains("Texto clínico interno"))
            for other in ConsultationTextSection.documentSections where other != preview.section {
                #expect(!text.contains("Conteúdo sintético de \(other.label)."))
            }
        }
        let cleared = try LinearConsultationPage(body: body).replacing(.certificate, text: "")
        #expect(
            try ConsultationDocumentPreview.make(bodyText: cleared, patientName: "Paciente Sintético")
                .map(\.section) == [.guidance, .prescription, .exams, .custom])
        #expect(try ConsultationDocumentPreview.make(bodyText: "Só a consulta interna.", patientName: "Paciente Sintético").isEmpty)
    }

    @MainActor
    @Test("continuous review preserves every page and A4 signature area")
    func continuousReviewAndSignature() throws {
        let previews = try ConsultationDocumentPreview.make(bodyText: documentBody(), patientName: "Paciente Sintético",
            professional: "Dra. Médica Sintética · CRM XX 000000")
        let combinedData = try #require(ConsultationDocumentReviewView.combinedPDF(previews))
        let combined = try #require(PDFDocument(data: combinedData))
        #expect(combined.pageCount == previews.count)
        for (index, preview) in previews.enumerated() {
            let page = try #require(combined.page(at: index))
            #expect(page.string?.contains("Conteúdo sintético de \(preview.section.label).") == true)
            #expect(page.string?.contains("Dra. Médica Sintética") == true)
            #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 0.01)
            #expect(abs(page.bounds(for: .mediaBox).height - 841.89) < 0.01)
        }
        if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try combined.dataRepresentation()?.write(to: url.appending(path: "documentos-assinatura.pdf"))
            let thumbnail = try #require(combined.page(at: 0)).thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox)
            let tiff = try #require(thumbnail.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appending(path: "documento-assinatura.png"))
        }
    }

    @MainActor
    @Test("all document tabs render in narrow and wide windows")
    func layouts() async throws {
        let body = try documentBody()
        for section in ConsultationTextSection.documentSections {
            for (width, scheme) in [(560.0, ColorScheme.light), (1100.0, ColorScheme.dark)] {
                var layoutBody = body
                if section == .prescription {
                    var prescription = PrescriptionPage(text: "")
                    prescription.medications = [.init(name: "MEDICAMENTO DE ENSAIO · apresentação fictícia", dosage: "Posologia de ensaio, preenchida pelo médico.")]
                    layoutBody = try LinearConsultationPage(body: body).replacing(.medication, text: prescription.text)
                }
                let root = ScrollView {
                    ConsultationFieldsEditor.preview(bodyText: layoutBody, section: section).padding(20)
                }
                .frame(width: width, height: 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                try await render(root, width: width, name: "document-\(section.rawValue)-\(Int(width))", scheme: scheme)
            }
        }
        let previews = try ConsultationDocumentPreview.make(bodyText: body, patientName: "Paciente Sintético")
        let review = ConsultationDocumentReviewView(documents: previews, onEdit: { _ in }, onClose: {})
            .frame(width: 820, height: 760).environment(\.colorScheme, .light)
        try await render(review, width: 820, name: "document-review", scheme: .light)
    }

    @MainActor
    private func render(_ root: some View, width: Double, name: String, scheme: ColorScheme) async throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        window.displayIfNeeded()
        #expect(view.fittingSize.width <= width)
        if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appending(path: name + ".png"))
        }
        window.orderOut(nil)
    }
}

extension DocumentWorkspaceTests {
    @MainActor @Test("native PDF remains loaded through repeated opening and navigation")
    func repeatedReviewNavigation() async throws {
        let body = try LinearConsultationPage(body: "").replacing(.guidance,
            text: DocumentPages.joining(["Primeira página de teste.", "Segunda página de teste."]))
        let full = try LinearConsultationPage(body: body).replacing(.exam, text: "Exames de teste.")
        let documents = try ConsultationDocumentPreview.make(bodyText: full, patientName: "Pessoa de ensaio")
        for _ in 0..<4 {
            let model = ConsultationReviewPDFModel(documents: documents)
            #expect(model.pages.map(\.section) == [.guidance, .guidance, .exams])
            #expect(model.pages.map(\.number) == [1, 2, 1])
            let host = NSHostingView(rootView: ConsultationDocumentReviewView(documents: documents, onEdit: { _ in }, onClose: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            func findPDF(_ view: NSView) -> PDFView? {
                if let pdf = view as? PDFView { return pdf }
                return view.subviews.compactMap(findPDF).first
            }
            let view = try #require(findPDF(host))
            let pdf = try #require(view.document)
            #expect(pdf.pageCount == 3)
            for _ in 0..<3 {
                for index in [2, 0, 1] {
                    view.go(to: try #require(pdf.page(at: index)))
                    try await Task.sleep(for: .milliseconds(20))
                    #expect(view.document === pdf)
                    #expect(view.currentPage != nil)
                }
            }
            window.orderOut(nil)
        }
    }
}
