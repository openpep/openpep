// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import PDFKit

struct ConsultationDocumentPreview: Identifiable {
    let section: ConsultationTextSection
    let title: String
    let data: Data
    let sourceText: String
    let fingerprint: String
    let prepared: PreparedClinicalDocument
    var id: ConsultationTextSection { section }

    static func make(bodyText: String, patientName: String, professional: String = "", doctorIdentity: DoctorDocumentIdentity? = nil, date: Date = Date()) throws -> [Self] {
        let page = try LinearConsultationPage(body: bodyText)
        return try ConsultationTextSection.documentSections.compactMap { section in
            guard let kind = section.kind, let text = page.text(for: kind),
                DocumentPages.split(text).contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            if section == .prescription, text.contains(UnifiedPrescription.marker) { return nil }
            if section == .prescription {
                for part in DocumentPages.split(text) {
                    let prescription = PrescriptionPage(text: part)
                    if !prescription.legacy && !prescription.compounded && prescription.medications.contains(where: { $0.dosage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        throw VaultValidationIssue(rule: "prescription.dosage", path: "", message: "Preencha a posologia de cada medicamento antes de revisar.")
                    }
                }
            }
            let title = section == .custom && !page.customTitle.isEmpty ? page.customTitle : kind.documentTitle
            let data = try ClinicalDocumentPDF.make(title: title, patientName: patientName,
                professional: professional, body: text, doctorIdentity: doctorIdentity, date: date)
            let identity = doctorIdentity ?? DoctorProfileStore.load().documentIdentity
            return Self(section: section, title: title, data: data, sourceText: text,
                fingerprint: DocumentReviewRecord.fingerprint(section: section, text: title + "\n" + text,
                    patientName: patientName, identity: identity),
                prepared: try PreparedClinicalDocument(title: title, data: data, sourceText: text,
                    professional: professional, doctorIdentity: doctorIdentity, createdAt: date))
        }
    }
}

struct ConsultationReviewSnapshot: Identifiable {
    let id = UUID()
    let documents: [ConsultationDocumentPreview]
}

@MainActor
final class ConsultationReviewPDFModel: ObservableObject {
    struct Page: Identifiable {
        let id: Int
        let section: ConsultationTextSection
        let number: Int
        let thumbnail: NSImage
    }
    let pdf: PDFDocument
    private let sourcePDFs: [PDFDocument]
    let pages: [Page]
    @Published var selectedPage = 0
    init(documents: [ConsultationDocumentPreview]) {
        let combined = PDFDocument()
        var pages: [Page] = []
        var sources: [PDFDocument] = []
        for document in documents {
            guard let source = PDFDocument(data: document.data) else { continue }
            sources.append(source)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                let position = combined.pageCount
                combined.insert(page, at: position)
                let thumbnail = page.thumbnail(of: NSSize(width: 220, height: 312), for: .mediaBox)
                pages.append(Page(id: position, section: document.section, number: index + 1, thumbnail: thumbnail))
            }
        }
        pdf = combined; self.pages = pages; sourcePDFs = sources
    }
}

private struct ConsultationReviewPDFCanvas: NSViewRepresentable {
    @ObservedObject var model: ConsultationReviewPDFModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.document = model.pdf
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.lastSelection != model.selectedPage,
           let page = model.pdf.page(at: model.selectedPage) {
            context.coordinator.lastSelection = model.selectedPage
            view.go(to: page)
        }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator {
        let model: ConsultationReviewPDFModel
        var token: NSObjectProtocol?
        var lastSelection = 0
        init(model: ConsultationReviewPDFModel) { self.model = model }
        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let page = view?.currentPage else { return }
                    let index = self.model.pdf.index(for: page)
                    guard index != NSNotFound else { return }
                    self.lastSelection = index
                    if self.model.selectedPage != index { self.model.selectedPage = index }
                }
            }
        }
        func stop() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
    }
}

struct ConsultationDocumentReviewView: View {
    let documents: [ConsultationDocumentPreview]
    let onEdit: (ConsultationTextSection) -> Void
    let onClose: () -> Void
    var onApprove: (([ConsultationDocumentPreview]) async throws -> [URL])? = nil
    var onFinish: (() -> Void)? = nil
    var deliveryPatient: PatientSummary? = nil
    var allowsEditing = true
    var onDelivered: (() -> Void)? = nil
    @State private var approved: Set<ConsultationTextSection>
    @State private var storedFiles: [ConsultationTextSection: URL] = [:]
    @State private var delivery: DocumentDelivery?
    @State private var deliveryCompleted = false
    @State private var saving = false
    @State private var signedDocuments: [ConsultationTextSection: ConsultationDocumentPreview] = [:]
    @State private var signingDocument: ConsultationDocumentPreview?
    @State private var error: String?
    @StateObject private var pdfModel: ConsultationReviewPDFModel

    init(documents: [ConsultationDocumentPreview], onEdit: @escaping (ConsultationTextSection) -> Void,
         onClose: @escaping () -> Void, onApprove: (([ConsultationDocumentPreview]) async throws -> [URL])? = nil,
         onFinish: (() -> Void)? = nil, deliveryPatient: PatientSummary? = nil, allowsEditing: Bool = true, onDelivered: (() -> Void)? = nil) {
        self.documents = documents; self.onEdit = onEdit; self.onClose = onClose
        self.onApprove = onApprove; self.onFinish = onFinish
        self.deliveryPatient = deliveryPatient; self.onDelivered = onDelivered; self.allowsEditing = allowsEditing
        _approved = State(initialValue: Set(documents.map(\.section)))
        _pdfModel = StateObject(wrappedValue: ConsultationReviewPDFModel(documents: documents))
    }
    private var currentDocument: ConsultationDocumentPreview? {
        let section = pdfModel.pages.first { $0.id == pdfModel.selectedPage }?.section
        return documents.first { $0.section == section }
    }

    static func combinedPDF(_ documents: [ConsultationDocumentPreview]) -> Data? {
        let combined = PDFDocument()
        for document in documents {
            guard let pdf = PDFDocument(data: document.data) else { return nil }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { return nil }
                combined.insert(page, at: combined.pageCount)
            }
        }
        return combined.dataRepresentation()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Revisar documentos").font(.title2.weight(.semibold))
                Spacer()
                Button("Fechar", action: onClose)
                    .keyboardShortcut(.cancelAction).disabled(saving)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let document = currentDocument {
                        HStack {
                            Text(document.title).font(.headline).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            if onApprove != nil, signedDocuments[document.section] == nil {
                                Button("Assinar PDF…") { signingDocument = document }.disabled(saving)
                            }
                            if signedDocuments[document.section] != nil { Label("Assinado e guardado", systemImage: "checkmark.seal").font(.callout) }
                            if allowsEditing {
                                Button("Editar", systemImage: "pencil") { onEdit(document.section) }.disabled(saving)
                            }
                        }.padding(12)
                    }
                    ConsultationReviewPDFCanvas(model: pdfModel)
                        .accessibilityLabel("Documentos em páginas contínuas")

                }
                Divider()
                pageSidebar
            }

            Divider()
            if let error { Text(error).foregroundStyle(.red).padding(8) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Text("\(approved.count) de \(documents.count) selecionados").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Encerrar") { finish(.close) }.disabled(saving)
                Button("Imprimir", systemImage: "printer") { finish(.print) }
                    .disabled(saving || approved.isEmpty || onApprove == nil)
                Button("Enviar", systemImage: "paperplane") { finish(.send) }
                    .buttonStyle(.borderedProminent).disabled(saving || approved.isEmpty || onApprove == nil)
            }.padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 520, idealWidth: 820, minHeight: 540, idealHeight: 780)
        .sheet(item: $signingDocument) { selected in
            LocalDocumentSigningView(document: selected.prepared, onSigned: { signed in
                guard let onApprove else { throw ConsultationFieldsError.ambiguous }
                let updated = ConsultationDocumentPreview(section: selected.section, title: selected.title,
                    data: signed.data, sourceText: selected.sourceText, fingerprint: selected.fingerprint, prepared: signed)
                _ = try await onApprove([updated])
                signedDocuments[selected.section] = updated
                storedFiles[selected.section] = nil
            }, onClose: { signingDocument = nil })
        }
        .sheet(item: $delivery, onDismiss: {
            if deliveryCompleted { onDelivered?() }
        }) { delivery in
            DocumentDeliveryView(files: delivery.files, patient: deliveryPatient,
                onClose: { self.delivery = nil },
                onCompleted: { deliveryCompleted = true; self.delivery = nil })
        }
    }
    private var pageSidebar: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(documents) { document in
                        Toggle(document.section.label, isOn: Binding(
                            get: { approved.contains(document.section) },
                            set: { if $0 { approved.insert(document.section) } else { approved.remove(document.section) } }))
                            .toggleStyle(.checkbox).font(.caption.weight(.semibold)).disabled(saving)
                            .accessibilityLabel("Incluir \(document.title)")
                        ForEach(pdfModel.pages.filter { $0.section == document.section }) { page in
                            Button { pdfModel.selectedPage = page.id } label: {
                                VStack(spacing: 5) {
                                    Image(nsImage: page.thumbnail).resizable().aspectRatio(595.28 / 841.89, contentMode: .fit)
                                        .background(.white)
                                        .overlay(Rectangle().stroke(pdfModel.selectedPage == page.id ? Color.accentColor : .secondary.opacity(0.25), lineWidth: pdfModel.selectedPage == page.id ? 3 : 1))
                                    Text("Página \(page.number)").font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).id(page.id)
                                .accessibilityLabel("Ir para \(document.title), página \(page.number)")
                        }
                    }
                }.padding(12)
            }
            .onChange(of: pdfModel.selectedPage) { _, page in withAnimation { reader.scrollTo(page, anchor: .center) } }
        }
        .frame(width: 130).background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Páginas por documento")
    }

    private enum Action { case close, print, send }
    private func finish(_ action: Action) {
        let chosen = documents.filter { approved.contains($0.section) }.map { signedDocuments[$0.section] ?? $0 }
        if chosen.isEmpty { if action == .close { onFinish?(); onClose() }; return }
        guard let onApprove else { if action == .close { onClose() }; return }
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                // Revalidate the full selected subset even when its files were previously archived.
                _ = try await onApprove(chosen)
                for document in chosen where storedFiles[document.section] == nil {
                    let directory = FileManager.default.temporaryDirectory.appending(path: "OpenPEP-Delivery-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    let safeTitle = String(document.title.map { "/:\n\r".contains($0) ? "-" : $0 }.prefix(100))
                    let file = directory.appending(path: safeTitle + ".pdf")
                    try document.data.write(to: file, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    storedFiles[document.section] = file
                }
                switch action {
                case .close: onFinish?(); onClose()
                case .print:
                    guard let data = Self.combinedPDF(chosen), let pdf = PDFDocument(data: data),
                          let operation = pdf.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
                        throw ConsultationFieldsError.emptyDocument
                    }
                    operation.showsPrintPanel = true; operation.run()
                case .send:
                    delivery = DocumentDelivery(files: chosen.compactMap { storedFiles[$0.section] })
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
