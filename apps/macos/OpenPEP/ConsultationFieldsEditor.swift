// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ConsultationTextSection: String, CaseIterable, Identifiable {
    case consultation, guidance, prescription, exams, certificate, custom
    static let documentSections: [Self] = [.guidance, .certificate, .prescription, .exams, .custom]
    var id: String { rawValue }
    var label: String {
        switch self {
        case .consultation: "Consulta"
        case .guidance: "Orientações"
        case .prescription: "Receita"
        case .exams: "Exames"
        case .custom: "Personalizado"
        case .certificate: "Atestado"
        }
    }
    var kind: ConsultationFieldKind? {
        switch self {
        case .consultation: nil
        case .guidance: .guidance
        case .prescription: .medication
        case .exams: .exam
        case .custom: .custom
        case .certificate: .certificate
        }
    }
    var initialTemplate: String {
        switch self {
        case .consultation: "Queixa e evolução:\n\nExame:\n\nConduta:\n"
        case .guidance: "Orientações:\n\nRetorno:\n"
        case .prescription: "Prescrevo:\n\n"
        case .exams: "Solicito:\n\n"
        case .custom: "Texto do documento:\n\n"
        case .certificate: ""
        }
    }
}

/// Plain Markdown/text templates are optional conveniences, never automatically persisted clinical facts.
struct ConsultationTextTemplate {
    var text: String
    var title: String = ""

    static func read(_ content: String, section: ConsultationTextSection) throws -> Self {
        guard content.utf8.count <= 300_000 else { throw ConsultationFieldsError.tooLarge }
        if content.contains(ConsultationFields.start) || content.contains(ConsultationFields.end) {
            let page = try LinearConsultationPage(body: content)
            guard let kind = section.kind, let text = page.text(for: kind) else { throw ConsultationFieldsError.emptyDocument }
            return Self(text: text, title: kind == .custom ? page.customTitle : "")
        }
        if section == .custom, content.hasPrefix("# "), let end = content.firstIndex(of: "\n") {
            return Self(
                text: String(content[content.index(after: end)...]).trimmingCharacters(in: .newlines),
                title: String(content[content.index(content.startIndex, offsetBy: 2)..<end]))
        }
        return Self(text: content)
    }

    static func requiresReplacement(currentText: String) -> Bool {
        !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fileText: String { title.isEmpty ? text : "# \(title)\n\n\(text)" }
}

struct ConsultationFieldsEditor: View {
    @Binding var bodyText: String
    let onPrepare: (String, String) async throws -> Void
    var includesConsultation = true
    var patientName = ""
    var initialDocumentSection: ConsultationTextSection = .guidance
    var includesDocuments = true
    var previousPatient: PatientSummary? = nil
    var consultationDate: Date = Date()
    var onDelivered: (() -> Void)? = nil
    var onApprove: (([ConsultationDocumentPreview]) async throws -> [URL])? = nil
    var onFinish: (() -> Void)? = nil
    var cockpitAuthorizationURL: URL? = nil
    var cockpitEncounterID: String? = nil
    var onCockpitArchive: ((PreparedClinicalDocument) throws -> URL)? = nil
    @State private var activePages: [ConsultationTextSection: Int] = [:]
    var consultationMinimumHeight: CGFloat = 420
    @State private var favorites: [DoctorDocumentFavorite] = []
    @State private var error: String?
    @State private var preparing = false
    @State private var templateSection: ConsultationTextSection?
    @State private var templateText = ""
    @State private var templateTitle = ""
    @State private var useByDefault = true
    @State private var confirmsReplacement = false
    @State private var pendingTemplate: (ConsultationTextSection, ConsultationTextTemplate)?
    @State private var expanded: Set<ConsultationTextSection> = []
    @State private var suggestedTitle = ""
    @State private var selectedDocument: ConsultationTextSection = .guidance
    @State private var didSelectInitialDocument = false
    @State private var showsModels = false
    @State private var modelSearch = ""
    @State private var reviewSnapshot: ConsultationReviewSnapshot?
    @State private var deliveryCompleted = false

    #if DEBUG
        static func preview(bodyText: String, section: ConsultationTextSection) -> Self {
            var view = Self(
                bodyText: .constant(bodyText), onPrepare: { _, _ in },
                includesConsultation: false, patientName: "Paciente Sintético", initialDocumentSection: section)
            view._selectedDocument = State(initialValue: section)
            return view
        }
    #endif

    private var customTitle: String { page?.text(for: .custom) == nil ? suggestedTitle : (page?.customTitle ?? "") }
    private var page: LinearConsultationPage? { try? LinearConsultationPage(body: bodyText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if page == nil {
                Label("Os campos antigos precisam de revisão. O texto original está preservado abaixo.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $bodyText).font(.body).frame(minHeight: 320)
                    .accessibilityLabel("Texto original da consulta")
            } else {
                if includesConsultation {
                    textArea(.consultation)
                    DiagnosisEditor(bodyText: $bodyText, previousPatient: previousPatient)
                }
                if !includesConsultation && includesDocuments {
                    documentWorkspace
                } else {
                    ForEach(ConsultationTextSection.allCases.filter { includesDocuments && $0 != .consultation }) { section in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: {
                                    hasContent(section) || expanded.contains(section)
                                },
                                set: { value in
                                    if value || hasContent(section) { expanded.insert(section) } else { expanded.remove(section) }
                                })
                        ) {
                            textArea(section).padding(.horizontal, 12).padding(.bottom, 12)
                        } label: {
                            Text(section.label).font(.headline)
                        }
                        .disclosureGroupStyle(ConsultationDocumentDisclosureStyle(hasContent: hasContent(section)))

                    }
                }

            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
        }
        .disabled(preparing)
        .task {
            if !didSelectInitialDocument {
                selectedDocument = initialDocumentSection; didSelectInitialDocument = true
            }
            restoreTemplates()
            keepFilledSectionsOpen()
        }
        .onChange(of: bodyText) { _, _ in keepFilledSectionsOpen() }
        .sheet(item: $reviewSnapshot, onDismiss: {
            if deliveryCompleted { deliveryCompleted = false; onDelivered?() }
        }) { snapshot in
            ConsultationDocumentReviewView(
                documents: snapshot.documents,
                onEdit: { section in
                    selectedDocument = section
                    reviewSnapshot = nil
                }, onClose: { reviewSnapshot = nil },
                onApprove: onApprove, onFinish: { reviewSnapshot = nil; onFinish?() }, deliveryPatient: previousPatient,
                onDelivered: { deliveryCompleted = true; reviewSnapshot = nil })
        }
        .sheet(isPresented: Binding(get: { templateSection != nil }, set: { if !$0 { templateSection = nil } })) {
            templateEditor
        }
        .confirmationDialog("Substituir o texto deste campo?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button("Substituir texto") {
                if let (section, template) = pendingTemplate { apply(template, to: section) }
                pendingTemplate = nil
            }
            Button("Cancelar", role: .cancel) { pendingTemplate = nil }
        }
    }

    private var documentWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                documentTools(selectedDocument)
                Spacer()
                if selectedDocument != .prescription || onCockpitArchive == nil { Button("Revisar documentos") {
                    openReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ConsultationTextSection.documentSections.contains(where: hasContent)) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(ConsultationTextSection.documentSections) { section in
                        Button {
                            selectedDocument = section
                            showsModels = false
                        } label: {
                            HStack(spacing: 6) {
                                Text(section.label)
                                if hasContent(section) { Circle().frame(width: 5, height: 5) }
                            }
                            .padding(.vertical, 12)
                            .foregroundStyle(selectedDocument == section ? Color.accentColor : .secondary)
                            .overlay(alignment: .bottom) {
                                if selectedDocument == section { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedDocument == section ? .isSelected : [])
                        .accessibilityValue(hasContent(section) ? "Preenchido" : "Em branco")
                    }
                }
            }
            // Keep the fields alive across tabs, including an unfinished certificate form.
            VStack(spacing: 0) {
                ForEach(ConsultationTextSection.documentSections) { section in
                    textArea(section)
                        .frame(height: selectedDocument == section ? nil : 0)
                        .opacity(selectedDocument == section ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(selectedDocument == section)
                        .accessibilityHidden(selectedDocument != section)
                }
            }
        }
    }

    private func openReview() {
        do {
            let documents = try ConsultationDocumentPreview.make(bodyText: bodyText, patientName: patientName,
                professional: DocumentProfessionalSettings.signature, doctorIdentity: DoctorProfileStore.load().documentIdentity)
            if !documents.isEmpty { reviewSnapshot = ConsultationReviewSnapshot(documents: documents) }
        } catch { self.error = error.localizedDescription }
    }

    private func modelsPopover(for section: ConsultationTextSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Buscar modelo", text: $modelSearch).searchClearButton($modelSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Usar modelo padrão") {
                        showsModels = false
                        useDefault(for: section)
                    }
                    ForEach(favorites.filter { modelSearch.isEmpty || $0.title.localizedStandardContains(modelSearch) }) { favorite in
                        Button(favorite.title, systemImage: "star.fill") {
                            showsModels = false
                            do { propose(try ConsultationTextTemplate.read(favorite.markdown, section: section), for: section) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    ForEach(
                        ConsultationExampleTemplates.examples(for: section).filter {
                            modelSearch.isEmpty || $0.name.localizedStandardContains(modelSearch)
                        }
                    ) { example in
                        Button(example.name) {
                            showsModels = false
                            propose(ConsultationTextTemplate(text: example.text), for: section)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 200)
            Divider()
            Button("Criar modelo", systemImage: "plus") {
                showsModels = false
                templateText = ""
                templateTitle = ""
                useByDefault = true
                templateSection = section
            }
            Button("Importar modelo…", systemImage: "square.and.arrow.down") {
                showsModels = false
                loadTemplate(for: section)
            }
        }
        .buttonStyle(.borderless)
        .padding(16).frame(width: 300)
    }

    private func documentTools(_ section: ConsultationTextSection) -> some View {
                HStack {
                    if section == .prescription, let patient = previousPatient {
                        Menu("Repetir receita", systemImage: "clock.arrow.circlepath") {
                            ForEach(PreviousPrescription.from(patient)) { prescription in
                                Button(prescription.label) {
                                    propose(ConsultationTextTemplate(text: prescription.text), for: .prescription)
                                }
                            }
                        }.disabled(PreviousPrescription.from(patient).isEmpty)
                    }
                    Spacer()
                    Button("Meus modelos", systemImage: "chevron.down") {
                        selectedDocument = section
                        showsModels = true
                    }
                    .popover(
                        isPresented: Binding(
                            get: { showsModels && selectedDocument == section },
                            set: { showsModels = $0 })
                    ) { modelsPopover(for: section) }
                    Menu {
                        templateActions(section)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .fixedSize().accessibilityLabel("Mais opções do documento")
                }
    }

    private func textArea(_ section: ConsultationTextSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if section != .consultation && includesConsultation {
                documentTools(section)
            }
            if section == .certificate {
                CertificateWordingEditor(
                    patientName: patientName,
                    diagnoses: page?.fields.items.filter { $0.kind == .diagnosis } ?? [],
                    consultationDate: consultationDate,
                    onGenerate: { text in propose(ConsultationTextTemplate(text: text), for: .certificate) })
            }
            if section == .custom {
                TextField(
                    "Título do documento",
                    text: Binding(
                        get: { customTitle },
                        set: { title in
                            suggestedTitle = title
                            update { try $0.replacing(.custom, text: fullText(.custom), title: title) }
                        })
                ).textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .controlSize(.large)
            }
            if section == .prescription {
                if let patient = previousPatient, let onCockpitArchive {
                    UnifiedPrescriptionEditor(text: Binding(get: { fullText(section) }, set: { value in
                        update { try $0.replacing(.medication, text: value) }
                    }), patient: patient, encounterID: cockpitEncounterID, authorizationURL: cockpitAuthorizationURL, onArchive: onCockpitArchive)
                } else {
                    PrescriptionPageEditor(text: Binding(get: { displayedText(section) }, set: { setText($0, for: section) }))
                        .id("prescription-\(activePages[section, default: 0])")
                }
            } else {
            Text(displayedText(section) + "\n")
                .font(.body).padding(8).hidden().accessibilityHidden(true)
                .frame(
                    maxWidth: .infinity,
                    minHeight: section == .consultation ? consultationMinimumHeight : (includesConsultation ? 100 : 300),
                    alignment: .topLeading
                )
                .overlay {
                    TextEditor(
                        text: Binding(
                            get: { displayedText(section) },
                            set: { value in
                                expanded.insert(section)
                                setText(value, for: section)
                            })
                    )
                    .font(.body)
                    .accessibilityLabel(section.label)
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
                .contextMenu {
                    if section == .consultation { templateActions(section) }
                }
                .shadow(color: .black.opacity(section == .consultation ? 0.05 : 0), radius: 8, y: 3)
            }

            if section != .consultation && !(section == .prescription && onCockpitArchive != nil) { pageControls(section) }
            if section.kind != nil && includesConsultation && !(section == .prescription && onCockpitArchive != nil) {
                HStack {
                    Spacer()
                    Button("Imprimir…", systemImage: "printer") {
                        if onApprove == nil { prepare(section) } else { openReview() }
                    }
                        .help("Revise e aprove os documentos antes de imprimir.")
                        .disabled(preparing || displayedText(section).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

        }
    }

    @ViewBuilder
    private func templateActions(_ section: ConsultationTextSection) -> some View {
        Button("Usar modelo padrão") { useDefault(for: section) }
        Button("Começar do zero") { propose(ConsultationTextTemplate(text: ""), for: section) }
        if section == .exams {
            Button("Pedido com justificativa") {
                propose(ConsultationTextTemplate(text: "Solicito:\n\nJustificativa:\n\n"), for: section)
            }
            Button("Pedido por grupos") {
                propose(ConsultationTextTemplate(text: "Laboratoriais:\n\nImagem:\n\nOutros:\n\n"), for: section)
            }
        }
        if !ConsultationExampleTemplates.examples(for: section).isEmpty {
            Menu("Exemplos para editar") {
                ForEach(ConsultationExampleTemplates.examples(for: section)) { example in
                    Button(example.name) { propose(ConsultationTextTemplate(text: example.text), for: section) }
                }
            }
        }
        Divider()
        Button("Carregar modelo…") { loadTemplate(for: section) }
        Button("Editar / salvar modelo padrão…") {
            templateText = displayedText(section)
            templateTitle = section == .custom ? customTitle : ""
            useByDefault = true
            templateSection = section
        }
        if !favorites.isEmpty {
            Divider()
            ForEach(favorites) { favorite in
                Button(favorite.title) {
                    do { propose(try ConsultationTextTemplate.read(favorite.markdown, section: section), for: section) } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func hasContent(_ section: ConsultationTextSection) -> Bool {
        guard let kind = section.kind else { return false }
        return DocumentPages.split(page?.text(for: kind) ?? "").contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func keepFilledSectionsOpen() {
        for section in ConsultationTextSection.allCases where hasContent(section) { expanded.insert(section) }
    }

    private func displayedText(_ section: ConsultationTextSection) -> String {
        if let kind = section.kind {
            let pages = DocumentPages.split(page?.text(for: kind) ?? "")
            return pages[min(activePages[section, default: 0], pages.count - 1)]
        }
        let text = page?.consultation ?? ""
        return text
    }

    private func fullText(_ section: ConsultationTextSection) -> String {
        section.kind.flatMap { page?.text(for: $0) } ?? ""
    }

    private func setText(_ value: String, for section: ConsultationTextSection) {
        update { page in
            guard let kind = section.kind else { return try page.replacingConsultation(with: value) }
            var pages = DocumentPages.split(page.text(for: kind) ?? "")
            pages[min(activePages[section, default: 0], pages.count - 1)] = value
            return try page.replacing(kind, text: DocumentPages.joining(pages), title: section == .custom ? customTitle : "")
        }
    }

    private func pageControls(_ section: ConsultationTextSection) -> some View {
        let pages = DocumentPages.split(fullText(section))
        return ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(pages.indices, id: \.self) { index in
                    Button { activePages[section] = index } label: {
                        Text("Página \(index + 1)").font(.callout.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(activePages[section, default: 0] == index ? Color.accentColor.opacity(0.12) : .clear,
                                        in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                            .overlay(alignment: .top) {
                                if activePages[section, default: 0] == index { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(activePages[section, default: 0] == index ? Color.accentColor : .secondary)
                    .accessibilityAddTraits(activePages[section, default: 0] == index ? .isSelected : [])
                }
                Button("Nova página", systemImage: "plus") {
                    guard let kind = section.kind else { return }
                    update { try $0.replacing(kind, text: DocumentPages.joining(pages + [""]), title: section == .custom ? customTitle : "") }
                    activePages[section] = pages.count
                }
                if pages.count > 1 && displayedText(section).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Remover página vazia", systemImage: "minus.circle") {
                        var updated = pages
                        updated.remove(at: min(activePages[section, default: 0], pages.count - 1))
                        activePages[section] = 0
                        if let kind = section.kind { update { try $0.replacing(kind, text: DocumentPages.joining(updated), title: section == .custom ? customTitle : "") } }
                    }
                }
            }.padding(.vertical, 6)
        }
    }

    private func update(_ transform: (LinearConsultationPage) throws -> String) {
        do {
            bodyText = try transform(LinearConsultationPage(body: bodyText))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func propose(_ template: ConsultationTextTemplate, for section: ConsultationTextSection) {
        let hasContent = ConsultationTextTemplate.requiresReplacement(currentText: displayedText(section))
        if hasContent {
            pendingTemplate = (section, template)
            confirmsReplacement = true
        } else {
            apply(template, to: section)
        }
    }

    private func apply(_ template: ConsultationTextTemplate, to section: ConsultationTextSection) {
        expanded.insert(section)
        if section == .custom { suggestedTitle = template.title }
        var proposedText = template.text
        if section == .prescription, onCockpitArchive != nil, let patient = previousPatient,
           proposedText.contains(UnifiedPrescription.marker) {
            do { proposedText = try UnifiedPrescription(patient: patient, text: proposedText).proposal(for: patient).text }
            catch { self.error = error.localizedDescription; return }
        }
        update { page in
            if let kind = section.kind {
                var pages = DocumentPages.split(page.text(for: kind) ?? "")
                pages[min(activePages[section, default: 0], pages.count - 1)] = proposedText
                return try page.replacing(kind, text: DocumentPages.joining(pages), title: section == .custom ? template.title : "")
            }
            return try page.replacingConsultation(with: template.text)
        }
    }

    private func prepare(_ section: ConsultationTextSection) {
        guard let kind = section.kind else { return }
        let text = fullText(section)
        let title = section == .custom ? customTitle : kind.documentTitle
        // Only the selected document text is prepared; diagnoses stay internal.
        update { try $0.replacing(kind, text: text, title: section == .custom ? title : "") }
        guard error == nil else { return }
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do { try await onPrepare(title.isEmpty ? "Documento" : title, text) } catch { self.error = error.localizedDescription }
        }
    }

    private func readFile(_ url: URL, section: ConsultationTextSection) throws -> ConsultationTextTemplate {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 300_000 else {
            throw ConsultationFieldsError.tooLarge
        }
        return try ConsultationTextTemplate.read(String(contentsOf: url, encoding: .utf8), section: section)
    }

    private func loadTemplate(for section: ConsultationTextSection) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { propose(try readFile(url, section: section), for: section) } catch { self.error = error.localizedDescription }
    }

    private func useDefault(for section: ConsultationTextSection) {
        do {
            if let bookmark = UserDefaults.standard.data(forKey: "openpep.documents.default." + section.rawValue) {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw ConsultationFieldsError.ambiguous }
                propose(try readFile(url, section: section), for: section)
            } else {
                propose(ConsultationTextTemplate(text: section.initialTemplate), for: section)
            }
        } catch { self.error = "Modelo padrão indisponível. Carregue o arquivo novamente ou escolha Começar do zero." }
    }

    private func restoreTemplates() {
        if let bookmark = UserDefaults.standard.data(forKey: "openpep.documents.library.local-solo") {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                favorites = try DoctorDocumentLibrary.read(url)
            } catch { self.error = "A pasta de favoritos está indisponível. Você ainda pode carregar um modelo avulso." }
        }
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Modelo de \(templateSection?.label.lowercased() ?? "texto")").font(.title2)
            Text("Edite um texto reutilizável, sem nomes nem dados deste paciente.").foregroundStyle(.secondary)
            if templateSection == .custom {
                TextField("Título", text: $templateTitle).textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $templateText).font(.body).frame(minHeight: 260).border(.separator)
                .accessibilityLabel("Texto do modelo")
            Toggle("Lembrar como modelo padrão (aplicar pelo menu)", isOn: $useByDefault)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { templateSection = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar modelo…") {
                    guard let section = templateSection else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Modelo - \(section.label).md"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do {
                        let template = ConsultationTextTemplate(text: templateText, title: templateTitle)
                        try Data(template.fileText.utf8).write(to: url, options: .atomic)
                        if useByDefault {
                            let bookmark = try url.bookmarkData(
                                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                            UserDefaults.standard.set(bookmark, forKey: "openpep.documents.default." + section.rawValue)
                        }
                        templateSection = nil
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(minWidth: 560, idealWidth: 680, minHeight: 450)
    }
}

/// Native disclosure semantics, with the whole header acting as the target.
struct ConsultationDocumentDisclosureStyle: DisclosureGroupStyle {
    let hasContent: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasContent {
                header(configuration).accessibilityElement(children: .combine)
                    .help("Apague todo o conteúdo para poder recolher este documento.")
            } else {
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    header(configuration)
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Aberto" : "Fechado")
                .help("Clique no título ou em qualquer ponto desta faixa.")
            }
            if configuration.isExpanded { configuration.content }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func header(_ configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                .font(.callout.weight(.semibold)).frame(width: 16)
            configuration.label
            Spacer(minLength: 16)
            Text(hasContent ? "Apague o conteúdo para recolher" : (configuration.isExpanded ? "Recolher" : "Abrir"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
