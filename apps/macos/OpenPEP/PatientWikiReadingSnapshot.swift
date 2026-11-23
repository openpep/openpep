// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Local reading projection only. Nothing in this type sends, generates or persists content.
struct PatientWikiReadingSnapshot: Sendable {
    enum Freshness: String, Sendable { case current, outdated, missing, invalid }
    struct Paragraph: Equatable, Sendable {
        let title: String
        let text: String
        let sourceNumbers: [Int]
    }
    struct AcceptedFact: Equatable, Sendable {
        let fact: PatientWikiFact
        let sourceNumber: Int
        var note: String? = nil
    }

    let patient: PatientSummary
    let entries: [PatientHistoryEntry]
    let corrections: String
    let exclusions: PatientWikiExclusions
    let freshness: Freshness
    let wikiParagraphs: [Paragraph]
    let acceptedIPS: [AcceptedFact]
    let outdatedAcceptedIDs: Set<String>
    let conflictingAcceptedIDs: Set<String>
    let reviewsIssue: String?
    let fingerprint: String
    private let selectedSourceIDs: Set<String>?

    // Demographic registration alone is never clinical evidence.
    var hasClinicalSources: Bool { entries.contains { $0.source != "patient.yaml" } }

    static func load(context: PatientHistoryContext, selectedSourceIDs: Set<String>? = nil) throws -> Self {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let snapshot = try read(context: context, selectedSourceIDs: selectedSourceIDs)
        try Task.checkCancellation()
        let verified = try read(context: context, selectedSourceIDs: selectedSourceIDs)
        guard snapshot.fingerprint == verified.fingerprint else { throw PatientAIIssue.changed }
        return verified
    }

    func revalidate(context: PatientHistoryContext) throws {
        guard context.patientID == patient.patientID else { throw PatientAIIssue.changed }
        let current = try Self.load(context: context, selectedSourceIDs: selectedSourceIDs)
        guard current.patient.url.standardizedFileURL == patient.url.standardizedFileURL,
              current.fingerprint == fingerprint else {
            throw PatientAIIssue.changed
        }
    }

    private static func read(context: PatientHistoryContext, selectedSourceIDs: Set<String>?) throws -> Self {
        let base = try PatientWikiContext.load(context: context, corrections: "")
        let store = PatientWikiStore()
        let wiki = try store.load(for: base.patient)
        guard wiki.correctionsIssue == nil else { throw PatientAIIssue.changed }
        let current = try PatientWikiContext.load(context: context, corrections: wiki.corrections?.markdown ?? "")
        var reviews: PatientWikiReviews?
        var reviewData: Data?
        var reviewsIssue: String?
        do { (reviews, reviewData) = try store.loadReviews(for: current.patient) }
        catch {
            reviewsIssue = "As revisões do IPS não estão disponíveis; nenhum fato foi considerado aceito."
            if let directory = try? store.validatedWikiDirectory(for: current.patient) {
                reviewData = try? store.readManagedFileIfPresent(directory.appending(path: "review.json"))
            }
        }
        return try make(context: current, wiki: wiki, reviews: reviews, reviewData: reviewData,
                        reviewsIssue: reviewsIssue, selectedSourceIDs: selectedSourceIDs)
    }

    static func make(context: PatientWikiContext, wiki: PatientWikiSnapshot,
                     reviews: PatientWikiReviews?, reviewData: Data?, reviewsIssue: String? = nil,
                     selectedSourceIDs: Set<String>? = nil) throws -> Self {
        guard wiki.correctionsIssue == nil,
              reviews?.patientID == nil || reviews?.patientID == context.patient.patientID else { throw PatientAIIssue.changed }
        let entries = context.entries.filter { selectedSourceIDs?.contains($0.id) ?? true }
        func number(for source: PatientWikiSource) -> Int? {
            entries.firstIndex { $0.id == source.id && $0.source == source.path
                && PatientAIContext.digest(Data($0.text.utf8)) == source.sha256 }.map { $0 + 1 }
        }
        let summary = wiki.summary
        let freshness: Freshness
        if wiki.summaryIssue != nil { freshness = .invalid }
        else if let summary {
            freshness = summary.sourceFingerprint == context.fingerprint && summary.sources.allSatisfy { source in
                context.entries.contains { $0.id == source.id && $0.source == source.path
                    && PatientAIContext.digest(Data($0.text.utf8)) == source.sha256 }
            } ? .current : .outdated
        } else { freshness = .missing }
        var paragraphs: [Paragraph] = []
        if freshness == .current, let summary {
            for section in PatientWikiMarkdownPresentation.parse(summary.markdown) {
                for text in section.text.components(separatedBy: "\n\n") {
                    let labels = PatientWikiMarkdownPresentation.sourceLabels(in: text)
                    let remapped = labels.compactMap { label -> (String, Int)? in
                        guard let index = Int(label.dropFirst()), summary.sources.indices.contains(index - 1),
                              let number = number(for: summary.sources[index - 1]) else { return nil }
                        return (label, number)
                    }
                    guard !labels.isEmpty, remapped.count == labels.count else { continue }
                    // Replace in one regex pass, so swaps (F1 -> F2, F2 -> F1) cannot collide.
                    let mapping = Dictionary(uniqueKeysWithValues: remapped)
                    let expression = try NSRegularExpression(pattern: #"\[F([0-9]+)\]"#)
                    var result = text
                    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                        guard let range = Range(match.range, in: result),
                              let original = Range(match.range(at: 1), in: text),
                              let number = mapping["F" + text[original]] else { continue }
                        result.replaceSubrange(range, with: "[F\(number)]")
                    }
                    paragraphs.append(Paragraph(title: section.title, text: result, sourceNumbers: remapped.map(\.1)))
                }
            }
        }
        let availableReviews = reviewsIssue == nil ? reviews : nil
        let accepted = (availableReviews?.accepted(in: context) ?? []).compactMap { fact -> AcceptedFact? in
            number(for: fact.source).map { AcceptedFact(fact: fact, sourceNumber: $0, note: availableReviews?.latestReview(for: fact)?.note) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = try context.patient.record.map { try PatientRecordCodec.encode($0).base64EncodedString() } ?? ""
        let decisions = try encoder.encode(availableReviews).base64EncodedString()
        let token = try encoder.encode([context.fingerprint, identity,
            summary?.persistedData.base64EncodedString() ?? "", wiki.summaryIssue ?? "",
            wiki.corrections?.persistedData.base64EncodedString() ?? "", reviewData?.base64EncodedString() ?? "",
            reviewsIssue ?? "", decisions, freshness.rawValue,
            selectedSourceIDs == nil ? "all" : "selected"] + (selectedSourceIDs?.sorted() ?? []))
        return Self(patient: context.patient, entries: entries, corrections: wiki.corrections?.markdown ?? "",
            exclusions: context.exclusions, freshness: freshness, wikiParagraphs: paragraphs,
            acceptedIPS: accepted, outdatedAcceptedIDs: Set(availableReviews?.outdatedAccepted(in: context).map(\.id) ?? []),
            conflictingAcceptedIDs: PatientWikiFact.conflictingIDs(in: accepted.map(\.fact)), reviewsIssue: reviewsIssue,
            fingerprint: PatientAIContext.digest(token), selectedSourceIDs: selectedSourceIDs)
    }
}
