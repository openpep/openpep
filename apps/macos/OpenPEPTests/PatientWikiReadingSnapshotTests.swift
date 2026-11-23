// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientWikiReadingSnapshotTests {
    @Test func currentSummaryRemapsParagraphsAndRespectsSelectedSources() throws {
        try withFixture { _, patient, _ in
            let first = entry("first", "Primeira fonte sintética."), second = entry("second", "Segunda fonte sintética.")
            let context = try PatientWikiContext.make(patient: patient, entries: [second, first], corrections: "")
            let sources = [source(first), source(second)]
            let wiki = snapshot(context, sources: sources,
                text: "# Resumo breve\n\nPrimeiro [F1], segundo [F2].\n\nSem referência.\n\nSó primeiro [F1].\n\nReferência impossível [F99].")
            let full = try PatientWikiReadingSnapshot.make(context: context, wiki: wiki, reviews: nil, reviewData: nil)
            #expect(full.freshness == .current && full.wikiParagraphs.count == 2)
            #expect(full.wikiParagraphs[0].text == "Primeiro [F2], segundo [F1].")
            #expect(full.wikiParagraphs[0].sourceNumbers == [2, 1])
            let selected = try PatientWikiReadingSnapshot.make(context: context, wiki: wiki, reviews: nil,
                reviewData: nil, selectedSourceIDs: [first.id])
            #expect(selected.wikiParagraphs.map(\.text) == ["Só primeiro [F1]."])
            #expect(selected.entries.map(\.id) == [first.id])
        }
    }

    @Test func acceptedFactsKeepConflictsAndBecomeOutdatedWhenEvidenceChanges() throws {
        try withFixture { _, patient, _ in
            let original = entry("first", "Condição sintética registrada, sem confirmação de situação atual.")
            let context = try PatientWikiContext.make(patient: patient, entries: [original], corrections: "")
            let active = fact(patient: patient, entry: original, status: "active")
            let resolved = fact(patient: patient, entry: original, status: "resolved")
            try active.validate(); try resolved.validate()
            var reviews = PatientWikiReviews(patientID: patient.patientID, records: [review(active), review(resolved)])
            let wiki = snapshot(context, sources: [source(original)], text: "Condição registrada. [F1]")
            let loaded = try PatientWikiReadingSnapshot.make(context: context, wiki: wiki, reviews: reviews, reviewData: Data("reviews".utf8))
            #expect(loaded.acceptedIPS.count == 2)
            #expect(loaded.conflictingAcceptedIDs == [active.id, resolved.id])
            let changed = try PatientWikiContext.make(patient: patient, entries: [entry("first", "Texto corrigido.")], corrections: "")
            let outdated = try PatientWikiReadingSnapshot.make(context: changed, wiki: wiki, reviews: reviews, reviewData: Data("reviews".utf8))
            #expect(outdated.freshness == .outdated && outdated.wikiParagraphs.isEmpty && outdated.acceptedIPS.isEmpty)
            #expect(outdated.outdatedAcceptedIDs == [active.id, resolved.id])
            reviews.records.append(review(active, decision: .rejected))
            let rejected = try PatientWikiReadingSnapshot.make(context: context, wiki: wiki, reviews: reviews, reviewData: Data("rejected".utf8))
            #expect(rejected.acceptedIPS.map(\.fact.id) == [resolved.id])
            #expect(rejected.conflictingAcceptedIDs.isEmpty)
        }
    }

    @Test func missingInvalidWikiAndUnavailableReviewsPreserveClinicalSources() throws {
        try withFixture { _, patient, _ in
            let clinical = try PatientWikiContext.make(patient: patient, entries: [entry("first", "Fonte sintética.")], corrections: "")
            let missing = PatientWikiSnapshot(summary: nil, corrections: nil, summaryIssue: nil, correctionsIssue: nil)
            let loaded = try PatientWikiReadingSnapshot.make(context: clinical, wiki: missing, reviews: nil, reviewData: nil)
            #expect(loaded.freshness == .missing && loaded.hasClinicalSources && loaded.entries.count == 2)
            let invalid = PatientWikiSnapshot(summary: nil, corrections: nil, summaryIssue: "Inválida", correctionsIssue: nil)
            let unavailable = try PatientWikiReadingSnapshot.make(context: clinical, wiki: invalid,
                reviews: nil, reviewData: Data("invalid".utf8), reviewsIssue: "Indisponível")
            #expect(unavailable.freshness == .invalid && unavailable.hasClinicalSources)
            #expect(unavailable.acceptedIPS.isEmpty && unavailable.reviewsIssue != nil)
            let demographics = try PatientWikiContext.make(patient: patient, entries: [], corrections: "")
            #expect(try !PatientWikiReadingSnapshot.make(context: demographics, wiki: missing, reviews: nil, reviewData: nil).hasClinicalSources)
        }
    }

    @Test func loadedSnapshotIsReadOnlyAndRevalidationDetectsSummaryReviewAndSourceChanges() throws {
        try withFixture { directory, patient, history in
            let file = directory.appending(path: "fonte-sintetica.txt")
            try "Condição sintética registrada.".write(to: file, atomically: true, encoding: .utf8)
            let vault = try VaultReader().open(history.vaultURL)
            _ = try GeneralDocumentImporter().importDocument(from: file, into: patient, encounterID: nil,
                deviceID: vault.manifest.deviceID,
                identity: .init(assetID: "asset_0198f5d2-0000-7000-8000-000000000451"), importedAt: Date())
            let context = try PatientWikiContext.load(context: history, corrections: "")
            let clinical = try #require(context.entries.first(where: { $0.source != "patient.yaml" }))
            let accepted = fact(patient: patient, entry: clinical, status: "active")
            let store = PatientWikiStore()
            let summary = try store.saveSummary(for: patient, input: .init(markdown: "Condição registrada. [F1]",
                sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-17T12:00:00Z",
                sources: context.entries.map(source), overview: "Condição registrada.", exclusions: context.exclusions,
                proposals: [accepted], promptVersion: PatientWikiGeneration.prompt.id),
                expectedData: nil, expectedCorrectionsData: nil)
            try store.saveReview(review(accepted), for: patient, expectedData: nil, validateSources: {})
            let before = try fileBytes(in: history.vaultURL)
            let loaded = try PatientWikiReadingSnapshot.load(context: history)
            #expect(loaded.freshness == .current && loaded.acceptedIPS.count == 1)
            try loaded.revalidate(context: history)
            #expect(try fileBytes(in: history.vaultURL) == before)
            let backup = directory.appending(path: "Backup.openpep", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: history.vaultURL, to: backup)
            let backupContext = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
                vaultURL: backup, authorizationURL: backup, insertionEncounter: nil)
            #expect(throws: PatientAIIssue.changed) { try loaded.revalidate(context: backupContext) }
            _ = try store.saveSummary(for: patient, input: .init(markdown: "Resumo alterado. [F1]",
                sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-17T12:00:00Z",
                sources: context.entries.map(source), overview: "Resumo alterado.", exclusions: context.exclusions,
                promptVersion: PatientWikiGeneration.prompt.id),
                expectedData: summary.persistedData, expectedCorrectionsData: nil)
            #expect(throws: PatientAIIssue.changed) { try loaded.revalidate(context: history) }
            let updated = try PatientWikiReadingSnapshot.load(context: history)
            let reviewURL = patient.url.appending(path: "wiki/review.json")
            try Data("invalid reviews".utf8).write(to: reviewURL, options: .atomic)
            #expect(throws: PatientAIIssue.changed) { try updated.revalidate(context: history) }
            let invalidReviews = try PatientWikiReadingSnapshot.load(context: history)
            #expect(invalidReviews.reviewsIssue != nil && invalidReviews.acceptedIPS.isEmpty && invalidReviews.hasClinicalSources)
            let currentPatient = try VaultReader().open(history.vaultURL).patients[0]
            try FileManager.default.removeItem(at: currentPatient.rawAssets[0].originalURL)
            #expect(throws: (any Error).self) { try invalidReviews.revalidate(context: history) }
        }
    }

    private func entry(_ id: String, _ text: String) -> PatientHistoryEntry {
        let identifier = "asset_0198f5d2-0000-7000-8000-00000000045" + (id == "first" ? "2" : "3")
        return .init(id: identifier, title: "Documento sintético", timestamp: "2026-09-17T12:00:00Z", status: "Documento",
              text: text, source: "raw/\(identifier).txt", assetID: nil, issue: nil)
    }
    private func source(_ entry: PatientHistoryEntry) -> PatientWikiSource {
        .init(id: entry.id, path: entry.source, sha256: PatientAIContext.digest(Data(entry.text.utf8)))
    }
    private func fact(patient: PatientSummary, entry: PatientHistoryEntry, status: String) -> PatientWikiFact {
        .init(patientID: patient.patientID,
            draft: .init(kind: .problem, label: "Condição sintética", text: "Registro sintético", source: entry.id,
                         quote: entry.text, clinicalStatus: status), source: source(entry))
    }
    private func review(_ fact: PatientWikiFact, decision: PatientWikiReview.Decision = .accepted) -> PatientWikiReview {
        .init(fact: fact, decision: decision, reviewer: "Profissional Sintético", reviewedAt: "2026-09-17T12:00:00Z")
    }
    private func snapshot(_ context: PatientWikiContext, sources: [PatientWikiSource], text: String) -> PatientWikiSnapshot {
        .init(summary: .init(markdown: text, sourceFingerprint: context.fingerprint, model: "synthetic",
            generatedAt: "2026-09-17T12:00:00Z", sources: sources, overview: nil, exclusions: nil, proposals: [],
            promptVersion: PatientWikiGeneration.prompt.id, persistedData: Data(text.utf8)),
            corrections: nil, summaryIssue: nil, correctionsIssue: nil)
    }
    private func fileBytes(in root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var bytes: [String: Data] = [:]
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            bytes[file.path] = try Data(contentsOf: file)
        }
        return bytes
    }
    private func withFixture(_ body: (URL, PatientSummary, PatientHistoryContext) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wiki-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try VaultCreator().create(in: directory, identity: .init(
            vaultID: "vlt_0198f5c0-0000-7000-8000-000000000451", deviceID: "dev_0198f5c1-0000-7000-8000-000000000451"), createdAt: Date())
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-000000000451"),
            input: .init(fullName: "Ana Fictícia", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []))
        try body(directory, patient, .init(patientID: patient.patientID, patientName: patient.displayName,
            vaultURL: vault.url, authorizationURL: vault.url, insertionEncounter: nil))
    }
}
