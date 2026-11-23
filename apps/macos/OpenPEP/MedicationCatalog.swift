// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct MedicationCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        let id: String
        let name: String
        let presentation: String
        let substance: String
        let laboratory: String
        var prescriptionName: String { name + " · " + MedicationPresentation.readable(presentation) }
        let searchText: String
        let metadata: MedicationCatalogMetadata
    }
    let entries: [Entry]
    let publication: String
    static let source = URL(string: "https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv")!

    init(csv: String) throws {
        guard csv.utf8.count <= 30_000_000 else { throw ConsultationFieldsError.tooLarge }
        let rows = try Self.rows(csv)
        guard let headerIndex = rows.firstIndex(where: { $0.contains("PRODUTO") && $0.contains("APRESENTAÇÃO") }) else {
            throw CatalogError.invalid
        }
        let header = rows[headerIndex]
        func index(_ name: String) throws -> Int {
            guard let value = header.firstIndex(of: name) else { throw CatalogError.invalid }; return value
        }
        let name = try index("PRODUTO"), presentation = try index("APRESENTAÇÃO")
        let substance = try index("SUBSTÂNCIA"), laboratory = try index("LABORATÓRIO"), code = try index("CÓDIGO GGREM")
        let publication = rows.prefix(headerIndex).compactMap(\.first).first { $0.contains("Publicada em") } ?? "CMED · Anvisa"
        let registration = header.firstIndex(of: "REGISTRO"), classification = header.firstIndex(of: "CLASSE TERAPÊUTICA")
        let hospital = header.firstIndex(of: "RESTRIÇÃO HOSPITALAR")
        let atc = header.firstIndex(of: "CÓDIGO ATC") ?? header.firstIndex(of: "ATC")
        var entries: [Entry] = []; var seen = Set<String>()
        for row in rows.dropFirst(headerIndex + 1) {
            guard row.count == header.count, !row[name].isEmpty, !row[code].isEmpty else { continue }
            let id = row[code] + "|" + row[name] + "|" + row[presentation]
            guard seen.insert(id).inserted else { continue }
            entries.append(Entry(id: id, name: row[name], presentation: row[presentation],
                substance: row[substance], laboratory: row[laboratory],
                searchText: PatientSearch.normalize([row[name], row[presentation], row[substance], row[laboratory]].joined(separator: " ")),
                metadata: MedicationCatalogMetadata(ggrem: row[code], registration: registration.map { row[$0] },
                    substance: row[substance], product: row[name], presentation: row[presentation], laboratory: row[laboratory],
                    therapeuticClassCMED: classification.map { row[$0] }, atc: atc.flatMap { row[$0].isEmpty ? nil : row[$0] },
                    publication: publication, hospitalOnly: hospital.map { ["SIM", "S"].contains(row[$0].uppercased()) })))
        }
        guard !entries.isEmpty else { throw CatalogError.invalid }
        self.entries = entries
        self.publication = publication
    }
    func search(_ query: String, includesHospital: Bool = true) -> [Entry] {
        let terms = PatientSearch.normalize(query).split(separator: " ")
        guard query.count >= 2, !terms.isEmpty else { return [] }
        return Array(entries.lazy.filter { entry in (includesHospital || entry.metadata.hospitalOnly != true) && terms.allSatisfy { entry.searchText.contains($0) } }.prefix(25))
    }
    static func refreshIsDue(lastDownloaded: Date?, now: Date = Date()) -> Bool {
        guard let lastDownloaded else { return true }
        return now.timeIntervalSince(lastDownloaded) >= 30 * 24 * 60 * 60
    }
    static func load(refresh: Bool = false) async throws -> Self {
        if !refresh, let cached = await MedicationCatalogMemory.shared.fresh() { return cached }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "OpenPEP/CMED")
        let file = directory.appending(path: "catalog.csv")
        let cached = (try? String(contentsOf: file, encoding: .utf8)).flatMap { try? Self(csv: $0) }
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if !refresh, let cached, !refreshIsDue(lastDownloaded: modified) {
            await MedicationCatalogMemory.shared.store(cached, downloadedAt: modified ?? Date())
            return cached
        }
        do {
        var request = URLRequest(url: source); request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 30_000_000, let csv = String(data: data, encoding: .utf8) else { throw CatalogError.invalid }
        let catalog = try Self(csv: csv)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        await MedicationCatalogMemory.shared.store(catalog, downloadedAt: Date())
        return catalog
        } catch {
            if !refresh, let cached { return cached }
            throw error
        }
    }
    enum CatalogError: LocalizedError {
        case invalid
        var errorDescription: String? { "Não foi possível carregar a tabela CMED. Tente novamente." }
    }
    /// Semicolon CSV, including escaped quotes and newlines inside quoted fields.
    private static func rows(_ text: String) throws -> [[String]] {
        var result: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var current = iterator.next()
        while let character = current {
            if character == "\"" {
                if quoted {
                    let next = iterator.next()
                    if next == "\"" { cell.append("\""); current = iterator.next(); continue }
                    quoted = false; current = next; continue
                } else if cell.isEmpty { quoted = true }
                else { cell.append(character) }
            } else if character == ";" && !quoted { row.append(cell); cell = "" }
            else if character == "\n" && !quoted { row.append(cell); result.append(row); row = []; cell = "" }
            else { cell.append(character) }
            current = iterator.next()
        }
        guard !quoted else { throw CatalogError.invalid }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); result.append(row) }
        return result
    }
}

/// Source facts, never an inferred allergy, interaction or therapeutic classification mapping.
struct MedicationCatalogMetadata: Codable, Equatable, Sendable {
    let ggrem: String
    let registration: String?
    let substance: String
    let product: String
    let presentation: String
    let laboratory: String
    let therapeuticClassCMED: String?
    let atc: String?
    let publication: String
    var hospitalOnly: Bool? = nil
    var sourceURL: String? = MedicationCatalog.source.absoluteString
    static let prefix = "<!-- openpep:cmed:"
    var markdown: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Self.prefix + ((try? encoder.encode(self)) ?? Data()).base64EncodedString() + " -->"
    }
    static func read(_ line: String) -> Self? {
        guard line.hasPrefix(prefix), line.hasSuffix(" -->"), line.count < 16_000,
              let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(4))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}


private actor MedicationCatalogMemory {
    static let shared = MedicationCatalogMemory()
    private var catalog: MedicationCatalog?
    private var downloadedAt: Date?
    func fresh() -> MedicationCatalog? {
        MedicationCatalog.refreshIsDue(lastDownloaded: downloadedAt) ? nil : catalog
    }
    func store(_ value: MedicationCatalog, downloadedAt: Date) { catalog = value; self.downloadedAt = downloadedAt }
}

enum MedicationPresentation {
    /// Drop commercial packaging only for solid forms; preserve strength, release and pharmaceutical form.
    static func readable(_ original: String) -> String {
        var text = original
        if text.range(of: #"\b(COM|CAP)\b"#, options: .regularExpression) != nil,
           let packaging = text.range(of: #"\s+(CT|CX)\s+"#, options: .regularExpression) {
            text = String(text[..<packaging.lowerBound])
        }
        for (code, label) in [("CAP DURA", "cápsula dura"), ("CAP MOLE", "cápsula mole"),
                              ("COM REV", "comprimido revestido"), ("COM", "comprimido"),
                              ("CAP", "cápsula"), ("LIB PROL", "liberação prolongada"),
                              ("LIB RET", "liberação retardada"), ("MG", "mg"), ("MCG", "mcg")] {
            text = text.replacingOccurrences(of: "\\b" + code + "\\b", with: label, options: .regularExpression)
        }
        return text
    }
}
