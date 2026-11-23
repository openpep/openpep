// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct CockpitMedicationAssistanceView: View {
    @Binding var medication: CockpitPrescription.Medication
    let catalog: CockpitMedicationCatalog
    let recipeType: String
    var keepsSelection = false
    var showsSearch = true
    var compact = false
    let onSelect: (CockpitMedicationCatalog.Entry) -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var pendingEntry: CockpitMedicationCatalog.Entry?
    @State private var pendingPlan: CockpitMedicationCatalog.Plan?
    @State private var error: String?
    @State private var weight = ""
    @State private var perKg: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsSearch { Button("Escolher medicamento e apresentação…", systemImage: "magnifyingglass") {
                query = medication.nome; searching = true
            }.popover(isPresented: $searching) { search } }
            if let entry = medication.assistance, entry.matches(medication) {
                if !compact { Text("\(CockpitPrescription.names[entry.recipeType] ?? entry.recipeType) · selecionada pela apresentação")
                    .font(.callout).foregroundStyle(.secondary)
                if entry.recipeType != recipeType && medication.recipeOverride == nil {
                    Text("O tipo de receita foi alterado. Volte ao modelo indicado para esta apresentação antes de revisar.").font(.callout).foregroundStyle(.red)
                }
                Picker("Apresentação", selection: Binding(get: { entry.id }, set: { id in
                    if let next = catalog.entries.first(where: { $0.id == id }) { choose(next) }
                })) {
                    ForEach(presentations(entry)) { Text($0.presentation).tag($0.id) }
                } }
                if !entry.plans.isEmpty {
                    Text("Preencher posologia").font(.callout.weight(.semibold))
                    plans(entry)
                } else { Text("Sem atalho para esta apresentação. Preencha a posologia abaixo.").font(.callout).foregroundStyle(.secondary) }
                if let calculator = entry.calculator { weightCalculator(calculator, entry: entry) }
                if !entry.notes.isEmpty {
                    DisclosureGroup("Orientações para incluir") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(entry.notes, id: \.self) { note in
                                HStack(alignment: .top) {
                                    Text(note).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Incluir") { append(note, type: entry.recipeType) }
                                        .accessibilityLabel("Incluir orientação: " + note)
                                }
                            }
                        }.padding(.top, 8)
                    }
                }
                DisclosureGroup("Fonte das sugestões") {
                    Text(entry.publication).font(.caption)
                    ForEach(entry.sources, id: \.self) { source in
                        if let url = URL(string: source), ["https", "http"].contains(url.scheme) {
                            Link(url.host ?? "Consultar fonte", destination: url).font(.caption)
                        }
                    }
                    Text("Sugestões do catálogo para revisão profissional; não avaliam indicação, contraindicação ou ajustes para este paciente.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .onChange(of: [medication.nome, medication.concentracao, medication.forma, medication.unidade]) { _, _ in
            if !keepsSelection, let entry = medication.assistance, !entry.matches(medication) { medication.assistance = nil }
            weight = ""; perKg = nil; error = nil
        }
        .confirmationDialog("Trocar a apresentação e limpar a posologia atual?", isPresented: Binding(get: { pendingEntry != nil }, set: { if !$0 { pendingEntry = nil } }), titleVisibility: .visible) {
            if let entry = pendingEntry { Button("Trocar e preencher novamente") { onSelect(entry); pendingEntry = nil } }
        } message: { Text("A dose e as orientações da apresentação anterior serão removidas. Se cancelar, o texto atual será preservado.") }
        .confirmationDialog("Substituir a posologia atual pela sugestão?", isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } }), titleVisibility: .visible) {
            if let plan = pendingPlan { Button("Usar sugestão") { apply(plan); pendingPlan = nil } }
        } message: { if let plan = pendingPlan { Text(plan.text) } }
    }
    private func presentations(_ current: CockpitMedicationCatalog.Entry) -> [CockpitMedicationCatalog.Entry] {
        var values = catalog.entries.filter { $0.substanceID == current.substanceID }
        if !values.contains(where: { $0.id == current.id }) { values.append(current) }
        return values
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Substância ou nome comercial", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(catalog.search(query, type: recipeType)) { entry in
                        Button { searching = false; choose(entry) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).font(.headline)
                                Text(entry.presentation).font(.callout)
                                Text(CockpitPrescription.names[entry.recipeType] ?? entry.recipeType).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if catalog.search(query, type: recipeType).isEmpty { Text("Nenhuma apresentação neste catálogo. Você pode preencher manualmente ou buscar na CMED.").foregroundStyle(.secondary) }
                }
            }.frame(height: 330)
            Text("Catálogo do Cockpit RX · selecione a apresentação para preencher os campos e o modelo de receita.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 490)
    }
    private func choose(_ entry: CockpitMedicationCatalog.Entry) {
        guard entry.id != medication.assistance?.id else { return }
        if !medication.posologia.isEmpty || !medication.orientacoes.isEmpty || !medication.tempo.isEmpty { pendingEntry = entry }
        else { onSelect(entry) }
    }
    private func plans(_ entry: CockpitMedicationCatalog.Entry) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(entry.plans) { plan in Button(plan.label) { propose(plan) }.help(plan.text).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func propose(_ plan: CockpitMedicationCatalog.Plan) {
        if !medication.posologia.isEmpty, medication.posologia != plan.text { pendingPlan = plan }
        else { apply(plan) }
    }
    private func apply(_ plan: CockpitMedicationCatalog.Plan) {
        medication.apply(plan)
        error = plan.text.contains("__") ? "Complete os espaços __ na posologia antes de revisar." : nil
    }
    private func append(_ note: String, type: String) {
        do { try medication.appendInstruction(note, recipeType: type); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func weightCalculator(_ calculator: CockpitMedicationCatalog.Calculator, entry: CockpitMedicationCatalog.Entry) -> some View {
        DisclosureGroup("Calcular por peso") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Peso em kg", text: $weight).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                if calculator.mgPorUnidade != nil {
                    Picker("Dose proposta (mg/kg/dia)", selection: Binding(get: { perKg ?? calculator.mgKgDia }, set: { perKg = $0 })) {
                        ForEach(calculator.steps, id: \.self) { Text($0.formatted(.number.locale(Locale(identifier: "pt_BR")))).tag($0) }
                    }
                }
                if let kg = Double(weight.replacingOccurrences(of: ",", with: ".")),
                   let result = try? calculator.calculate(weight: kg, perKg: perKg, unit: entry.unit) {
                    Text(result.explanation).font(.callout)
                    Text(result.plan.text).font(.callout).foregroundStyle(.secondary)
                    Button("Usar cálculo na posologia") { propose(result.plan) }
                } else if !weight.isEmpty { Text("Confira o peso e os limites de cálculo da apresentação.").font(.callout).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        }
    }
}
