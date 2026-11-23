// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct PrescriptionPageEditor: View {
    @Binding var text: String
    @State private var draft = PrescriptionPage(text: "")
    @State private var query = ""
    @State private var catalog: MedicationCatalog?
    @State private var catalogError: String?
    @State private var loading = false
    @State private var choosing = false
    @State private var changingMode = false
    @State private var includesHospital = false
    @FocusState private var dosageFocus: UUID?
    @State private var pendingFocus: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if draft.legacy {
                Text("Receita existente").font(.headline)
                TextEditor(text: $draft.freeText).frame(minHeight: 280)
                Button("Criar receita estruturada…") { changingMode = true }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { kindPicker; modePicker; Spacer() }
                    VStack(alignment: .leading) { kindPicker; modePicker }
                }
                if draft.compounded {
                    Text("Texto do receituário").font(.headline)
                    TextEditor(text: $draft.freeText).frame(minHeight: 280)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                    ForEach($draft.medications) { $medication in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                TextField("Medicamento", text: $medication.name, axis: .vertical)
                                    .textFieldStyle(.roundedBorder).font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Nome no receituário. A apresentação original permanece nos metadados.")
                                Button(role: .destructive) { draft.medications.removeAll { $0.id == medication.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).help("Remover medicamento")
                            }
                            Text("Posologia").font(.callout).foregroundStyle(.secondary)
                            TextField("Como usar: dose, frequência e duração", text: $medication.dosage, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                                .focused($dosageFocus, equals: medication.id)
                                .accessibilityLabel("Posologia de \(medication.name)")
                        }.padding(18)
                        Divider().padding(.horizontal, 18)
                    }
                    Button("Adicionar medicamento", systemImage: "plus") { choosing = true }
                        .buttonStyle(.borderless).padding(18)
                        .popover(isPresented: $choosing) { medicationSearch }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
                }
            }
        }
        .onAppear { draft = PrescriptionPage(text: text) }
        .onChange(of: choosing) { _, visible in
            if !visible, let id = pendingFocus {
                Task { @MainActor in
                    await Task.yield()
                    dosageFocus = id
                    pendingFocus = nil
                }
            }
        }
        .onChange(of: draft.text) { _, value in if value != text { text = value } }
        .onChange(of: text) { _, value in
            guard value.trimmingCharacters(in: .newlines) != draft.text.trimmingCharacters(in: .newlines) else { return }
            var updated = PrescriptionPage(text: value)
            for index in updated.medications.indices where draft.medications.indices.contains(index) {
                if updated.medications[index].name == draft.medications[index].name && updated.medications[index].metadata == draft.medications[index].metadata {
                    updated.medications[index].id = draft.medications[index].id
                }
            }
            draft = updated
        }
        .confirmationDialog("Substituir o conteúdo desta página?", isPresented: $changingMode) {
            Button("Substituir", role: .destructive) {
                if draft.legacy { draft = PrescriptionPage(text: "") }
                else { draft.compounded.toggle(); draft.medications = []; draft.freeText = "" }
                text = ""
            }
        }
    }
    private var kindPicker: some View {
        Toggle("Receituário Especial", isOn: $draft.special).toggleStyle(.checkbox)
            .fixedSize().accessibilityLabel("Usar receituário especial nesta página")
    }
    private var modePicker: some View {
        Picker("Preenchimento", selection: Binding(get: { draft.compounded }, set: { value in
            if !draft.text.isEmpty { changingMode = true } else { draft.compounded = value }
        })) {
            Text("Medicamentos").tag(false); Text("Texto livre").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
    }
    private var medicationSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Nome, princípio ativo ou apresentação", text: $query).searchClearButton($query).textFieldStyle(.roundedBorder)
            Toggle("Incluir uso hospitalar", isOn: $includesHospital).font(.callout)
            if loading { ProgressView("Carregando CMED…") }
            if let catalogError { Text(catalogError).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(catalog?.search(query, includesHospital: includesHospital) ?? []) { entry in
                        Button {
                            let medication = PrescriptionPage.Medication(name: entry.prescriptionName, dosage: "", metadata: entry.metadata)
                            draft.medications.append(medication)
                            pendingFocus = medication.id
                            choosing = false; query = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.prescriptionName).font(.headline)
                                Text("Apresentação CMED: " + entry.presentation)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(entry.laboratory).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if let catalog, query.count >= 2, catalog.search(query, includesHospital: includesHospital).isEmpty { Text("Nenhum medicamento encontrado.") }
                }
            }.frame(height: 290)
            HStack {
                Text(catalog?.publication ?? "CMED · Anvisa").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Atualizar") { loadCatalog(refresh: true) }.disabled(loading)
            }
        }.padding(16).frame(width: 440)
            .onAppear { if catalog == nil { loadCatalog() } }
    }
    private func loadCatalog(refresh: Bool = false) {
        loading = true; catalogError = nil
        Task {
            do { catalog = try await Task.detached { try await MedicationCatalog.load(refresh: refresh) }.value }
            catch { catalogError = error.localizedDescription }
            loading = false
        }
    }
}
