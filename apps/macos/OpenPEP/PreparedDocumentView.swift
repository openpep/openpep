// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreText
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum DocumentProfessionalSettings {
    static let nameKey = "openpep.documents.professional-name"
    static let registrationKey = "openpep.documents.professional-registration"
    static var signature: String { DoctorProfileStore.load().documentIdentity.signatureText }

}

struct PreparedClinicalDocument: Identifiable, Codable {
    let id: UUID
    let title: String
    let data: Data
    let sourceText: String
    let professional: String
    let doctorIdentity: DoctorDocumentIdentity?
    let createdAt: Date
    let pdfIdentity: RawAssetCreationIdentity
    let sourceIdentity: RawAssetCreationIdentity

    init(title: String, data: Data, sourceText: String = "", professional: String = "", doctorIdentity: DoctorDocumentIdentity? = nil, createdAt: Date = Date()) throws {
        self.id = UUID()
        self.title = title
        self.data = data
        self.sourceText = sourceText
        self.professional = professional
        self.doctorIdentity = doctorIdentity
        self.createdAt = createdAt
        pdfIdentity = try .generate(at: createdAt)
        sourceIdentity = try .generate(at: createdAt)
    }
}

/// Typesets the full text into A4 pages. The same bytes drive preview, archival and printing.
enum ClinicalDocumentPDF {
    static func make(title: String, patientName: String, professional: String, body: String, doctorIdentity: DoctorDocumentIdentity? = nil, date: Date = Date()) throws -> Data {
        guard !body.contains(UnifiedPrescription.marker) else { throw CockpitError.message("Revise esta receita na lista de medicamentos para gerar os formulários correspondentes.") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConsultationFieldsError.emptyDocument }
        guard body.utf8.count <= 300_000, title.count <= 300, patientName.count <= 500,
              professional.count <= 500 else { throw ConsultationFieldsError.tooLarge }
        let parts = DocumentPages.split(body).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if parts.count > 1 {
            let combined = PDFDocument()
            for part in parts {
                let data = try make(title: title, patientName: patientName, professional: professional,
                                    body: part, doctorIdentity: doctorIdentity, date: date)
                guard let pdf = PDFDocument(data: data) else { throw ConsultationFieldsError.emptyDocument }
                for index in 0..<pdf.pageCount { if let page = pdf.page(at: index) { combined.insert(page, at: combined.pageCount) } }
                guard combined.pageCount <= 250 else { throw ConsultationFieldsError.tooLarge }
            }
            guard let result = combined.dataRepresentation() else { throw ConsultationFieldsError.emptyDocument }
            return result
        }
        var body = parts.first ?? ""
        var title = title
        if title == "Receituário" || title == "Receituário Especial" {
            let prescription = PrescriptionPage(text: body)
            if !prescription.legacy {
                title = prescription.special ? "Receituário Especial" : "Receituário"
                body = body.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            }
        }
        guard !body.isEmpty else { throw ConsultationFieldsError.emptyDocument }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let text = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 19), .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: "Paciente: \(patientName)\nData: \(date.formatted(date: .numeric, time: .shortened))\n"
                                       + "\n",
                                       attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black,
                                                    .paragraphStyle: paragraph]))
        text.append(formattedBody(body, paragraph: paragraph))
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw ConsultationFieldsError.emptyDocument }
        var offset = 0
        var frames: [CTFrame] = []
        let expandedFooter = doctorIdentity.map { !$0.contactText.isEmpty || $0.signaturePNG != nil } ?? false
        let footerHeight: CGFloat = expandedFooter ? 230 : 148
        let path = CGPath(rect: CGRect(x: 48, y: footerHeight, width: page.width - 96, height: page.height - footerHeight - 48), transform: nil)
        while offset < text.length {
            guard frames.count < 250 else { throw ConsultationFieldsError.tooLarge }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw ConsultationFieldsError.tooLarge }
            frames.append(frame)
            offset += visible.length
        }
        for (index, frame) in frames.enumerated() {
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            if index == frames.count - 1 {
                let lineY: CGFloat = expandedFooter ? 146 : 106
                if let data = doctorIdentity?.signaturePNG, let image = NSImage(data: data),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let scale = min(190 / CGFloat(cgImage.width), 58 / CGFloat(cgImage.height))
                    let size = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
                    context.draw(cgImage, in: CGRect(x: (page.width - size.width) / 2, y: lineY + 8, width: size.width, height: size.height))
                }
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: 148, y: lineY))
                context.addLine(to: CGPoint(x: page.width - 148, y: lineY))
                context.strokePath()
                let signature = NSAttributedString(
                    string: professional.isEmpty ? "Nome do médico e assinatura" : professional,
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
                let signaturePath = CGPath(rect: CGRect(x: 48, y: lineY - 51, width: page.width - 96, height: 43), transform: nil)
                let centered = NSMutableAttributedString(attributedString: signature)
                let alignment = NSMutableParagraphStyle()
                alignment.alignment = .center
                centered.addAttribute(.paragraphStyle, value: alignment, range: NSRange(location: 0, length: centered.length))
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(centered), CFRange(location: 0, length: 0), signaturePath, nil), context)
                if let contact = doctorIdentity?.contactText, !contact.isEmpty {
                    let value = NSAttributedString(string: contact, attributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .paragraphStyle: alignment])
                    let path = CGPath(rect: CGRect(x: 48, y: 35, width: page.width - 96, height: 60), transform: nil)
                    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value), CFRange(location: 0, length: 0), path, nil), context)
                }
            }
            let footer = NSAttributedString(string: "OpenPEP · ensaio sintético · conferir assinatura no arquivo · página \(index + 1) de \(frames.count)",
                                            attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 48, y: expandedFooter ? 18 : 32)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Ordinary text stays ordinary. A small Markdown subset adds headings, emphasis and lists without HTML or remote resources.
    private static func formattedBody(_ body: String, paragraph: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for line in body.components(separatedBy: "\n") {
            if MedicationCatalogMetadata.read(line) != nil { continue }
            var content = line
            var heading = false
            for prefix in ["### ", "## ", "# "] where content.hasPrefix(prefix) {
                content = String(content.dropFirst(prefix.count))
                heading = true
                break
            }
            if content.hasPrefix("- ") { content = "• " + content.dropFirst(2) }
            let parsed = (try? AttributedString(markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
            for run in parsed.runs {
                let value = String(parsed[run.range].characters) + (run.link.map { " (" + $0.absoluteString + ")" } ?? "")
                let strong = heading || run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                let italic = run.inlinePresentationIntent?.contains(.emphasized) == true
                var font = strong ? NSFont.boldSystemFont(ofSize: heading ? 14 : 12) : NSFont.systemFont(ofSize: 12)
                if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.append(NSAttributedString(string: value, attributes: [
                    .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
                ]))
            }
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

}

struct ClinicalPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = PDFDocument(data: data)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        // The sheet owns an immutable snapshot; never regenerate a PDF during printing.
    }
}

struct PreparedDocumentView: View {
    let document: PreparedClinicalDocument
    var isArchived = false
    let onClose: () -> Void
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title).font(.title2)
                    Text("Confira todas as páginas antes de imprimir.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ClinicalPDFPreview(data: document.data)
                .accessibilityLabel("Prévia paginada do documento")
            Divider()
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(8) }
            if let message { Text(message).foregroundStyle(.secondary).padding(8) }
            HStack {
                if isArchived {
                    Label("Guardado no Histórico", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Button("Exportar PDF…", action: export)
                Spacer()
                Button("Imprimir…", systemImage: "printer", action: printDocument)
                    .keyboardShortcut("p")
                    .buttonStyle(.borderedProminent)
            }.padding(18)
        }
        .frame(minWidth: 560, idealWidth: 800, minHeight: 600, idealHeight: 800)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.title + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.data.write(to: url, options: .atomic)
            error = nil
            message = "PDF exportado."
        } catch { self.error = error.localizedDescription }
    }

    private func printDocument() {
        guard let pdf = PDFDocument(data: document.data),
              let operation = pdf.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            error = "Não foi possível preparar a impressão do PDF."
            return
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if operation.run() {
            message = "Trabalho encaminhado ao sistema de impressão."
        }
    }
}
