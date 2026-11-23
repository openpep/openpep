// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct PatientIPSCoding: Codable, Equatable, Sendable {
    let system: String
    let version: String
    let code: String
    let display: String
    let mapping: String
}

/// Offline exact lookup, deliberately without fuzzy matching or model-generated identifiers.
struct PatientIPSTerminology: Sendable {
    static let system = "http://snomed.info/sct"
    static let version = "http://snomed.info/sub/999991001000101/version/20240701"
    static let resourceDigest = "ad6b12c3a73b3664fe90f9b0d5bd2e339756ae6f91402e767987c1513021dc4a"
    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "snomed-ips-20240701", withExtension: "tsv"),
              let data = try? Data(contentsOf: url), PatientAIContext.digest(data) == resourceDigest else { return nil }
        return try? Self(data: data)
    }()

    let names: [String: String]
    private let exact: [String: Set<String>]
    // Local Portuguese labels, not an official translation of SNOMED CT.
    private static let aliases: [String: String] = [
        "hipertensao arterial": "38341003", "hipertensao arterial sistemica": "38341003",
        "hipertensao essencial": "59621000", "diabetes mellitus tipo 2": "44054006",
        "diabetes tipo 2": "44054006", "obesidade": "414916001", "enxaqueca": "37796009",
        "asma": "195967001", "hipotireoidismo": "40930008", "colecistectomia": "38102005"
    ]

    init(data: Data) throws {
        guard data.count <= 10_000_000, let text = String(data: data, encoding: .utf8) else {
            throw OpenAITextIssue.invalidResponse
        }
        let lines = text.split(separator: "\n")
        guard lines.first == "conceptId\ttypeId\tterm" else { throw OpenAITextIssue.invalidResponse }
        var names: [String: String] = [:], terms: [String: Set<String>] = [:]
        for line in lines.dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3, columns[0].range(of: "^[0-9]{6,18}$", options: .regularExpression) != nil,
                  !columns[2].isEmpty else { throw OpenAITextIssue.invalidResponse }
            if columns[1] == "900000000000003001" {
                guard names.updateValue(columns[2], forKey: columns[0]) == nil else { throw OpenAITextIssue.invalidResponse }
            }
            terms[PatientSearch.normalize(columns[2]), default: []].insert(columns[0])
        }
        guard terms.values.allSatisfy({ $0.allSatisfy { names[$0] != nil } }) else { throw OpenAITextIssue.invalidResponse }
        self.names = names
        exact = terms
    }

    func match(label: String, kind: PatientWikiFactKind) -> PatientIPSCoding? {
        // Other IPS bindings require domain-specific value sets; leave them textual.
        guard kind == .problem || kind == .procedure else { return nil }
        let key = PatientSearch.normalize(label)
        let alias = Self.aliases[key]
        let candidates = alias.map { Set([$0]) } ?? exact[key] ?? []
        guard candidates.count == 1, let id = candidates.first, let name = names[id],
              kind == .problem ? (name.hasSuffix("(disorder)") || name.hasSuffix("(finding)")) : name.hasSuffix("(procedure)") else { return nil }
        return PatientIPSCoding(system: Self.system, version: Self.version, code: id, display: name,
            mapping: alias == nil ? "exact-en@1" : "openpep-pt-labels@1")
    }

    static func validate(_ coding: PatientIPSCoding, label: String, kind: PatientWikiFactKind) throws {
        guard let bundled, coding == bundled.match(label: label, kind: kind) else {
            throw OpenAITextIssue.invalidResponse
        }
    }
}
