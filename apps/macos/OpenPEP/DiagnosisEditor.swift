// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

enum BundledDiagnosisCatalog {
    static let result: Result<LocalDiagnosisCatalog, Error> = Result {
        guard let url = Bundle.main.url(forResource: "cid10-br-2008", withExtension: "tsv")
            ?? Bundle.main.url(forResource: "cid10-br-2008", withExtension: "tsv", subdirectory: "Resources") else {
            throw ConsultationFieldsError.invalidCatalog
        }
        return try LocalDiagnosisCatalog(tsv: String(contentsOf: url, encoding: .utf8))
    }
    static func normalizedCode(_ code: String) -> String {
        code.uppercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
    }
    static let codes: Set<String> = Set((try? result.get().entries.map { normalizedCode($0.code) }) ?? [])
}

enum ConsultationDiagnoses {
    /// Explicit codes only; never infer a diagnosis from symptom wording.
    static func suggestions(body: String, patient: PatientSummary?) -> [ConsultationFieldItem] {
        var result: [ConsultationFieldItem] = []
        let text = (try? LinearConsultationPage(body: body).consultation) ?? body
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b[A-Z][0-9]{2}(?:\.?[0-9])?\b"#),
           let catalog = try? BundledDiagnosisCatalog.result.get() {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let code = BundledDiagnosisCatalog.normalizedCode(String(text[range]))
                if let entry = catalog.entries.first(where: { BundledDiagnosisCatalog.normalizedCode($0.code) == code }) {
                    result.append(.init(kind: .diagnosis, values: [.code: entry.code, .title: entry.title, .course: "Não crônico"]))
                }
            }
        }
        for encounter in (patient?.encounters ?? []).sorted(by: { $0.metadata.startedAt > $1.metadata.startedAt }) {
            guard case let .verified(finalization) = encounter.finalizationStatus,
                  let fields = try? ConsultationFields.read(from: finalization.finalNote.body) else { continue }
            result += fields.items.filter { $0.kind == .diagnosis && BundledDiagnosisCatalog.codes.contains(BundledDiagnosisCatalog.normalizedCode($0[.code])) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert(BundledDiagnosisCatalog.normalizedCode($0[.code])).inserted }
    }

    /// Most recent explicit observation wins, including an unchecked chronic checkbox.
    static func chronic(from bodies: [String]) -> [ConsultationFieldItem] {
        var latest: [String: ConsultationFieldItem] = [:]
        for body in bodies {
            guard let fields = try? ConsultationFields.read(from: body) else { continue }
            for item in fields.items where item.kind == .diagnosis {
                let code = BundledDiagnosisCatalog.normalizedCode(item[.code])
                guard BundledDiagnosisCatalog.codes.contains(code) else { continue }
                latest[code] = item
            }
        }
        return latest.values.filter { $0[.course] == "Crônico" }.sorted { $0[.code] < $1[.code] }
    }

    static func chronic(in patient: PatientSummary, excluding encounterID: String? = nil) -> [ConsultationFieldItem] {
        let observations = patient.encounters.filter { $0.metadata.encounterID != encounterID }
            .flatMap { encounter -> [(date: String, id: String, body: String)] in
                guard case let .verified(finalization) = encounter.finalizationStatus else { return [] }
                return [(finalization.finalNote.metadata.finalizedAt, encounter.metadata.encounterID, finalization.finalNote.body)]
                    + finalization.addenda.map { ($0.metadata.createdAt, $0.metadata.addendumID, $0.body) }
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let bodies = observations.map(\.body)
        return chronic(from: bodies)
    }

    static func carryingChronic(into body: String, patient: PatientSummary, encounterID: String) throws -> String {
        var fields = try ConsultationFields.read(from: body)
        guard !fields.items.contains(where: { $0.kind == .diagnosis }) else { return body }
        fields.items.insert(contentsOf: chronic(in: patient, excluding: encounterID), at: 0)
        return try fields.replacing(in: body)
    }
}

struct DiagnosisEditor: View {
    @Binding var bodyText: String
    var previousPatient: PatientSummary? = nil
    @State private var query = ""
    @State private var showsSearch = false
    @State private var commentCode: String?
    @FocusState private var searchFocused: Bool
    @State private var error: String?
    private var diagnoses: [ConsultationFieldItem] {
        ((try? ConsultationFields.read(from: bodyText).items) ?? []).filter { $0.kind == .diagnosis }
    }
    private var matches: [LocalDiagnosisCatalog.Entry] {
        let selected = Set(diagnoses.map { BundledDiagnosisCatalog.normalizedCode($0[.code]) })
        return ((try? BundledDiagnosisCatalog.result.get().search(query)) ?? [])
            .filter { !selected.contains(BundledDiagnosisCatalog.normalizedCode($0.code)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Diagnósticos").font(.headline)
                Spacer()
                Button(showsSearch ? "Concluir" : "Adicionar", systemImage: showsSearch ? "checkmark" : "plus") {
                    showsSearch.toggle()
                    searchFocused = showsSearch
                }.buttonStyle(.borderless)
            }
            let suggestions = ConsultationDiagnoses.suggestions(body: bodyText, patient: previousPatient)
                .filter { item in !diagnoses.contains { BundledDiagnosisCatalog.normalizedCode($0[.code]) == BundledDiagnosisCatalog.normalizedCode(item[.code]) } }
            if !suggestions.isEmpty {
                Menu("Do rascunho e de consultas anteriores", systemImage: "clock.arrow.circlepath") {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                        Button(item[.code] + " · " + item[.title]) {
                            edit { $0.append(item) }
                        }
                    }
                }
            }
            if !diagnoses.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(diagnoses.enumerated()), id: \.offset) { index, item in
                        diagnosisCard(item, index: index)
                    }
                }
            }
            if showsSearch {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Buscar por código CID-10 ou descrição", text: $query).searchClearButton($query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Buscar novo diagnóstico por código CID-10 ou descrição")
                        .onSubmit { if let first = matches.first { add(first) } }
                    if !query.isEmpty {
                        Button("Limpar busca", systemImage: "xmark.circle.fill") { query = ""; searchFocused = true }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }.padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 2 : 1))
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                }
                Label("CID-10 Brasil · edição 2008 · busca offline", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Crônicos de consultas finalizadas são recuperados automaticamente. Desmarque Crônico quando deixar de se aplicar. A edição histórica não inclui códigos posteriores a 2008.")
            }
            }
            if case .failure = BundledDiagnosisCatalog.result {
                Label("O catálogo CID-10 não pôde ser carregado. Reabra ou reinstale o app.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .onAppear { if diagnoses.isEmpty { showsSearch = true } }
    }

    private func diagnosisCard(_ item: ConsultationFieldItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(item[.code].isEmpty ? "Sem CID" : item[.code])
                    .font(.body.monospaced().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Text(item[.title]).font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                Toggle("Crônico", isOn: Binding(get: { item[.course] == "Crônico" }, set: { value in
                    change(index) { $0[.course] = value ? "Crônico" : "Não crônico" }
                })).toggleStyle(.checkbox).fixedSize().padding(.top, 4)
                    .accessibilityLabel("Diagnóstico \(item[.code]) crônico")
                Button("Comentário", systemImage: item[.detail].isEmpty ? "text.bubble" : "text.bubble.fill") {
                    commentCode = item[.code]
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 28, height: 28)
                .accessibilityLabel("Comentário do diagnóstico \(item[.code])")
                .help(item[.detail].isEmpty ? "Adicionar comentário" : item[.detail])
                .popover(isPresented: Binding(get: { commentCode == item[.code] }, set: { if !$0 { commentCode = nil } })) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Comentário · \(item[.code])").font(.headline)
                        TextField("Acrescente detalhes, se necessário", text: Binding(get: { item[.detail] }, set: { value in
                            change(index) { $0[.detail] = value }
                        }), axis: .vertical).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Comentário opcional do diagnóstico \(item[.code])")
                        Button("Concluir") { commentCode = nil }
                    }.padding(16).frame(width: 320)
                }
                Button("Remover", systemImage: "minus.circle") { remove(index) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 28, height: 28)
                    .accessibilityLabel("Remover diagnóstico \(item[.code])")
                    .help("Remover este diagnóstico da consulta")
            }

        }.padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resultados da busca").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if matches.isEmpty {
                Text("Nenhum código encontrado ou os resultados já foram incluídos.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { entry in
                            Button { add(entry) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(entry.code).fontWeight(.semibold).frame(width: 62, alignment: .leading)
                                    Text(entry.title).multilineTextAlignment(.leading)
                                    Spacer()
                                    Label("Adicionar", systemImage: "plus.circle").font(.callout).foregroundStyle(Color.accentColor)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Adicionar diagnóstico \(entry.code), \(entry.title)")
                            Divider()
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }
    }
    private func edit(_ transform: (inout [ConsultationFieldItem]) -> Void) {
        do {
            var fields = try ConsultationFields.read(from: bodyText)
            var items = fields.items.filter { $0.kind == .diagnosis }
            transform(&items)
            fields.items.removeAll { $0.kind == .diagnosis }
            fields.items.insert(contentsOf: items, at: 0)
            bodyText = try fields.replacing(in: bodyText)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func add(_ entry: LocalDiagnosisCatalog.Entry) {
        edit { items in
            guard !items.contains(where: { BundledDiagnosisCatalog.normalizedCode($0[.code]) == BundledDiagnosisCatalog.normalizedCode(entry.code) }) else { return }
            items.append(ConsultationFieldItem(kind: .diagnosis, values: [.code: entry.code, .title: entry.title, .course: "Não crônico"]))
        }
        query = ""
        searchFocused = true
    }
    private func change(_ index: Int, _ transform: (inout ConsultationFieldItem) -> Void) {
        edit { if $0.indices.contains(index) { transform(&$0[index]) } }
    }
    private func remove(_ index: Int) { edit { if $0.indices.contains(index) { $0.remove(at: index) } } }
}
