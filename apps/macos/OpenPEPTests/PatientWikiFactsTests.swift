// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI
import Testing
import Yams
@testable import OpenPEP

struct PatientWikiFactsTests {
    @MainActor
    @Test("native sharing preview renders the named patient and selectable reviewed facts")
    func sharingPreview() async throws {
        let context = try context()
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let summary = PatientWikiSummary(markdown: "Resumo sintético. [F1]", sourceFingerprint: context.fingerprint,
            model: "synthetic", generatedAt: "2026-09-07T12:00:00Z", sources: [fact.source],
            overview: "Resumo sintético. [F1]", exclusions: context.exclusions, proposals: [fact], persistedData: Data())
        let view = PatientWikiExportView(summary: summary, context: context,
            historyContext: .init(patientID: patientID, patientName: context.patient.displayName,
                vaultURL: context.patient.url, authorizationURL: context.patient.url),
            reviews: .init(patientID: patientID, records: [review(fact)]), expectedReviews: nil, reviewer: "Profissional Sintético")
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 620)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        try png.write(to: URL(fileURLWithPath: "/tmp/openpep-wiki-export-preview.png"), options: .atomic)
    }

    @Test("literal evidence and clinical dates are required for quantitative extraction")
    func evidence() throws {
        let context = try context()
        let fact = try #require(PatientWikiFact.bind([weight()], to: context).first)
        #expect(fact.matches(context.entries))
        #expect(fact.loinc == "29463-7")
        var wrong = weight(); wrong.quote = "Texto inventado"
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([wrong], to: context) }
        wrong = weight(); wrong.date = "2026-02-30"
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([wrong], to: context) }
        wrong = weight(); wrong.value = "80"
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([wrong], to: context) }
        wrong = weight(); wrong.unit = "lb"
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([wrong], to: context) }
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiFact.bind([weight(), weight()], to: context) }
    }

    @Test("stable evidence survives source reordering but not changed source text")
    func sourceIdentity() throws {
        let first = try context()
        let original = try PatientWikiFact.bind([weight()], to: first)[0]
        let other = PatientHistoryEntry(id: "asset_0198f700-0000-7000-8000-000000000010", title: "Outra fonte",
            timestamp: "2026-09-02T12:00:00Z", status: "Documento", text: "Texto adicional sintético.",
            source: "raw/another.txt", assetID: nil, issue: nil)
        let reordered = try PatientWikiContext.make(patient: first.patient, entries: [other] + first.entries.filter { $0.source != "patient.yaml" }, corrections: "")
        var draft = weight(); draft.source = "F2"
        #expect(try PatientWikiFact.bind([draft], to: reordered)[0].id == original.id)
        let changed = try context(text: "Peso 73 kg. Fonte corrigida.")
        #expect(!original.matches(changed.entries))
        let accepted = PatientWikiReviews(patientID: first.patient.patientID, records: [review(original)])
        #expect(accepted.accepted(in: first).count == 1)
        #expect(accepted.accepted(in: changed).isEmpty)
    }

    @Test("outdated acceptances remain visible but never eligible, and latest rejection wins")
    func outdatedAcceptances() throws {
        let original = try context()
        let fact = try PatientWikiFact.bind([weight()], to: original)[0]
        var reviews = PatientWikiReviews(patientID: patientID, records: [review(fact)])
        #expect(reviews.outdatedAccepted(in: original).isEmpty)
        let changed = try context(text: "Peso 73 kg. Fonte corrigida.")
        #expect(reviews.accepted(in: changed).isEmpty)
        #expect(reviews.outdatedAccepted(in: changed).map(\.id) == [fact.id])
        let removed = try PatientWikiContext.make(patient: original.patient, entries: [], corrections: "")
        #expect(reviews.outdatedAccepted(in: removed).map(\.id) == [fact.id])
        reviews.records.append(review(fact, decision: .rejected))
        #expect(reviews.outdatedAccepted(in: changed).isEmpty)
        #expect(reviews.accepted(in: original).isEmpty)
        let foreign = PatientWikiReviews(patientID: "pt_other", records: [review(fact)])
        #expect(foreign.outdatedAccepted(in: changed).isEmpty)
        #expect(foreign.accepted(in: original).isEmpty)
        let unreviewed = PatientWikiReviews(patientID: patientID)
        #expect(unreviewed.accepted(in: original).isEmpty)
        #expect(unreviewed.outdatedAccepted(in: changed).isEmpty)
    }

    @Test("the IPS preview keeps a rejected fact available only for deliberate reconsideration")
    func rejectedFactsRemainAvailableForPreview() throws {
        let context = try context()
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let reviews = PatientWikiReviews(patientID: patientID, records: [review(fact, decision: .rejected)])
        let summary = PatientWikiSummary(markdown: "# Resumo breve\n\nResumo sintético. [F1]",
            sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-07T12:00:00Z",
            sources: [fact.source], overview: "Resumo sintético. [F1]", exclusions: context.exclusions,
            proposals: [], persistedData: Data("summary".utf8))

        let candidates = reviews.candidates(for: summary, in: context)
        #expect(candidates.map(\.id) == [fact.id])
        #expect(reviews.decision(for: fact) == .rejected)
    }

    @Test("review decisions persist, reject stale writes and survive summary regeneration")
    func reviewPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-wiki-review-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(url: directory)
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let store = PatientWikiStore()
        let changes = ClinicalChangeRecorder(patientURL: context.patient.url)
        try store.saveReview(review(fact), for: context.patient, expectedData: nil, validateSources: {})
        #expect(changes.count == 1)
        let (saved, bytes) = try store.loadReviews(for: context.patient)
        #expect(saved.accepted(in: context).count == 1)
        #expect(throws: (any Error).self) {
            try store.saveReview(review(fact), for: context.patient, expectedData: nil, validateSources: {})
        }
        #expect(throws: (any Error).self) {
            try store.saveReview(review(fact, decision: .rejected), for: context.patient, expectedData: bytes) {
                throw PatientAIIssue.changed
            }
        }
        #expect(try store.loadReviews(for: context.patient).1 == bytes)
        #expect(changes.count == 1)
        _ = try store.saveSummary(for: context.patient, input: PatientWikiSummaryInput(markdown: "Resumo sintético.",
            sourceFingerprint: context.fingerprint, model: "synthetic-model", generatedAt: "2026-09-07T12:00:00Z",
            sources: [fact.source], overview: "Resumo sintético.", exclusions: context.exclusions, proposals: [fact]),
            expectedData: nil, expectedCorrectionsData: nil)
        #expect(try store.loadReviews(for: context.patient).1 == bytes)
        try store.saveReview(review(fact, decision: .rejected), for: context.patient, expectedData: bytes, validateSources: {})
        let (rejected, _) = try store.loadReviews(for: context.patient)
        #expect(rejected.records.count == 2)
        #expect(rejected.accepted(in: context).isEmpty)
    }

    @Test("one IPS approval writes a batch and preserves the earlier rejection")
    func batchReviewPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-wiki-review-batch-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try context(text: "Peso 72 kg. HbA1c 6.5 %.", url: directory)
        let weightFact = try PatientWikiFact.bind([weight()], to: context)[0]
        let hba1cDraft = PatientWikiFactDraft(kind: .measurement, label: "HbA1c", text: "Resultado sintético.",
            source: "F1", quote: "HbA1c 6.5 %.", date: "2026-09-01", measurement: "hba1c",
            value: "6.5", unit: "%", method: "Método sintético")
        let hba1cFact = try PatientWikiFact.bind([hba1cDraft], to: context)[0]
        let store = PatientWikiStore()
        try store.saveReview(review(weightFact, decision: .rejected), for: context.patient,
            expectedData: nil, validateSources: {})
        let (_, beforeBatch) = try store.loadReviews(for: context.patient)

        let reviewedAt = "2026-09-08T12:00:00Z"
        let batch = [weightFact, hba1cFact].map {
            PatientWikiReview(fact: $0, decision: .accepted, reviewer: "Médico do Solo",
                reviewedAt: reviewedAt)
        }
        try store.saveReviews(batch, for: context.patient, expectedData: beforeBatch, validateSources: {})

        let (saved, _) = try store.loadReviews(for: context.patient)
        #expect(saved.records.count == 3)
        #expect(saved.decision(for: weightFact) == .accepted)
        #expect(saved.decision(for: hba1cFact) == .accepted)
        #expect(saved.records.suffix(2).allSatisfy { $0.reviewer == "Médico do Solo" })
    }

    @Test("the approval operation rejects a stale preview before accepting and exporting a new proposal")
    func approvalChain() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-wiki-approval-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try context(url: directory)
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let store = PatientWikiStore()
        let first = try store.saveSummary(for: context.patient,
            input: PatientWikiSummaryInput(markdown: "# Resumo breve\n\nPeso encontrado. [F1]",
                sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-07T12:00:00Z",
                sources: [fact.source], overview: "Peso encontrado. [F1]", exclusions: context.exclusions,
                proposals: [fact]), expectedData: nil, expectedCorrectionsData: nil)
        let historyContext = PatientHistoryContext(patientID: patientID, patientName: context.patient.displayName,
            vaultURL: directory, authorizationURL: directory)
        let emptyReviews = PatientWikiReviews(patientID: patientID)

        _ = try store.saveSummary(for: context.patient,
            input: PatientWikiSummaryInput(markdown: "# Resumo breve\n\nPeso atualizado. [F1]",
                sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-08T12:00:00Z",
                sources: [fact.source], overview: "Peso atualizado. [F1]", exclusions: context.exclusions,
                proposals: [fact]), expectedData: first.persistedData, expectedCorrectionsData: nil)

        let candidates = PatientWikiApproval.candidates(reviews: emptyReviews, summary: first,
            context: context, proposals: [fact])
        #expect(candidates.map(\.id) == [fact.id])
        #expect(throws: (any Error).self) {
            try PatientWikiApproval.approve(summary: first, context: context, historyContext: historyContext,
                reviews: emptyReviews, expectedReviews: nil, proposals: [fact], selectedIDs: [fact.id],
                reviewer: "Médico do Solo", reviewedAt: "2026-09-08T12:01:00Z", reloadContext: { context })
        }
        #expect(try store.loadReviews(for: context.patient).0.records.isEmpty)

        let current = try #require(store.load(for: context.patient).summary)
        let approved = try PatientWikiApproval.approve(summary: current, context: context,
            historyContext: historyContext, reviews: emptyReviews, expectedReviews: nil, proposals: [fact],
            selectedIDs: [fact.id], reviewer: "Médico do Solo", reviewedAt: "2026-09-08T12:02:00Z",
            reloadContext: { context })
        #expect(approved.reviews.decision(for: fact) == .accepted)
        #expect(approved.reviews.records.last?.reviewer == "Médico do Solo")

        let ips = try PatientWikiExport.ips(context: context, reviews: approved.reviews,
            author: "Médico do Solo", selectedIDs: [fact.id])
        let text = String(decoding: ips, as: UTF8.self)
        #expect(text.contains("72"))
        #expect(text.contains(fact.source.id))
    }

    @Test("IPS snapshots preserve unknowns, provisional diagnoses and reviewed evidence")
    func ipsFixtures() throws {
        let context = try context(text: "Peso 72 kg. HbA1c 6.5 %. Método sintético. Suspeita de condição sintética. Uso relatado de medicamento sintético. Alergia sintética informada. Alergia ativa de teste. Prescrito tratamento sintético alternativo. Problema anterior resolvido.")
        let drafts = [weight(),
            PatientWikiFactDraft(kind: .measurement, label: "HbA1c", text: "Resultado sintético.", source: "F1", quote: "HbA1c 6.5 %.",
                date: "2026-09-01", measurement: "hba1c", value: "6.5", unit: "%", method: "Método sintético"),
            PatientWikiFactDraft(kind: .problem, label: "Condição sintética", text: "Suspeita documentada.", source: "F1", quote: "Suspeita de condição sintética.", certainty: "suspected"),
            PatientWikiFactDraft(kind: .medication, label: "Medicamento sintético", text: "Uso relatado.", source: "F1", quote: "Uso relatado de medicamento sintético.", medicationUse: "reported"),
            PatientWikiFactDraft(kind: .allergy, label: "Alergia sintética", text: "Informada na fonte.", source: "F1", quote: "Alergia sintética informada."),
            PatientWikiFactDraft(kind: .allergy, label: "Alergia de teste", text: "Ativa na fonte.", source: "F1", quote: "Alergia ativa de teste.", clinicalStatus: "active"),
            PatientWikiFactDraft(kind: .medication, label: "Tratamento sintético alternativo", text: "Prescrição documentada.", source: "F1", quote: "Prescrito tratamento sintético alternativo.", medicationUse: "prescribed"),
            PatientWikiFactDraft(kind: .problem, label: "Problema anterior", text: "Resolução documentada.", source: "F1", quote: "Problema anterior resolvido.", clinicalStatus: "resolved")]
        let facts = try PatientWikiFact.bind(drafts, to: context)
        let reviews = PatientWikiReviews(patientID: patientID, records: facts.map { review($0) })
        let data = try PatientWikiExport.ips(context: context, reviews: reviews, author: "Profissional Sintético")
        let bundle = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(bundle["entry"] as? [[String: Any]])
        let resources = entries.compactMap { $0["resource"] as? [String: Any] }
        #expect(resources.first?["resourceType"] as? String == "Composition")
        #expect(resources.filter { $0["resourceType"] as? String == "Provenance" }.count == facts.count)
        #expect(String(decoding: data, as: UTF8.self).contains("provisional"))
        #expect(!String(decoding: data, as: UTF8.self).contains("confirmed"))
        let minimal = try PatientWikiExport.ips(context: context,
            reviews: PatientWikiReviews(patientID: patientID), author: "Profissional Sintético")
        #expect(String(decoding: minimal, as: UTF8.self).components(separatedBy: "emptyReason").count == 4)
        // Synthetic validation artifacts for the external pinned HL7 validator.
        try data.write(to: URL(fileURLWithPath: "/tmp/openpep-ips-synthetic-full.json"), options: .atomic)
        try minimal.write(to: URL(fileURLWithPath: "/tmp/openpep-ips-synthetic-empty.json"), options: .atomic)
    }

    @Test("OKF carries source text and stable footnotes without marking AI narrative as verified")
    func okf() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-okf-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(url: directory)
        let fact = try PatientWikiFact.bind([weight()], to: context)[0]
        let summary = try PatientWikiStore().saveSummary(for: context.patient,
            input: PatientWikiSummaryInput(markdown: "Peso documentado. [F1]", sourceFingerprint: context.fingerprint,
                model: "synthetic-model", generatedAt: "2026-09-07T12:00:00Z", sources: [fact.source],
                overview: "Peso documentado. [F1]", exclusions: context.exclusions), expectedData: nil, expectedCorrectionsData: nil)
        let files = try PatientWikiExport.okf(summary: summary, context: context)
        let text = String(decoding: try #require(files["summary.md"]), as: UTF8.self)
        #expect(text.contains("[^" + fact.source.id + "]"))
        #expect(text.contains("unverified"))
        #expect(!text.contains("\"verified\""))
        // Read with the independent YAML parser, not the producer's JSON serializer.
        let yaml = try #require(Yams.load(yaml: text.components(separatedBy: "---\n")[1]) as? [String: Any])
        #expect(yaml["type"] as? String == "Patient Summary")
        let sourceReferences = try #require(yaml["sources"] as? [[String: String]])
        for reference in sourceReferences {
            let sourcePath = try #require(reference["resource"])
            let sourceText = String(decoding: try #require(files[sourcePath]), as: UTF8.self)
            let metadata = try #require(Yams.load(yaml: sourceText.components(separatedBy: "---\n")[1]) as? [String: Any])
            #expect(metadata["type"] as? String == "Clinical Source")
            #expect(sourceText.contains(context.entries[0].text))
        }
        let export = root.appending(path: "export")
        try PatientWikiExport.write(files, to: export, validate: {})
        #expect(try Data(contentsOf: export.appending(path: "summary.md")) == files["summary.md"])
        #expect(throws: (any Error).self) { try PatientWikiExport.write(files, to: export, validate: {}) }
        let interrupted = root.appending(path: "interrupted")
        #expect(throws: (any Error).self) {
            try PatientWikiExport.write(files, to: interrupted) { throw PatientAIIssue.changed }
        }
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
    }

    @Test("conflicting accepted values require an explicit selection and unknown selections fail")
    func selectionAndConflicts() throws {
        let context = try context(text: "Peso 72 kg. Peso 73 kg.")
        var second = weight(); second.value = "73"; second.quote = "Peso 73 kg."
        let facts = try PatientWikiFact.bind([weight(), second], to: context)
        let reviews = PatientWikiReviews(patientID: patientID, records: facts.map { review($0) })
        #expect(PatientWikiFact.conflictingIDs(in: facts).count == 2)
        #expect(throws: (any Error).self) { try PatientWikiExport.ips(context: context, reviews: reviews, author: "Sintético") }
        #expect(throws: (any Error).self) {
            try PatientWikiExport.ips(context: context, reviews: reviews, author: "Sintético", selectedIDs: ["inexistente"])
        }
        let data = try PatientWikiExport.ips(context: context, reviews: reviews, author: "Sintético", selectedIDs: [facts[0].id])
        #expect(String(decoding: data, as: UTF8.self).contains("não foram incluídos"))
        var rejected = reviews; rejected.records.append(review(facts[1], decision: .rejected))
        #expect(PatientWikiFact.conflictingIDs(in: rejected.accepted(in: context)).isEmpty)
    }

    @Test("local document checks reject dangling references and duplicate fullUrls")
    func documentReferences() throws {
        let context = try context()
        let data = try PatientWikiExport.ips(context: context, reviews: .init(patientID: patientID), author: "Sintético")
        var bundle = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(bundle["entry"] as? [[String: Any]])
        entries.remove(at: 1); bundle["entry"] = entries
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiExport.validateDocument(bundle) }
        entries.append(entries[0]); bundle["entry"] = entries
        #expect(throws: OpenAITextIssue.invalidResponse) { try PatientWikiExport.validateDocument(bundle) }
    }

    @Test("IPS requires an available patient record with a full name")
    func missingPatientName() throws {
        let incomplete = try context(hasRecord: false)
        #expect(throws: (any Error).self) {
            try PatientWikiExport.ips(context: incomplete, reviews: .init(patientID: patientID), author: "Sintético")
        }
    }

    private let patientID = "pt_0198f700-0000-7000-8000-000000000091"
    private func context(text: String = "Peso 72 kg.", url: URL? = nil, hasRecord: Bool = true) throws -> PatientWikiContext {
        let record = PatientRecord(schema: "openpep/patient@1", patientID: patientID, status: .active,
            fullName: "Pessoa Sintética da Wiki", preferredName: nil, birthDate: nil,
            contacts: [], identifiers: [], alerts: [], createdAt: "2026-09-01T12:00:00Z", updatedAt: "2026-09-01T12:00:00Z",
            archivedAt: nil, extensions: [:])
        let patient = PatientSummary(patientID: patientID,
            url: url ?? URL(fileURLWithPath: "/synthetic/" + patientID), record: hasRecord ? record : nil, rawAssets: [], encounters: [])
        let source = PatientHistoryEntry(id: "enc_0198f700-0000-7000-8000-000000000001", title: "Consulta sintética",
            timestamp: "2026-09-01T12:00:00Z", status: "Finalizada", text: text,
            source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)
        return try PatientWikiContext.make(patient: patient, entries: [source], corrections: "")
    }
    private func weight() -> PatientWikiFactDraft {
        PatientWikiFactDraft(kind: .measurement, label: "Peso", text: "Peso registrado.", source: "F1",
            quote: "Peso 72 kg.", date: "2026-09-01", measurement: "weight", value: "72", unit: "kg")
    }
    private func review(_ fact: PatientWikiFact, decision: PatientWikiReview.Decision = .accepted) -> PatientWikiReview {
        PatientWikiReview(fact: fact, decision: decision, reviewer: "Profissional Sintético", reviewedAt: "2026-09-07T12:00:00Z")
    }
}

/// Notification delivery is synchronous; locking also isolates parallel test writers.
final class ClinicalChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var token: NSObjectProtocol?
    var count: Int { lock.withLock { total } }

    init(patientURL: URL) {
        token = NotificationCenter.default.addObserver(forName: PatientClinicalChange.notification,
            object: nil, queue: nil) { [weak self] change in
                guard PatientClinicalChange.matches(change, patientURL: patientURL), let self else { return }
                self.lock.withLock { self.total += 1 }
            }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
