// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import OpenPEP

/// Opt-in maintenance of the ten built-in synthetic cases, never an automatic test side effect.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENPEP_WIKI_MAINTENANCE"] != nil))
struct SyntheticWikiMaintenanceTests {
    @Test func maintainOriginalSyntheticWikis() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = try #require(env["OPENPEP_WIKI_MAINTENANCE"])
        let vaultURL = URL(fileURLWithPath: try #require(env["OPENPEP_WIKI_VAULT"]))
        let output = URL(fileURLWithPath: try #require(env["OPENPEP_WIKI_OUTPUT"]))
        guard ["export", "validate", "apply", "verify"].contains(mode) else { throw PatientAIIssue.changed }
        let vault = try VaultReader().open(vaultURL)
        guard vault.writingAllowed else { throw PatientAIIssue.changed }
        let names = Set(SyntheticCardiologyScenarios.patients.map(\.name))
        let patients = vault.patients.filter { names.contains($0.displayName) }
        guard patients.count == 10, Set(patients.map(\.displayName)) == names else { throw PatientAIIssue.changed }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [[String: Any]] = []
        for patient in patients.sorted(by: { $0.patientID < $1.patientID }) {
            let context = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
                vaultURL: vaultURL, authorizationURL: vaultURL, insertionEncounter: nil)
            let wiki = try PatientWikiStore().load(for: patient)
            guard wiki.summaryIssue == nil, wiki.correctionsIssue == nil else { throw PatientAIIssue.changed }
            let corrections = wiki.corrections?.markdown ?? ""
            let captured = try PatientWikiContext.load(context: context, corrections: corrections)
            let dir = output.appending(path: patient.patientID)
            let manifest = dir.appending(path: "sources.json")
            if mode == "export" {
                guard !FileManager.default.fileExists(atPath: manifest.path) else { throw PatientAIIssue.changed }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let sources: [[String: Any]] = captured.entries.enumerated().map { index, entry in
                    ["label": "F\(index + 1)", "id": entry.id, "title": entry.title, "timestamp": entry.timestamp,
                     "status": entry.status, "text": entry.text, "path": entry.source]
                }
                let json: [String: Any] = ["patientID": patient.patientID, "name": patient.displayName,
                    "fingerprint": captured.fingerprint, "corrections": corrections, "sources": sources,
                    "exclusions": captured.exclusions.description]
                try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
                if let old = wiki.summary?.persistedData { try old.write(to: dir.appending(path: "previous-summary.md")) }
                if let old = wiki.corrections?.persistedData { try old.write(to: dir.appending(path: "previous-corrections.md")) }
            } else if mode == "apply" || mode == "validate" {
                let snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
                guard snapshot["fingerprint"] as? String == captured.fingerprint,
                      snapshot["patientID"] as? String == patient.patientID else { throw PatientAIIssue.changed }
                let previous = try? Data(contentsOf: dir.appending(path: "previous-summary.md"))
                let priorCorrections = try? Data(contentsOf: dir.appending(path: "previous-corrections.md"))
                guard wiki.summary?.persistedData == previous, wiki.corrections?.persistedData == priorCorrections else { throw PatientAIIssue.changed }
                let generation = try PatientWikiGeneration.decode(String(contentsOf: dir.appending(path: "generation.json"), encoding: .utf8), sourceCount: captured.entries.count)
                let facts = try PatientWikiFact.bind(generation.facts, to: captured)
                if mode == "apply" {
                _ = try PatientWikiStore().saveSummary(for: patient,
                    input: .init(markdown: generation.markdown, sourceFingerprint: captured.fingerprint,
                        model: "gpt-5.6-luna/codex", generatedAt: ISO8601DateFormatter().string(from: Date()),
                        sources: captured.entries.map { .init(id: $0.id, path: $0.source, sha256: PatientAIContext.digest(Data($0.text.utf8))) },
                        overview: generation.overviewText, exclusions: captured.exclusions,
                        proposals: facts, promptVersion: PatientWikiGeneration.prompt.id),
                    expectedData: previous, expectedCorrectionsData: priorCorrections,
                    validateSources: {
                        let current = try PatientWikiContext.load(context: context, corrections: corrections)
                        guard current.writingAllowed, current.fingerprint == captured.fingerprint else { throw PatientAIIssue.changed }
                    })
                }
            }
            let checked = try PatientWikiStore().load(for: patient)
            if mode == "apply" || mode == "verify" {
                let summary = try #require(checked.summary)
                #expect(checked.summaryIssue == nil && summary.sourceFingerprint == captured.fingerprint)
                #expect(summary.proposals.allSatisfy { $0.matches(captured.entries) })
                #expect(summary.promptVersion == PatientWikiGeneration.prompt.id)
            }
            report.append(["patientID": patient.patientID, "name": patient.displayName,
                "sources": captured.entries.count, "characters": captured.input.count,
                "wikiCharacters": checked.summary?.markdown.count ?? 0, "facts": checked.summary?.proposals.count ?? 0])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appending(path: mode + "-report.json"))
    }
}
