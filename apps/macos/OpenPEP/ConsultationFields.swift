// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ConsultationFieldKind: String, CaseIterable, Identifiable, Sendable {
    case diagnosis, medication, exam, guidance, custom, certificate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .diagnosis: "Diagnóstico"
        case .medication: "Medicamento"
        case .exam: "Exame"
        case .guidance: "Orientações"
        case .custom: "Documento personalizado"
        case .certificate: "Atestado"
        }
    }
    var documentTitle: String {
        switch self {
        case .medication: "Receituário"
        case .exam: "Solicitação de exames"
        case .guidance: "Orientações ao paciente"
        default: label
        }
    }
    var icon: String {
        switch self {
        case .diagnosis: "stethoscope"
        case .medication: "pills"
        case .exam: "testtube.2"
        case .guidance: "text.bubble"
        case .custom: "doc.text"
        case .certificate: "doc.text.badge.plus"
        }
    }
    var fields: [ConsultationInputField] {
        switch self {
        case .diagnosis: [.title, .code, .course, .certainty, .detail]
        case .medication: [.title, .dose, .route, .frequency, .duration, .quantity, .detail]
        case .exam: [.title, .code, .detail]
        case .guidance, .custom, .certificate: [.title, .detail]
        }
    }
}

enum ConsultationInputField: String, CaseIterable, Sendable {
    case title, code, course, certainty, dose, route, frequency, duration, quantity, detail
    var label: String {
        switch self {
        case .title: "Descrição"
        case .code: "Código"
        case .course: "Curso"
        case .certainty: "Certeza"
        case .dose: "Dose"
        case .route: "Via"
        case .frequency: "Frequência"
        case .duration: "Duração / uso contínuo"
        case .quantity: "Quantidade a dispensar"
        case .detail: "Texto / comentários"
        }
    }
}

struct ConsultationFieldItem: Identifiable, Sendable {
    var id = UUID()
    var kind: ConsultationFieldKind
    var values: [ConsultationInputField: String] = [:]
    subscript(_ field: ConsultationInputField) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }
    var isEmpty: Bool { values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

enum ConsultationFieldsError: LocalizedError {
    case ambiguous, invalidCatalog, emptyDocument, tooLarge
    var errorDescription: String? {
        switch self {
        case .ambiguous: "Os campos foram modificados no texto livre e não podem ser interpretados sem perda. Revise o bloco na nota; o original foi preservado."
        case .invalidCatalog: "Use um arquivo UTF-8 TSV com duas colunas: código CID-10 e descrição, separados por tabulação. Códigos repetidos ou inválidos não são aceitos."
        case .emptyDocument: "Preencha o conteúdo antes de preparar o documento."
        case .tooLarge: "O conteúdo excede o limite desta prévia. Divida-o em documentos menores."
        }
    }
}

/// A reversible editing convention inside the existing Markdown body, never a second clinical authority.
struct ConsultationFields {
    static let start = "<!-- openpep:consultation-fields:1 -->"
    static let end = "<!-- /openpep:consultation-fields -->"
    var items: [ConsultationFieldItem] = []

    var markdown: String {
        let records = items.filter { !$0.isEmpty }.map { item in
            "### \(item.kind.label)\n\n" + item.kind.fields.compactMap { field -> String? in
                let value = item[field].replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                guard !value.isEmpty else { return nil }
                return "- \(field.label): " + value.replacingOccurrences(of: "\n", with: "\n    ")
            }.joined(separator: "\n")
        }
        guard !records.isEmpty else { return "" }
        return Self.start + "\n## Campos da consulta\n\n" + records.joined(separator: "\n\n") + "\n" + Self.end
    }

    static func read(from body: String) throws -> ConsultationFields {
        guard body.contains(start) || body.contains(end) else { return ConsultationFields() }
        let range = try blockRange(in: body)
        let block = String(body[range])
        let prefix = start + "\n## Campos da consulta\n\n"
        guard block.hasPrefix(prefix) else { throw ConsultationFieldsError.ambiguous }
        let content = String(block.dropFirst(prefix.count).dropLast(("\n" + end).count))
        var result = ConsultationFields()
        var current: ConsultationFieldItem?
        var lastField: ConsultationInputField?
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                if let current { result.items.append(current) }
                guard let kind = ConsultationFieldKind.allCases.first(where: { line == "### " + $0.label }) else {
                    throw ConsultationFieldsError.ambiguous
                }
                current = ConsultationFieldItem(kind: kind)
                lastField = nil
            } else if line.hasPrefix("    "), let field = lastField {
                current?[field] += "\n" + String(line.dropFirst(4))
            } else if line.hasPrefix("- "), let kind = current?.kind,
                      let field = kind.fields.first(where: { line.hasPrefix("- \($0.label): ") }) {
                guard current?.values[field] == nil else { throw ConsultationFieldsError.ambiguous }
                current?[field] = String(line.dropFirst(("- \(field.label): ").count))
                lastField = field
            } else if !line.isEmpty {
                throw ConsultationFieldsError.ambiguous
            }
        }
        if let current { result.items.append(current) }
        guard result.markdown == block else { throw ConsultationFieldsError.ambiguous }
        return result
    }

    func replacing(in body: String) throws -> String {
        let output = markdown
        guard !output.dropFirst(Self.start.count).contains(Self.start),
              output.components(separatedBy: Self.end).count <= 2 else { throw ConsultationFieldsError.ambiguous }
        if body.contains(Self.start) || body.contains(Self.end) {
            _ = try Self.read(from: body)
            return body.replacingCharacters(in: try Self.blockRange(in: body), with: output)
        }
        return output.isEmpty ? body : body + (body.isEmpty ? "" : "\n\n") + output + "\n"
    }

    static func blockRange(in body: String) throws -> Range<String.Index> {
        guard body.components(separatedBy: start).count == 2,
              body.components(separatedBy: end).count == 2,
              let first = body.range(of: start), let last = body.range(of: end),
              first.upperBound < last.lowerBound else { throw ConsultationFieldsError.ambiguous }
        return first.lowerBound..<last.upperBound
    }

    func documentText(for kind: ConsultationFieldKind) throws -> String {
        guard kind != .diagnosis else { throw ConsultationFieldsError.emptyDocument }
        let selected = items.filter { $0.kind == kind && !$0.isEmpty }
        guard !selected.isEmpty else { throw ConsultationFieldsError.emptyDocument }
        return selected.enumerated().map { index, item in
            (["\(index + 1). \(item[.title])"] + kind.fields.filter { $0 != .title }.compactMap { field in
                item[field].isEmpty ? nil : (field == .detail ? item[field] : "\(field.label): \(item[field])")
            }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

struct LocalDiagnosisCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        let code: String
        let title: String
        let searchText: String
        init(code: String, title: String) {
            self.code = code; self.title = title
            searchText = PatientSearch.normalize(code.replacingOccurrences(of: ".", with: "") + " " + title)
        }
        var id: String { code }
    }
    let entries: [Entry]
    init(tsv: String) throws {
        guard tsv.utf8.count <= 8_000_000 else { throw ConsultationFieldsError.invalidCatalog }
        var entries: [Entry] = []
        var seen = Set<String>()
        for line in tsv.components(separatedBy: .newlines) where !line.isEmpty {
            let columns = line.components(separatedBy: "\t")
            guard columns.count == 2 else { throw ConsultationFieldsError.invalidCatalog }
            let code = columns[0].trimmingCharacters(in: .whitespaces).uppercased()
            let title = columns[1].trimmingCharacters(in: .whitespaces)
            guard code.range(of: "^[A-Z][0-9]{2}(\\.?[0-9])?$", options: .regularExpression) != nil,
                  !title.isEmpty, title.count <= 500,
                  seen.insert(code.replacingOccurrences(of: ".", with: "")).inserted else {
                throw ConsultationFieldsError.invalidCatalog
            }
            entries.append(Entry(code: code, title: title))
        }
        guard !entries.isEmpty else { throw ConsultationFieldsError.invalidCatalog }
        self.entries = entries
    }
    func search(_ query: String) -> [Entry] {
        let terms = PatientSearch.normalize(query.replacingOccurrences(of: ".", with: "")).split(separator: " ")
        guard !terms.isEmpty else { return [] }
        return Array(entries.filter { entry in
            let text = entry.searchText
            return terms.allSatisfy { text.contains($0) }
        }.prefix(20))
    }
}


/// Projects the existing body into linear text areas. Legacy structured items stay intact until that area is edited.
struct LinearConsultationPage {
    let body: String
    let fields: ConsultationFields

    init(body: String) throws {
        self.body = body
        fields = try ConsultationFields.read(from: body)
    }

    var consultation: String {
        guard let range = try? ConsultationFields.blockRange(in: body) else { return body }
        var before = String(body[..<range.lowerBound])
        var after = String(body[range.upperBound...])
        // Remove only the separator added by the writer, never the physician's trailing newlines.
        if before.hasSuffix("\n\n") { before.removeLast(2) }
        if after.hasPrefix("\n") { after.removeFirst() }
        return before + after
    }

    func text(for kind: ConsultationFieldKind) -> String? {
        let items = fields.items.filter { $0.kind == kind && !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        if items.count == 1, let item = items.first,
           item.values.filter({ !$0.value.isEmpty }).keys.allSatisfy({ $0 == .detail || (kind == .custom && $0 == .title) }) {
            return item[.detail]
        }
        return items.map { item in
            kind.fields.compactMap { field in
                let value = item[field]
                guard !value.isEmpty else { return nil }
                return field == .title || field == .detail ? value : "\(field.label): \(value)"
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    var customTitle: String {
        let items = fields.items.filter { $0.kind == .custom }
        return items.count == 1 ? items[0][.title] : ""
    }

    func replacingConsultation(with text: String) throws -> String {
        // Reject reserved markers typed into a free area instead of absorbing them into another area.
        try Self.requirePlainArea(text)
        return try fields.replacing(in: text)
    }

    func replacing(_ kind: ConsultationFieldKind, text: String, title: String = "") throws -> String {
        try Self.requirePlainArea(text)
        try Self.requirePlainArea(title)
        var updated = fields
        let insertion = updated.items.firstIndex { $0.kind == kind } ?? updated.items.count
        updated.items.removeAll { $0.kind == kind }
        if !text.isEmpty || !title.isEmpty {
            var item = ConsultationFieldItem(kind: kind)
            item[.detail] = text
            if kind == .custom { item[.title] = title }
            updated.items.insert(item, at: min(insertion, updated.items.count))
        }
        return try updated.replacing(in: body)
    }

    private static func requirePlainArea(_ text: String) throws {
        guard !text.contains(ConsultationFields.start), !text.contains(ConsultationFields.end) else {
            throw ConsultationFieldsError.ambiguous
        }
    }
}
