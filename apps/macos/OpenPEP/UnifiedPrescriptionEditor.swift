// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct UnifiedPrescriptionEditor: View {
    private static let bundledCatalog = try? CockpitMedicationCatalog.load()
    @Binding var text: String
    let patient: PatientSummary
    let encounterID: String?
    let authorizationURL: URL?
    let onArchive: (PreparedClinicalDocument) throws -> URL
    @State private var composition: UnifiedPrescription?
    @State private var catalog: CockpitMedicationCatalog?
    @State private var error: String?
    @State private var searching: UUID?
    @State private var pendingSelection: (UUID, CockpitMedicationCatalog.Entry)?
    @State private var documents: [CockpitPrescription] = []
    @State private var selectedDocument = 0
    @State private var reviewing = false
    @State private var reviewID = UUID()
    @State private var visited: Set<UUID> = []
    @State private var showsDetails = false
    @State private var lastWritten = ""
    @State private var files: [UUID: URL] = [:]
    @State private var delivering = false
    @State private var emitting = false
    @State private var pending: [SNCRRegistry.Number] = []
    @State private var preparing = false
    @State private var preflightRenderer = CockpitPDFRenderer()

    init(text: Binding<String>, patient: PatientSummary, encounterID: String?, authorizationURL: URL?,
         onArchive: @escaping (PreparedClinicalDocument) throws -> URL) {
        _text = text; self.patient = patient; self.encounterID = encounterID
        self.authorizationURL = authorizationURL; self.onArchive = onArchive
        _composition = State(initialValue: try? UnifiedPrescription(patient: patient, text: text.wrappedValue))
        _catalog = State(initialValue: Self.bundledCatalog)
        _lastWritten = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if reviewing {
                HStack {
                    Button("Voltar à lista", systemImage: "chevron.left") { reviewing = false }.disabled(emitting)
                    Spacer()
                    if !files.isEmpty { Button("Enviar PDFs guardados…") { delivering = true } }
                }
                Text("Receitas organizadas automaticamente").font(.headline)
                Picker("Documento para revisar", selection: $selectedDocument) {
                    ForEach(documents.indices, id: \.self) { index in
                        Text(label(documents[index])).tag(index)
                    }
                }.disabled(emitting)
            }
            // Keep review instances alive while navigating: a reservation or signature is never replayed.
            if !documents.isEmpty {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                    if visited.contains(document.id) { CockpitPrescriptionView(patient: patient, encounterID: encounterID, authorizationURL: authorizationURL,
                        initialDraft: document, onArchive: { prepared in
                            let url = try onArchive(prepared); files[prepared.id] = url; return url
                        }, onClose: { reviewing = false }, embedded: true, onFreeze: { composition?.locked = true }, onReviewError: { message in
                            error = message; reviewing = false; showsDetails = true
                        }, onBusy: { emitting = $0 })
                    .frame(height: reviewing && selectedDocument == index ? nil : 0)
                    .opacity(reviewing && selectedDocument == index ? 1 : 0).clipped()
                    .allowsHitTesting(reviewing && selectedDocument == index)
                    .accessibilityHidden(!reviewing || selectedDocument != index) }
                }.id(reviewID)
            }
            if !reviewing, let composition {
                if composition.text.isEmpty && !pending.isEmpty {
                    Menu("Retomar emissão pendente") {
                        ForEach(pending) { number in
                            Button("\(CockpitPrescription.names[number.type] ?? number.type) · \(number.id)") { resume(number) }
                        }
                    }
                }
                if composition.locked {
                    Text("Esta lista já iniciou a emissão. Continue a revisão para guardar os documentos pendentes.").font(.callout)
                }
                VStack(alignment: .leading, spacing: 22) {
                    if !composition.legacyText.isEmpty {
                        DisclosureGroup("Texto anterior — conferir medicamentos", isExpanded: .constant(true)) {
                            Text(composition.legacyText).textSelection(.enabled)
                            Button("Já incluí os medicamentos na lista") { self.composition?.legacyText = "" }
                        }
                    }
                    ForEach(composition.draft.medications) { medication in medicationRow(medication) }
                    Button("Adicionar medicamento", systemImage: "plus") {
                        self.composition?.draft.medications.append(.init())
                    }.disabled(composition.draft.medications.count >= 100)
                    DisclosureGroup("Dados do paciente e do médico", isExpanded: $showsDetails) { details }
                        .font(.callout)
                }.disabled(composition.locked || preparing)
                HStack {
                    Text("\(composition.draft.medications.count) medicamento(s) · separação automática por receituário")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if preparing { ProgressView("Conferindo documentos…").controlSize(.small) }
                    Button("Revisar receitas") { review() }.buttonStyle(.borderedProminent).disabled(catalog == nil || preparing)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task { loadPending(); if composition == nil { load() }; if catalog == nil { do { catalog = try CockpitMedicationCatalog.load() } catch { self.error = error.localizedDescription } } }
        .onChange(of: selectedDocument) { _, index in
            if documents.indices.contains(index) { visited.insert(documents[index].id) }
        }
        .onChange(of: composition) { _, value in
            guard let value else { return }
            lastWritten = value.text
            if text != lastWritten { text = lastWritten }
        }
        .onChange(of: text) { _, value in
            guard value != lastWritten else { return }
            if composition?.locked == true {
                text = composition?.text ?? value
                error = "A lista já iniciou a emissão. Termine a revisão antes de substituir seu conteúdo."
            } else { load(); documents = []; files = [:]; reviewing = false }
        }
        .sheet(isPresented: $delivering) {
            DocumentDeliveryView(files: files.values.sorted { $0.path < $1.path }, patient: patient,
                onClose: { delivering = false }, onCompleted: { delivering = false })
        }
        .confirmationDialog("Trocar o medicamento e limpar a posologia anterior?", isPresented: Binding(
            get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } }), titleVisibility: .visible) {
                if let (id, entry) = pendingSelection {
                    Button("Trocar medicamento") { choose(entry, id: id); pendingSelection = nil }
                }
            }
    }
    private func loadPending() {
        let granted = authorizationURL?.startAccessingSecurityScopedResource() ?? false
        defer { if granted { authorizationURL?.stopAccessingSecurityScopedResource() } }
        do {
            let root = patient.url.deletingLastPathComponent().deletingLastPathComponent()
            let vault = try VaultReader().open(root)
            let ledger = try SNCRRegistryStore(vaultURL: root, vaultID: vault.manifest.vaultID).read()
            pending = ledger.numbers.filter { $0.state == "reserved" && $0.patientID == patient.patientID && $0.encounterID == encounterID && $0.draft != nil }
        } catch { pending = [] }
    }
    private func resume(_ number: SNCRRegistry.Number) {
        guard composition?.text.isEmpty == true, let draft = number.draft else { return }
        composition?.draft = draft; composition?.locked = true; composition?.resumedDocumentID = draft.id
        documents = [draft]; selectedDocument = 0; reviewID = UUID(); visited = [draft.id]; reviewing = true
    }
    private func load() {
        do { composition = try UnifiedPrescription(patient: patient, text: text); lastWritten = text; error = nil }
        catch { composition = nil; self.error = error.localizedDescription }
    }
    private func label(_ document: CockpitPrescription) -> String {
        let name = CockpitPrescription.names[document.tipo] ?? document.tipo
        return name + " · " + (document.tipo == "SIMPLE" ? "\(document.medications.count) medicamento(s)" : (document.medications.first?.nome ?? ""))
    }
    private func review() {
        guard let composition, let catalog else { return }
        preparing = true; error = nil
        Task { @MainActor in
            defer { preparing = false }
            do {
                let proposed = try await composition.reviewedDocuments(catalog: catalog, renderer: preflightRenderer)
                if !composition.locked {
                    guard self.composition == composition else { throw CockpitError.message("A lista mudou durante a conferência. Revise novamente.") }
                    documents = proposed; files = [:]; selectedDocument = 0; reviewID = UUID(); visited = []
                } else if documents.isEmpty { documents = proposed }
                if documents.indices.contains(selectedDocument) { visited.insert(documents[selectedDocument].id) }
                reviewing = true
            } catch { self.error = error.localizedDescription; showsDetails = true }
        }
    }
    private func medicationBinding(_ id: UUID) -> Binding<CockpitPrescription.Medication> {
        Binding(get: { composition?.draft.medications.first(where: { $0.id == id }) ?? .init(id: id) }, set: { value in
            guard let index = composition?.draft.medications.firstIndex(where: { $0.id == id }) else { return }
            composition?.draft.medications[index] = value
        })
    }
    private func choose(_ entry: CockpitMedicationCatalog.Entry, id: UUID) {
        do { try composition?.choose(entry, for: id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func medicationRow(_ medication: CockpitPrescription.Medication) -> some View {
        let item = medicationBinding(medication.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Medicamento", text: item.nome, axis: .vertical).lineLimit(1...3).font(.title3.weight(.semibold))
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .accessibilityLabel("Medicamento").onSubmit { searching = medication.id }
                        Button("Buscar medicamento e apresentação", systemImage: "magnifyingglass") { searching = medication.id }
                            .labelStyle(.iconOnly).controlSize(.large).help("Buscar medicamento e apresentação")
                            .popover(isPresented: Binding(get: { searching == medication.id }, set: { if !$0 { searching = nil } })) {
                                if let catalog {
                                    UnifiedMedicationSearch(query: medication.nome, catalog: catalog, onAssisted: { entry in
                                        searching = nil
                                        if !medication.posologia.isEmpty, medication.assistance?.id != entry.id { pendingSelection = (medication.id, entry) }
                                        else { choose(entry, id: medication.id) }
                                    }, onCatalog: { entry in
                                        // CMED selection creates a new item; never carry a dose to a different presentation.
                                        var next = CockpitPrescription.Medication(id: medication.id)
                                        next.nome = entry.prescriptionName; next.catalog = entry.metadata
                                        if medication.posologia.isEmpty { item.wrappedValue = next; searching = nil }
                                        else { error = "Adicione o novo medicamento em outra linha para preservar a posologia atual."; searching = nil }
                                    })
                                }
                            }
                    }
                    TextField("Posologia — escreva livremente ou use um atalho abaixo", text: item.posologia, axis: .vertical)
                        .lineLimit(3...12).textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("Posologia")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quantidade").font(.caption).foregroundStyle(.secondary)
                    TextField("Qtd.", text: item.quantidade).textFieldStyle(.roundedBorder).accessibilityLabel("Quantidade")
                    Text(medication.unidade).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if (composition?.draft.medications.count ?? 0) > 1 {
                        Button(role: .destructive) { composition?.draft.medications.removeAll { $0.id == medication.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Remover " + medication.nome)
                    }
                }.frame(width: 95)
            }
            if let catalog {
                CockpitMedicationAssistanceView(medication: item, catalog: catalog,
                    recipeType: medication.recipeOverride ?? medication.assistance?.recipeType ?? "SIMPLE",
                    keepsSelection: true, showsSearch: false, compact: true) { entry in choose(entry, id: medication.id) }
            }
            if !medication.concentracao.isEmpty || !medication.forma.isEmpty {
                Text([medication.concentracao, medication.forma].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Mais opções") {
                Form {
                    Picker("Receituário", selection: Binding(get: { medication.recipeOverride ?? "AUTO" }, set: { item.recipeOverride.wrappedValue = $0 == "AUTO" ? nil : $0 })) {
                        Text("Automático pela apresentação").tag("AUTO")
                        ForEach(["SIMPLE"] + SNCRRegistry.types, id: \.self) { Text(CockpitPrescription.names[$0] ?? $0).tag($0) }
                    }
                    TextField("Concentração", text: item.concentracao)
                    TextField("Forma farmacêutica", text: item.forma)
                    TextField("Unidade", text: item.unidade)
                    if medication.assistance?.recipeType == "NRT" || medication.recipeOverride == "NRT" {
                        TextField("Tempo de tratamento", text: item.tempo)
                        TextField("Outras orientações", text: item.orientacoes)
                    }
                }.frame(maxWidth: 420).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }.font(.callout)
            Divider()
        }
    }
    private func patientField(_ label: String, _ key: WritableKeyPath<CockpitPrescription.Person, String>) -> some View {
        TextField(label, text: Binding(get: { composition?.draft.paciente[keyPath: key] ?? "" }, set: { composition?.draft.paciente[keyPath: key] = $0 }))
            .accessibilityLabel(label)
    }
    private var details: some View {
        Form {
            Section("Paciente") {
                patientField("Nome", \.nome)
                patientField("CPF", \.documento)
                patientField("Nascimento (AAAA-MM-DD)", \.nascimento)
                patientField("Endereço completo", \.endereco)
                patientField("Cidade", \.cidade)
                patientField("UF", \.uf)
                patientField("Sexo (F/M, quando exigido)", \.sexo)
                patientField("Telefone", \.telefone)
                patientField("CID, quando exigido", \.cid)
            }
            Section("Médico e consultório") {
                TextField("Nome do médico", text: draftField(\.prescriber.nome))
                TextField("CPF do médico", text: draftField(\.prescriber.cpf))
                TextField("CRM", text: draftField(\.prescriber.crm))
                TextField("UF do CRM", text: draftField(\.prescriber.uf))
                TextField("Endereço do consultório", text: draftField(\.emitente.endereco))
                TextField("Cidade", text: draftField(\.emitente.cidade))
                TextField("UF", text: draftField(\.emitente.uf))
                TextField("Telefone do consultório", text: draftField(\.emitente.telefone))
                if composition?.draft.medications.contains(where: { ($0.recipeOverride ?? $0.assistance?.recipeType) == "NRT" }) == true {
                    TextField("Especialidade", text: draftField(\.emitente.especialidade))
                    TextField("Cadastro do prescritor de talidomida", text: draftField(\.emitente.cadastro))
                    Toggle("Incluir responsável", isOn: Binding(get: { composition?.draft.includesGuardian ?? false }, set: { composition?.draft.includesGuardian = $0 }))
                    if composition?.draft.includesGuardian == true {
                        TextField("Nome do responsável", text: draftField(\.responsavel.nome))
                        TextField("Documento do responsável", text: draftField(\.responsavel.documento))
                        TextField("Endereço do responsável", text: draftField(\.responsavel.endereco))
                        TextField("Telefone do responsável", text: draftField(\.responsavel.telefone))
                    }
                }
            }
            Text("Ajustes aqui valem para esta emissão. O cadastro permanece como foi salvo.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 560).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
    private func draftField(_ key: WritableKeyPath<CockpitPrescription, String>) -> Binding<String> {
        Binding(get: { composition?.draft[keyPath: key] ?? "" }, set: { composition?.draft[keyPath: key] = $0 })
    }
}

private struct UnifiedMedicationSearch: View {
    @State var query: String
    let catalog: CockpitMedicationCatalog
    let onAssisted: (CockpitMedicationCatalog.Entry) -> Void
    let onCatalog: (MedicationCatalog.Entry) -> Void
    @State private var general: MedicationCatalog?
    @State private var catalogError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Medicamento ou nome comercial", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(catalog.search(query, type: "")) { entry in
                        Button { onAssisted(entry) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(.headline)
                                Text(entry.presentation).font(.callout)
                                Text(CockpitPrescription.names[entry.recipeType] ?? entry.recipeType).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    ForEach(general?.search(query, includesHospital: false) ?? []) { entry in
                        Button { onCatalog(entry) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(.headline)
                                Text(entry.presentation).font(.callout)
                                Text(entry.substance).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if query.count < 2 { Text("Digite pelo menos duas letras para buscar.").foregroundStyle(.secondary) }
                    if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(height: 350)
        }.padding(16).frame(width: 520)
        .task {
            do { general = try await Task.detached { try await MedicationCatalog.load() }.value }
            catch { catalogError = "Catálogo geral indisponível. A busca assistida local continua disponível." }
        }
    }
}
