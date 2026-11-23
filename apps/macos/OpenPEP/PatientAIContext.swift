// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct PatientAIContext: Sendable {
    let patient: PatientSummary
    let writingAllowed: Bool
    let entries: [PatientHistoryEntry]
    let excludedCount: Int
    let fingerprint: String
    let input: String

    static let maximumCharacters = 180_000

    static func load(context: PatientHistoryContext, corrections: String,
                     includeDrafts: Bool = false) throws -> PatientAIContext {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(context.vaultURL)
        guard let patient = vault.patients.first(where: { $0.patientID == context.patientID }) else {
            throw PatientAIIssue.patientUnavailable
        }
        let history = try PatientHistoryReader().load(patientID: context.patientID,
            vaultURL: context.vaultURL, authorizationURL: context.authorizationURL)
        return try make(patient: patient, entries: history.entries, corrections: corrections,
                        includeDrafts: includeDrafts, writingAllowed: vault.writingAllowed)
    }

    static func make(patient: PatientSummary, entries all: [PatientHistoryEntry],
                     corrections: String, includeDrafts: Bool = false, writingAllowed: Bool = true) throws -> PatientAIContext {
        let draftIDs = Set(patient.encounters.filter { $0.finalizationStatus == .draft }.map { $0.metadata.encounterID })
        let provisionalAssets = Set(patient.rawAssets.filter { $0.encounterID.map(draftIDs.contains) == true }.map(\.assetID))
        let provenanceAssets = Set(patient.encounters.flatMap { $0.draft.metadata.sourceIDs })
        let entries = all.filter {
            ($0.assetID.map { !provenanceAssets.contains($0) } ?? true) &&
            (includeDrafts || !($0.assetID.map(provisionalAssets.contains) ?? false)) &&
            $0.issue == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (includeDrafts || !$0.source.hasPrefix("content/notes/drafts/"))
        }
        let pieces = entries.enumerated().map { index, source in
            "[F\(index + 1)] \(source.title) · \(source.timestamp) · \(source.status)\n\(UnifiedPrescription.clinicalText(source.text))"
        }
        let input = pieces.joined(separator: "\n\n") + "\n\nCorreções humanas (preservar):\n" + corrections
        guard input.count <= maximumCharacters else { throw PatientAIIssue.tooLong }
        // Includes unavailable and excluded entries so deletion, finalization and
        // extraction failures also invalidate an earlier consolidated summary.
        let encoder = JSONEncoder()
        let fingerprintData = try encoder.encode(all.map {
            [$0.id, $0.assetID ?? "", $0.source, $0.timestamp, $0.status, $0.text, $0.issue ?? ""]
        } + [[patient.patientID, corrections, includeDrafts ? "drafts" : "consolidated"], entries.map(\.id)]
          + patient.rawAssets.map { ["asset-binding", $0.assetID, $0.encounterID ?? ""] }
          + patient.encounters.map { ["encounter-provenance", $0.metadata.encounterID] + $0.draft.metadata.sourceIDs })
        return PatientAIContext(patient: patient, writingAllowed: writingAllowed, entries: entries,
            excludedCount: all.count - entries.count,
            fingerprint: digest(fingerprintData), input: input)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PatientAIIssue: LocalizedError {
    case patientUnavailable, tooLong, changed, noSources
    var errorDescription: String? {
        switch self {
        case .patientUnavailable: "O paciente não está disponível. Reabra o prontuário."
        case .tooLong: "O conjunto de textos excede o limite desta geração. Nenhuma fonte foi cortada ou enviada."
        case .changed: "As fontes ou correções mudaram durante a geração. O resultado anterior foi mantido; atualize para tentar novamente."
        case .noSources: "Ainda não há fontes com texto disponível para esta geração."
        }
    }
}
