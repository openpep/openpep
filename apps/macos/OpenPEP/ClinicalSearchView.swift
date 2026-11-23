// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ClinicalSearchView: View {
    let index: ClinicalSearchIndex
    let unavailableCount: Int
    let errorMessage: String?
    let noticeMessage: String?
    let onRebuild: () -> Void
    let onOpen: (ClinicalSearchResult) -> Void
    @Binding var query: String
    @Binding var filter: ClinicalSearchFilter
    @State private var includesSupplementaryFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Buscar no prontuário").font(.largeTitle)
                        Spacer()
                        rebuildButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Buscar no prontuário").font(.largeTitle)
                        rebuildButton
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        queryField
                        filterPicker
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        queryField
                        filterPicker
                    }
                }
                HStack {
                    Toggle("Incluir arquivos de apoio", isOn: $includesSupplementaryFiles).toggleStyle(.checkbox)
                    Spacer()
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help("Busca nas consultas salvas e nos nomes dos documentos. PDFs e imagens não têm busca no conteúdo. Arquivos de apoio incluem fontes de resumos e versões de texto dos PDFs emitidos.")
                        .accessibilityLabel("Busca nas consultas salvas e nos nomes dos documentos; PDFs e imagens sem busca no conteúdo")
                }.font(.callout)
                let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let results = index.search(query, filter: filter, includesSupplementaryFiles: includesSupplementaryFiles)
                if !hasQuery {
                    Text("Mais recentes primeiro")
                        .font(.headline)
                }
                if results.isEmpty {
                    if hasQuery {
                        ContentUnavailableView("Nenhum resultado", systemImage: "magnifyingglass",
                                               description: Text("Tente outro termo, filtro ou atualize a busca para reler os arquivos."))
                    } else {
                        ContentUnavailableView("Nenhum registro", systemImage: "clock",
                                               description: Text("Ainda não há registros deste tipo para mostrar."))
                    }
                } else {
                    if hasQuery {
                        Text(results.count == 1 ? "1 resultado" : "\(results.count) resultados")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(results) { result in
                            Button { onOpen(result) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: result.systemImage).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.headline)
                                        Text("\(result.kind) · \(result.patientName)")
                                        Text(result.context).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.6)))
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(result.kind == "Documento" ? "Abre o documento verificado" : "Abre o registro no prontuário")
                        }
                    }
                }
                if unavailableCount > 0 {
                    Label("Há registros indisponíveis ou consultas com alteração. Consultas alteradas aparecem apenas por metadados; confira o paciente ou as configurações.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityLabel("Erro: \(errorMessage)")
                }
                if let noticeMessage { Text(noticeMessage).foregroundStyle(.secondary) }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Busca")
    }

    private var rebuildButton: some View {
        Button("Atualizar busca", systemImage: "arrow.clockwise", action: onRebuild)
            .accessibilityHint("Relê os arquivos do prontuário e reconstrói os resultados")
    }

    private var queryField: some View {
        TextField("Paciente, texto da consulta ou nome do documento", text: $query).searchClearButton($query)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Buscar no prontuário")
    }

    private var filterPicker: some View {
        Picker("Filtrar", selection: $filter) {
            ForEach(ClinicalSearchFilter.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Filtrar registros da busca")
    }
}
