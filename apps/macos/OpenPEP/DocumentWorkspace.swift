// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit

/// An explicit page boundary inside the existing editable Markdown, preserved by old readers.
enum DocumentPages {
    static let separator = "\n\n<!-- openpep:page-break -->\n\n"
    static func split(_ text: String) -> [String] { text.components(separatedBy: separator) }
    static func joining(_ pages: [String]) -> String { pages.joined(separator: separator) }
}

struct PrescriptionPage {
    struct Medication: Identifiable {
        var id = UUID()
        var name: String
        var dosage: String
        var metadata: MedicationCatalogMetadata? = nil
    }
    var special = false
    var compounded = false
    var medications: [Medication] = []
    var freeText = ""
    var legacy = false

    init(text: String) {
        guard !text.isEmpty else { return }
        let lines = text.components(separatedBy: "\n\n")
        guard let header = lines.first,
              ["## Receita simples", "## Receita especial", "## Receita simples · Manipulado", "## Receita especial · Manipulado"].contains(header) else {
            legacy = true; freeText = text; return
        }
        special = header.contains("especial")
        compounded = header.contains("Manipulado")
        let content = lines.dropFirst().joined(separator: "\n\n")
        if compounded { freeText = content; return }
        if content.isEmpty { return }
        guard content.hasPrefix("### ") else { legacy = true; freeText = text; return }
        for block in content.dropFirst(4).components(separatedBy: "\n\n### ") {
            let pieces = block.components(separatedBy: "\n")
            let metadata = pieces.count > 1 ? MedicationCatalogMetadata.read(pieces[1]) : nil
            medications.append(.init(name: pieces[0], dosage: pieces.dropFirst(metadata == nil ? 1 : 2).joined(separator: "\n"), metadata: metadata))
        }
        if self.text.trimmingCharacters(in: .newlines) != text.trimmingCharacters(in: .newlines) { legacy = true; freeText = text; medications = [] }
    }
    var text: String {
        if legacy { return freeText }
        let content = compounded ? freeText : medications.map { "### \($0.name)\n" + ($0.metadata.map { $0.markdown + "\n" } ?? "") + $0.dosage }.joined(separator: "\n\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "## Receita \(special ? "especial" : "simples")\(compounded ? " · Manipulado" : "")\n\n" + content
    }
}

struct DocumentReviewRecord: Codable {
    var fingerprints: [String: String] = [:]
    static let directoryName = "document-reviews"
    static func fingerprint(section: ConsultationTextSection, text: String, patientName: String,
                            identity: DoctorDocumentIdentity) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fields = [section.rawValue, text, patientName]
        var data = (try? encoder.encode(fields)) ?? Data()
        data.append((try? encoder.encode(identity)) ?? Data())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func url(patient: PatientSummary, encounterID: String) -> URL {
        patient.url.appending(path: "content/\(directoryName)/\(encounterID).json")
    }
    static func read(patient: PatientSummary, encounterID: String) -> Self {
        let url = url(patient: patient, encounterID: encounterID)
        guard (try? requireSafe(url)) != nil, let data = try? Data(contentsOf: url), data.count <= 32_000,
              let record = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return record
    }
    func save(patient: PatientSummary, encounterID: String) throws {
        guard OpenPEPIdentifier.isEncounter(encounterID) else { throw ConsultationFieldsError.ambiguous }
        let url = Self.url(patient: patient, encounterID: encounterID)
        try Self.requireSafe(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    static func inspect(directory: URL, encounterIDs: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try requireSafe(directory)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            try requireSafe(file)
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard file.pathExtension == "json", encounterIDs.contains(file.deletingPathExtension().lastPathComponent),
                  properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= 32_000 else { throw ConsultationFieldsError.ambiguous }
            let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            let known = Set(ConsultationTextSection.documentSections.map(\.rawValue))
            guard Set(record.fingerprints.keys).isSubset(of: known), record.fingerprints.values.allSatisfy({
                $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            }) else { throw ConsultationFieldsError.ambiguous }
        }
    }

    private static func requireSafe(_ url: URL) throws {
        var component = url
        while component.path != "/" {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ConsultationFieldsError.ambiguous
            }
            component.deleteLastPathComponent()
        }
    }
}

/// Reuse only verified final consultations; selecting a row creates an editable proposal.
struct PreviousPrescription: Identifiable {
    let id: String
    let label: String
    let text: String
    static func from(_ patient: PatientSummary) -> [Self] {
        patient.encounters.sorted { $0.metadata.startedAt > $1.metadata.startedAt }.compactMap { encounter in
            guard case let .verified(finalization) = encounter.finalizationStatus,
                  let page = try? LinearConsultationPage(body: finalization.finalNote.body),
                  let text = page.text(for: .medication), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let date = ISO8601DateFormatter().date(from: encounter.metadata.startedAt)?.formatted(date: .numeric, time: .omitted) ?? String(encounter.metadata.startedAt.prefix(10))
            let name = PrescriptionPage(text: DocumentPages.split(text)[0]).medications.first?.name ?? "Receituário"
            return Self(id: encounter.metadata.encounterID, label: date + " · " + String(name.prefix(70)), text: text)
        }
    }
}

enum DocumentReviewSelection {
    static func matches(_ selected: [ConsultationDocumentPreview], current: [ConsultationDocumentPreview]) -> Bool {
        !selected.isEmpty && Set(selected.map(\.section)).count == selected.count && selected.allSatisfy { item in
            current.contains { $0.section == item.section && $0.fingerprint == item.fingerprint }
        }
    }
}
