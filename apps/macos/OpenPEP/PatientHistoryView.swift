// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import QuickLook

struct PatientHistoryContext: Identifiable, Sendable {
    let patientID: String
    let patientName: String
    let vaultURL: URL
    let authorizationURL: URL
    var insertionEncounter: EncounterSummary? = nil
    var id: String { patientID }
}

struct ClinicalFormattedText: View {
    let text: String
    var body: some View {
        Text(ClinicalTextPresentation.clean(text))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}

private struct PatientHistoryVerticalContainer<Content: View>: View {
    let isEmbedded: Bool
    let content: Content

    init(isEmbedded: Bool, @ViewBuilder content: () -> Content) {
        self.isEmbedded = isEmbedded
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if isEmbedded { content }
        else { ScrollView { content } }
    }
}

private struct PatientHistoryFrame: ViewModifier {
    let isEmbedded: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isEmbedded { content }
        else { content.frame(minWidth: 740, idealWidth: 1050, minHeight: 650, idealHeight: 820) }
    }
}

struct PatientHistoryView: View {
    let context: PatientHistoryContext
    let onOpen: (PatientHistoryEntry) -> Void
    let onClose: () -> Void
    var onAccept: ((PatientAIAnswer, String) throws -> Void)? = nil
    var isEmbedded = false
    var patientRevision: PatientSummary? = nil
    var onScrollTo: ((String) -> Void)? = nil
    var onExportEncounter: ((String) -> Void)? = nil
    @State private var showsWiki = false
    @State private var snapshot: PatientHistorySnapshot?
    @State private var presentedText: [String: String] = [:]
    @State private var query = ""
    @State private var kind = "all"
    @State private var dateFilter = false
    @State private var showsFilters = false
    @State private var showsAssistant = false
    @State private var fromDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var error: String?
    @State private var isLoading = false
    @State private var selected = Set<String>()
    @State private var question = ""
    @State private var answers: [(source: PatientHistoryEntry, text: String)] = []
    @State private var summaryTask: Task<Void, Never>?
    @State private var progress: String?
    @State private var availability: ConsultationSummaryAvailability?
    @State private var refreshID = UUID()
    @State private var quickPreviewURL: URL?
    @State private var previewAccess = false
    @State private var textSize: Double = 13
    @State private var previewDocument: PreparedClinicalDocument?
    @State private var summaryNote: String?
    @State private var askedQuestion = ""
    @State private var textPreview: PatientHistoryEntry?
    @State private var expandedEntries = Set<String>()
    @State private var delivery: DocumentDelivery?
    @State private var deliveryPatient: PatientSummary?
    @State private var reissueSnapshot: ConsultationReviewSnapshot?
    @State private var aiSourcePreview: PatientHistoryEntry?
    @State private var cloudAnswer: PatientAIAnswer?
    @State private var acceptedText = ""
    @State private var useCloud = true
    @AppStorage(AITextSettings.enabledKey) private var allowsText = false

    #if DEBUG
    @State private var previewOnly = false
    static func preview(context: PatientHistoryContext, snapshot: PatientHistorySnapshot) -> Self {
        var view = Self(context: context, onOpen: { _ in }, onClose: {})
        view._snapshot = State(initialValue: snapshot)
        view._presentedText = State(initialValue: snapshot.entries.reduce(into: [:]) { $0[$1.id] = PatientHistoryPresentation.text($1) })
        view._previewOnly = State(initialValue: true)
        return view
    }
    #endif

    private var filtered: [PatientHistoryEntry] {
        (snapshot?.entries ?? []).filter { entry in
            !entry.isDraft && !PatientHistoryPresentation.isTechnical(entry) && entry.matches(query) && (kind == "all" || (kind == "documents" ? entry.isDocument : !entry.isDocument))
            && (!dateFilter || entry.date.map {
                $0 >= Calendar.current.startOfDay(for: fromDate)
                && $0 < (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate)) ?? toDate)
            } == true)
        }
    }
    private var sources: [PatientHistoryEntry] {
        (snapshot?.entries ?? []).filter { selected.contains($0.id) && $0.issue == nil && !$0.text.isEmpty }
    }

    private var historyGroups: [(date: Date, entries: [PatientHistoryEntry])] {
        Dictionary(grouping: filtered, by: historyDay(for:)).map { (date: $0.key, entries: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    historyTitle
                    Spacer()
                    headerActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    historyTitle
                    headerActions
                }
            }.padding(20)
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { historySearchField; historyKindPicker }
                    VStack(alignment: .leading, spacing: 8) { historySearchField; historyKindPicker }
                }
                DisclosureGroup("Opções de leitura", isExpanded: $showsFilters) {
                    VStack(alignment: .leading, spacing: 10) {
                        periodControls
                        textSizeControls
                    }
                    .padding(.top, 4)
                }
                resultCount
            }.padding(.horizontal, 20).padding(.bottom, 14).disabled(progress != nil)
            Divider()
            ScrollViewReader { reader in
                PatientHistoryVerticalContainer(isEmbedded: isEmbedded) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if isLoading { ProgressView("Lendo e verificando consultas e documentos…") }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !isLoading && filtered.isEmpty {
                            ContentUnavailableView("Nenhum registro encontrado", systemImage: "magnifyingglass",
                                description: Text("Altere a busca ou o período. A pesquisa não depende da IA."))
                        }
                        if let answer = cloudAnswer {
                            GroupBox("Proposta · " + answer.result.model) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(askedQuestion).font(.headline)
                                    Text("Informações dos registros e sugestões do modelo devem ser distinguidas no texto. Não houve pesquisa de literatura externa.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    TextEditor(text: $acceptedText).frame(minHeight: 180).disabled(progress != nil)
                                        .accessibilityLabel("Resposta editável da IA")
                                    DisclosureGroup("Fontes usadas") {
                                        ForEach(Array(answer.entries.enumerated()), id: \.offset) { index, entry in
                                            Button("[F\(index + 1)] \(entry.title) · \(entry.displayDate) · \(entry.status)") { aiSourcePreview = entry }
                                        }
                                    }
                                    Button("Descartar proposta") { cloudAnswer = nil; acceptedText = "" }
                                        .disabled(progress != nil)
                                    if context.insertionEncounter != nil, onAccept != nil {
                                        Button("Aceitar e inserir no rascunho") { acceptAnswer() }
                                            .disabled(progress != nil || acceptedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }.padding(12)
                            }
                        }
                        if !answers.isEmpty {
                            GroupBox("Apple Intelligence · proposta para revisão") {
                                VStack(alignment: .leading, spacing: 14) {
                                    if !askedQuestion.isEmpty { Text("Pergunta: " + askedQuestion).font(.headline) }
                                    if let summaryNote { Text(summaryNote).font(.callout).foregroundStyle(.secondary) }
                                    Text("Confira as fontes. Este resultado não foi inserido na nota e pode conter erros.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                                        Button("\(answer.source.title) · \(answer.source.displayDate)") {
                                            withAnimation {
                                                if let onScrollTo { onScrollTo(answer.source.id) }
                                                else { reader.scrollTo(answer.source.id, anchor: .top) }
                                            }
                                        }
                                        ClinicalFormattedText(text: answer.text)
                                        Text(answer.source.source).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }.padding(12)
                            }.id("summary")
                        }
                        ForEach(historyGroups, id: \.date) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    historyEntry(entry).id(entry.id)
                                }
                            } header: {
                                historyDayTitle(group.date)
                            }
                        }
                    }.padding(20)
                }
                .onChange(of: answers.count) { _, count in
                    guard count > 0 else { return }
                    if let onScrollTo { onScrollTo("summary") }
                    else { reader.scrollTo("summary", anchor: .top) }
                }
            }
            Divider()
            DisclosureGroup("Consultar registros com IA", isExpanded: $showsAssistant) {
                aiControls.padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .disabled(progress != nil)
        }
        .modifier(PatientHistoryFrame(isEmbedded: isEmbedded))
        .task(id: refreshID) {
            #if DEBUG
            if previewOnly { return }
            #endif
            await load()
        }
        .onChange(of: patientRevision) { _, _ in
            if progress == nil, cloudAnswer == nil, answers.isEmpty { refreshID = UUID() }
        }
        .onDisappear { summaryTask?.cancel() }
        .sheet(isPresented: $showsWiki) {
            PatientWikiBrowser(context: context, onClose: { showsWiki = false })
        }
        .sheet(item: $aiSourcePreview) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text("Fonte usada na resposta · " + entry.title).font(.headline)
                Text(entry.displayDate + " · " + entry.status).font(.caption)
                ScrollView { ClinicalFormattedText(text: entry.text) }
                Button("Fechar fonte") { aiSourcePreview = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(minWidth: 600, minHeight: 450)
        }
        .overlay {
            if let entry = textPreview {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { textPreview = nil }
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).font(.title2.weight(.semibold))
                                    Text(entry.displayDate).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Fechar", systemImage: "xmark") { textPreview = nil }
                                    .labelStyle(.iconOnly).buttonStyle(.plain).keyboardShortcut(.cancelAction)
                            }
                            Divider()
                            ScrollView { ClinicalFormattedText(text: PatientHistoryPresentation.text(entry))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        }
                        .padding(24)
                        .frame(width: max(280, min(780, geometry.size.width - 48)), height: max(240, geometry.size.height - 64))
                        .background(.background, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(radius: 20).onTapGesture { }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.ignoresSafeArea()
            }
        }
        .sheet(item: $delivery) { delivery in
            DocumentDeliveryView(files: delivery.files, patient: deliveryPatient,
                onClose: { self.delivery = nil }, onCompleted: { self.delivery = nil })
        }
        .sheet(item: $reissueSnapshot) { snapshot in
            ConsultationDocumentReviewView(documents: snapshot.documents,
                onEdit: { _ in reissueSnapshot = nil }, onClose: { reissueSnapshot = nil },
                onApprove: { documents in try archiveReissued(documents) },
                onFinish: { reissueSnapshot = nil; refreshID = UUID() }, deliveryPatient: deliveryPatient, allowsEditing: false)
        }
        .quickLookPreview($quickPreviewURL)
        .onChange(of: quickPreviewURL) { _, value in
            if value == nil { releasePreview() }
        }
        .onDisappear { releasePreview() }
        .sheet(item: $previewDocument) { document in
            PreparedDocumentView(document: document, onClose: { previewDocument = nil })
        }
    }

    private var historyTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEmbedded ? "Linha do tempo" : "Histórico do paciente")
                .font(.title2.weight(.semibold))
            Text(snapshot?.patientName ?? context.patientName)
                .foregroundStyle(.secondary)
        }
    }

    private var headerActions: some View {
        HStack {
            Button("Wiki", systemImage: "book.closed") { showsWiki = true }
            Button("Atualizar", systemImage: "arrow.clockwise") { refreshID = UUID() }
                .disabled(isLoading || progress != nil || cloudAnswer != nil)
            if !isEmbedded {
                Button("Fechar", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
    }

    private var historySearchField: some View {
        TextField("Buscar no histórico", text: $query).searchClearButton($query)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Pesquisar no histórico deste paciente")
    }

    private var historyKindPicker: some View {
        Picker("Mostrar", selection: $kind) {
            Text("Tudo").tag("all")
            Text("Consultas").tag("encounters")
            Text("Documentos").tag("documents")
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder private var periodControls: some View {
        Toggle("Filtrar período", isOn: $dateFilter)
        if dateFilter {
            ViewThatFits(in: .horizontal) {
                HStack { DatePicker("De", selection: $fromDate, displayedComponents: .date); DatePicker("Até", selection: $toDate, displayedComponents: .date) }
                VStack(alignment: .leading) { DatePicker("De", selection: $fromDate, displayedComponents: .date); DatePicker("Até", selection: $toDate, displayedComponents: .date) }
            }
        }
    }

    private var textSizeControls: some View {
        HStack {
            Text("Texto").font(.caption)
            Slider(value: $textSize, in: 13...26)
                .frame(width: 90)
                .accessibilityLabel("Tamanho do texto do histórico")
        }
    }

    private var resultCount: some View {
        Text("\(filtered.count) registros")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var questionField: some View {
        TextField("Pergunte sobre este paciente ou peça um texto…", text: $question)
            .textFieldStyle(.roundedBorder)
            .disabled(progress != nil)
    }

    private var aiPicker: some View {
        Picker("IA", selection: $useCloud) {
            Text("OpenAI").tag(true)
            Text("Apple local").tag(false)
        }
        .frame(width: 160)
        .disabled(progress != nil)
    }

    private var summarizeButton: some View {
        Button(question.isEmpty ? "Resumir" : "Perguntar", systemImage: "sparkles", action: summarize)
            .disabled(cloudAnswer != nil || sources.isEmpty || progress != nil ||
                      (useCloud ? !allowsText : availability != .ready) || isLoading)
    }

    private var aiControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Fontes para a consulta").font(.callout.weight(.medium))
                    Spacer()
                    selectionActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fontes para a consulta").font(.callout.weight(.medium))
                    selectionActions
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { questionField; aiPicker; summarizeButton }
                VStack(alignment: .leading, spacing: 8) {
                    questionField
                    HStack { aiPicker; summarizeButton }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    aiStatus
                    Spacer()
                    sourceCount
                }
                VStack(alignment: .leading, spacing: 6) {
                    aiStatus
                    sourceCount
                }
            }
        }
    }

    private var selectionActions: some View {
        HStack {
            Button("Usar resultados") {
                selected = Set(filtered.filter { $0.issue == nil && !$0.text.isEmpty }.map(\.id))
            }
            Button("Limpar") { selected = [] }
                .disabled(selected.isEmpty)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func historyDayTitle(_ day: Date) -> some View {
        if day == .distantPast {
            Label("Data não confirmada", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "pt_BR"))))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func historyDay(for entry: PatientHistoryEntry) -> Date {
        guard let date = entry.date else { return .distantPast }
        return Calendar.current.startOfDay(for: date)
    }

    private func historyEntry(_ entry: PatientHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    entryTitle(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    entryActions(entry)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let issue = entry.issue {
                    Label(issue, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !entry.text.isEmpty {
                    let text = presentedText[entry.id] ?? ""
                    let expanded = expandedEntries.contains(entry.id)
                    Text(expanded ? text : PatientHistoryPresentation.preview(text))
                        .font(.system(size: textSize)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped().textSelection(.disabled)
                    Button(expanded ? "Ver menos" : "Ver mais…", systemImage: expanded ? "chevron.up" : "chevron.down") {
                        if expanded { expandedEntries.remove(entry.id) } else { expandedEntries.insert(entry.id) }
                    }.buttonStyle(.borderless).font(.callout)
                }

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func entryTitle(_ entry: PatientHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.system(size: textSize + 2, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.title)
            Text([entry.date?.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))), entry.status.hasPrefix("Documento guardado") ? nil : entry.status]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func entryActions(_ entry: PatientHistoryEntry) -> some View {
        HStack {
            if entry.isDocument, let type = entry.mediaType, !type.hasPrefix("text/") {
                Button("Visualização rápida", systemImage: "eye") { quickLook(entry) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Visualizar arquivo original")
            }
            Menu {
                if entry.isDocument {
                    Button("Reenviar", systemImage: "paperplane") { resend(entry) }
                    if PatientHistoryPresentation.canReissue(entry) {
                        Button("Reemitir", systemImage: "doc.badge.plus") { reissue(entry) }
                    }
                    Button("Ver arquivo original") { openEntry(entry) }
                    Divider()
                }
                Button("Copiar texto", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PatientHistoryPresentation.text(entry), forType: .string)
                }.disabled(entry.text.isEmpty)
                Toggle("Usar como fonte para IA", isOn: Binding(get: { selected.contains(entry.id) }, set: {
                    if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) }
                }))
                .disabled(entry.issue != nil || entry.text.isEmpty || progress != nil)
                if entry.id.hasPrefix("enc_"), let onExportEncounter {
                    Divider()
                    Button("Exportar consulta…", systemImage: "square.and.arrow.up") { onExportEncounter(entry.id) }
                        .disabled(entry.issue != nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Mais ações para \(entry.title)")
        }
    }

    @ViewBuilder private var aiStatus: some View {
        if let progress {
            HStack {
                ProgressView(progress).controlSize(.small)
                Button("Cancelar") {
                    summaryTask?.cancel()
                    summaryNote = "Resumo cancelado. Os resultados acima cobrem apenas as fontes já processadas."
                }
            }
        } else {
            Text(useCloud ? (allowsText ? "Consultas finalizadas e documentos do paciente; a seleção de fontes é opcional." : "Ative IA de texto em Configurações. Leitura e busca continuam disponíveis.") : availabilityMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceCount: some View {
        Text("\(sources.count) fontes disponíveis para IA")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var availabilityMessage: String {
        switch availability {
        case .ready: "Processamento local. Selecione as fontes e confira o resultado; nada é salvo automaticamente."
        case .appleIntelligenceNotEnabled: "Ative Apple Intelligence nos Ajustes do Sistema para usar os resumos."
        case .deviceNotEligible: "Apple Intelligence indisponível neste Mac. Leitura e busca por texto continuam disponíveis."
        case .localeUnsupported: "O modelo disponível não oferece suporte ao português do Brasil."
        default: "Modelo local ainda indisponível. Leitura e pesquisa continuam funcionando."
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        answers = []
        cloudAnswer = nil
        selected = []
        defer { isLoading = false }
        do {
            let context = context
            let task = Task.detached(priority: .userInitiated) {
                let snapshot = try PatientHistoryReader().load(patientID: context.patientID, vaultURL: context.vaultURL,
                                                authorizationURL: context.authorizationURL, includeDrafts: false)
                let text = snapshot.entries.reduce(into: [String: String]()) { result, entry in
                    result[entry.id] = PatientHistoryPresentation.text(entry)
                }
                return (snapshot, text)
            }
            let (result, text) = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            presentedText = text
            snapshot = result
            selected = Set(result.entries.filter { $0.issue == nil && !$0.text.isEmpty }.map(\.id))
            availability = await ConsultationSummaryService().availability()
        } catch is CancellationError {} catch { snapshot = nil; self.error = error.localizedDescription }
    }

    private func summarize() {
        if useCloud { askCloud(); return }
        let sources = sources
        guard sources.count <= 30, sources.reduce(0, { $0 + $1.text.count }) <= 100_000, question.count <= 300 else {
            error = "Selecione até 30 fontes e 100 mil caracteres; use uma pergunta de até 300 caracteres. Refine a busca ou o período."
            return
        }
        answers = []
        summaryNote = nil
        askedQuestion = question
        error = nil
        progress = "Preparando resumo local…"
        let question = question
        summaryTask = Task { @MainActor in
            defer { summaryTask = nil; progress = nil }
            do {
                let service = ConsultationSummaryService(engine: ApplePatientHistoryEngine(question: question))
                for (index, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    progress = "Lendo fonte \(index + 1) de \(sources.count)…"
                    let proposal = try await service.propose(from: "Fonte: \(source.title)\nData: \(source.timestamp)\nEstado: \(source.status)\n\n\(source.text)")
                    try Task.checkCancellation()
                    answers.append((source, proposal.text))
                }
                progress = nil
            } catch is CancellationError {
                // A cancelled older task must not clear a newer task's progress.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Resumo não concluído: \(error.localizedDescription)"
                summaryNote = "Resultado parcial: nem todas as fontes selecionadas foram processadas."
                progress = nil
            }
        }
    }
    private func askCloud() {
        guard summaryTask == nil else { return }
        guard question.count <= 4_000 else {
            error = "Use uma pergunta de até 4.000 caracteres. Nenhum texto foi enviado."
            return
        }
        let context = context, question = question, selected = selected
        progress = "Lendo fontes e preparando resposta…"
        error = nil
        summaryTask = Task { @MainActor in
            defer { summaryTask = nil; progress = nil }
            do {
                let response = try await PatientQuestionService().answer(question: question, context: context, selected: selected)
                cloudAnswer = response
                acceptedText = response.result.text
                askedQuestion = question
                answers = []
            } catch is CancellationError { error = "Pergunta cancelada. O texto anterior foi mantido." }
            catch { self.error = error.localizedDescription }
        }
    }

    private func acceptAnswer() {
        guard let cloudAnswer, let onAccept, summaryTask == nil else { return }
        do {
            try onAccept(cloudAnswer, acceptedText)
            self.cloudAnswer = nil
            acceptedText = ""
        } catch { self.error = error.localizedDescription }
    }

    private func resend(_ entry: PatientHistoryEntry) {
        do {
            let result = try PatientDocumentReuse.resend(entry: entry, context: context)
            deliveryPatient = result.patient
            delivery = DocumentDelivery(files: [result.file])
        } catch { self.error = error.localizedDescription }
    }
    private func reissue(_ entry: PatientHistoryEntry) {
        do {
            let result = try PatientDocumentReuse.reissue(entry: entry, context: context)
            deliveryPatient = result.patient
            reissueSnapshot = ConsultationReviewSnapshot(documents: [result.document])
        } catch { self.error = error.localizedDescription }
    }
    private func archiveReissued(_ documents: [ConsultationDocumentPreview]) throws -> [URL] {
        guard let expected = reissueSnapshot?.documents, DocumentReviewSelection.matches(documents, current: expected) else { throw ConsultationFieldsError.ambiguous }
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(context.vaultURL)
        guard vault.writingAllowed, let patient = vault.patients.first(where: { $0.patientID == context.patientID }),
              !patient.isArchived, patient.record == deliveryPatient?.record,
              documents.allSatisfy({ $0.prepared.doctorIdentity == DoctorProfileStore.load().documentIdentity }) else { throw ConsultationFieldsError.ambiguous }
        return try documents.map {
            try ClinicalDocumentArchiver().archive($0.prepared, patient: patient, encounterID: nil,
                deviceID: vault.manifest.deviceID, expectedVaultID: vault.manifest.vaultID).pdf.originalURL
        }
    }

    private func releasePreview() {
        if previewAccess { context.authorizationURL.stopAccessingSecurityScopedResource(); previewAccess = false }
    }

    private func quickLook(_ entry: PatientHistoryEntry) {
        guard let assetID = entry.assetID else { return }
        releasePreview()
        previewAccess = context.authorizationURL.startAccessingSecurityScopedResource()
        do {
            quickPreviewURL = try RawAssetDocumentResolver().resolvePreview(patientID: context.patientID,
                assetID: assetID, in: context.vaultURL)
        } catch { releasePreview(); self.error = error.localizedDescription }
    }

    private func openEntry(_ entry: PatientHistoryEntry) {
        guard let assetID = entry.assetID else { textPreview = entry; return }
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            let asset = try RawAssetDocumentResolver().resolve(patientID: context.patientID, assetID: assetID, in: context.vaultURL)
            if asset.mediaType == "application/pdf" {
                previewDocument = try PreparedClinicalDocument(title: asset.originalName,
                    data: try PatientHistoryReader.verifiedData(asset))
            } else if !entry.text.isEmpty { textPreview = entry }
            else { onOpen(entry) }
        } catch { self.error = error.localizedDescription }
    }

}

/// Presentation only: source artifacts remain available to provenance verification.
enum PatientHistoryPresentation {
    static func isTechnical(_ entry: PatientHistoryEntry) -> Bool {
        entry.isDocument && entry.title.hasPrefix("openpep-progressive-summary-source-")
            && entry.text.hasPrefix("Fonte de resumo progressivo aceita")
    }
    static func preview(_ text: String) -> String {
        let head = String(text.prefix(1200))
        return head + (head.count < text.count ? "…" : "")
    }
    static func canReissue(_ entry: PatientHistoryEntry) -> Bool {
        entry.isDocument && entry.issue == nil
            && ["Documento avulso", "Documento da consulta"].contains(entry.status)
            && !PatientSearch.normalize(entry.title).contains("atestado")
    }
    static func text(_ entry: PatientHistoryEntry) -> String {
        let body: String
        if !entry.isDocument, let page = try? LinearConsultationPage(body: entry.text) { body = page.consultation }
        else { body = entry.text }
        return ClinicalTextPresentation.clean(body)
    }
}

/// Strip only internal markers; stored notes and their hashes remain untouched.
enum ClinicalTextPresentation {
    static func clean(_ body: String) -> String {
        var text = body
        for pattern in [#"<!-- openpep:prescription-v1 [A-Za-z0-9+/=]+ -->"#, #"(?s)<!--\s*openpep:cmed:.*?-->"#, #"<!--\s*/?openpep:consultation-fields[^>]*-->"#, #"<!--\s*openpep:page-break\s*-->"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: ConsultationFields.start, with: "").replacingOccurrences(of: ConsultationFields.end, with: "")
        return text.components(separatedBy: "\n").map { line in
            var line = line.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "- Texto / comentários: ", with: "")
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            if line == "Receita simples" { return "Receituário" }
            if line == "Receita especial" { return "Receituário Especial" }
            return line
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
