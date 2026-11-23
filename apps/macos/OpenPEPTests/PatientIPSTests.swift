// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import OpenPEP

struct PatientIPSTests {
    private let patientID = "pt_0198f700-0000-7000-8000-000000000091"
    private let stamp = "2026-09-29T12:00:00Z"

    @Test("legacy fact identity remains stable; new valid and invalid fixtures are distinguished")
    func fixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixtures/ips")
        func read(_ name: String) throws -> PatientWikiFact {
            try JSONDecoder().decode(PatientWikiFact.self, from: Data(contentsOf: root.appending(path: name)))
        }
        let legacy = try read("legacy-fact.json")
        try legacy.validate()
        #expect(legacy.draft.ips == nil && legacy.terminology == nil && !legacy.requiresIPSSchema)
        #expect(legacy.id == "59450a0c383f7b73a0162180986d4b487e5b16f0f4ec7251f1f05329994722f8")
        let valid = try read("valid-screening-fact.json")
        try valid.validate()
        #expect(valid.requiresIPSSchema && valid.isPlanned && valid.ipsSection == .results)
        let invalid = try read("invalid-screening-date.json")
        #expect(throws: (any Error).self) { try invalid.validate() }
        var missing = valid; missing.draft.ips = nil
        #expect(throws: (any Error).self) { try missing.validate() }
        var wrongKind = valid; wrongKind.draft.ips?.frequency = "diariamente"
        #expect(throws: (any Error).self) { try wrongKind.validate() }
    }

    @Test("pinned terminology maps exact labels only and rejects invented or mismatched coding")
    func terminology() throws {
        let terms = try #require(PatientIPSTerminology.bundled)
        #expect(terms.names.count == 19_697)
        let code = try #require(terms.match(label: "Hipertensão arterial", kind: .problem))
        #expect(code.code == "38341003" && code.version.hasSuffix("/20240701"))
        try PatientIPSTerminology.validate(code, label: "Hipertensão arterial", kind: .problem)
        #expect(throws: (any Error).self) { try PatientIPSTerminology.validate(code, label: "Obesidade", kind: .problem) }
        #expect(terms.match(label: "Hipertensão arterial suspeita xyz", kind: .problem) == nil)
        #expect(terms.match(label: "Hipertensão arterial", kind: .medication) == nil)
        #expect(terms.match(label: "Colecistectomia", kind: .procedure)?.code == "38102005")
        #expect(terms.match(label: "Obesidade", kind: .problem)?.display.hasSuffix("(disorder)") == true)
    }

    @Test("seven sections bind documented clinical dates and preserve planning without inventing dates")
    func categories() throws {
        let context = try context()
        let facts = try PatientWikiFact.bind(drafts(), to: context)
        #expect(Set(facts.map(\.ipsSection)) == Set(PatientIPSSection.allCases))
        #expect(facts.first?.terminology?.code == "38341003")
        var invented = drafts()[4]; invented.date = "2025-01-01"
        #expect(throws: (any Error).self) { try PatientWikiFact.bind([invented], to: context) }
        #expect(facts[1].ipsDetail.contains("1 vez/dia"))
        #expect(facts[5].isPlanned)
        var invalidDomain = facts[6]; invalidDomain.draft.ips?.socialDomain = ""
        #expect(throws: (any Error).self) { try invalidDomain.validate() }
        var mixedDomain = facts[0]; mixedDomain.draft.ips?.socialDomain = "tobacco"
        #expect(throws: (any Error).self) { try mixedDomain.validate() }
    }

    @Test("schema upgrades preserve edits and human observations across regeneration and reject stale writes")
    func reviewPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-ips-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(url: directory), store = PatientWikiStore()
        let fact = try PatientWikiFact.bind(drafts(), to: context)[0]
        let input = input(context: context, facts: [fact])
        let summary = try store.saveSummary(for: context.patient, input: input, expectedData: nil, expectedCorrectionsData: nil)
        #expect(String(decoding: summary.persistedData, as: UTF8.self).contains("openpep/patient-wiki@4"))
        var edit = fact; edit.draft.text = "Informação conferida com o paciente sintético."
        let history = PatientHistoryContext(patientID: patientID, patientName: "Sintético", vaultURL: root, authorizationURL: root)
        #expect(throws: (any Error).self) {
            try PatientIPSReviewService.save(original: fact, edited: edit, decision: .accepted, note: "",
                summary: summary, context: context, historyContext: history, expectedReviews: nil,
                reviewer: "Profissional Sintético", reloadContext: { context })
        }
        try PatientIPSReviewService.save(original: fact, edited: edit, decision: .accepted, note: "Conferido na revisão.",
            summary: summary, context: context, historyContext: history, expectedReviews: nil,
            reviewer: "Profissional Sintético", reloadContext: { context })
        let (reviews, bytes) = try store.loadReviews(for: context.patient)
        #expect(reviews.schema == "openpep/wiki-reviews@2" && reviews.records.count == 2)
        #expect(reviews.accepted(in: context).map(\.id) == [edit.id])
        #expect(reviews.candidates(for: summary, in: context).map(\.id) == [edit.id])
        #expect(PatientWikiApproval.candidates(reviews: reviews, summary: summary, context: context, proposals: [fact]).map(\.id) == [edit.id])
        #expect(reviews.latestReview(for: edit)?.note == "Conferido na revisão.")
        _ = try store.saveSummary(for: context.patient, input: input, expectedData: summary.persistedData, expectedCorrectionsData: nil)
        #expect(try store.loadReviews(for: context.patient).1 == bytes)
        #expect(throws: (any Error).self) {
            try PatientIPSReviewService.save(original: edit, decision: .pending, note: "",
                summary: summary, context: context, historyContext: history, expectedReviews: nil,
                reviewer: "Profissional Sintético", reloadContext: { context })
        }
        let changed = try self.context(url: directory, text: "Fonte alterada.")
        #expect(throws: (any Error).self) {
            try PatientIPSReviewService.save(original: edit, decision: .accepted, note: "Observação",
                summary: summary, context: context, historyContext: history, expectedReviews: bytes,
                reviewer: "Profissional Sintético", reloadContext: { changed })
        }
        #expect(try store.loadReviews(for: context.patient).1 == bytes)
        // Returning to the original value must not leave both versions hidden.
        try PatientIPSReviewService.save(original: edit, edited: fact, decision: .accepted, note: "Restaurado após conferência.",
            summary: summary, context: context, historyContext: history, expectedReviews: bytes,
            reviewer: "Profissional Sintético", reloadContext: { context })
        let (restored, _) = try store.loadReviews(for: context.patient)
        #expect(restored.accepted(in: context).map(\.id) == [fact.id])
        #expect(restored.candidates(for: summary, in: context).map(\.id) == [fact.id])
        // New fields under the old version fail closed.
        let wrongVersion = try JSONEncoder().encode(restored).replacingJSONVersion()
        try wrongVersion.write(to: directory.appending(path: "wiki/review.json"))
        #expect(throws: (any Error).self) { try store.loadReviews(for: context.patient) }
        let legacyHeader = String(decoding: summary.persistedData, as: UTF8.self)
            .replacingOccurrences(of: "patient-wiki@4", with: "patient-wiki@3")
        try Data(legacyHeader.utf8).write(to: directory.appending(path: "wiki/summary.md"))
        #expect(try store.load(for: context.patient).summaryIssue != nil)
    }

    @Test("regenerated wording stays grouped without inheriting approval and explicit acceptance replaces it")
    func regeneratedWording() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-ips-wording-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(url: directory), store = PatientWikiStore()
        let original = try PatientWikiFact.bind(drafts(), to: context)[7]
        var regenerated = original
        regenerated.draft.label = "Caminhadas regulares"
        regenerated.draft.text = "Relato de caminhada por 150 minutos semanais."
        let summary = try store.saveSummary(for: context.patient, input: input(context: context, facts: [regenerated]),
            expectedData: nil, expectedCorrectionsData: nil)
        try store.saveReview(.init(fact: original, decision: .accepted, reviewer: "Profissional Sintético",
            reviewedAt: stamp, note: "Observação preservada."), for: context.patient, expectedData: nil, validateSources: {})
        let (reviews, bytes) = try store.loadReviews(for: context.patient)
        let groups = PatientIPSFactGroup.make(reviews.candidates(for: summary, in: context), reviews: reviews)
        #expect(groups.count == 1)
        #expect(groups[0].primary == original && groups[0].alternatives == [regenerated])
        #expect(reviews.decision(for: regenerated) == nil)
        var changedDate = regenerated; changedDate.draft.date = "2026-09-01"
        var changedDomain = regenerated; changedDomain.draft.ips?.socialDomain = "sleep"
        var changedQuote = regenerated; changedQuote.draft.quote = "Relato diferente."
        for distinct in [changedDate, changedDomain, changedQuote] {
            #expect(!PatientIPSFactGroup.sameEvidence(original, distinct))
        }
        let history = PatientHistoryContext(patientID: patientID, patientName: "Sintético", vaultURL: root, authorizationURL: root)
        // A plain confirmation preserves identity; it cannot create a second candidate.
        try PatientIPSReviewService.save(original: original, decision: .accepted, note: "Observação preservada.",
            summary: summary, context: context, historyContext: history, expectedReviews: bytes,
            reviewer: "Profissional Sintético", reloadContext: { context })
        let afterConfirm = try store.loadReviews(for: context.patient)
        #expect(afterConfirm.0.accepted(in: context) == [original])
        try PatientIPSReviewService.save(original: regenerated, decision: .accepted, note: "Nova redação conferida.",
            summary: summary, context: context, historyContext: history, expectedReviews: afterConfirm.1,
            reviewer: "Profissional Sintético", reloadContext: { context })
        let reopened = try store.loadReviews(for: context.patient).0
        #expect(reopened.accepted(in: context) == [regenerated])
        #expect(reopened.candidates(for: summary, in: context) == [regenerated])
        #expect(reopened.latestReview(for: original)?.note == "Observação preservada.")
        #expect(reopened.latestReview(for: regenerated)?.note == "Nova redação conferida.")
    }

    @Test("editor explains missing input, dates and evidence without misreporting a concurrent change")
    func editorValidation() throws {
        let context = try context()
        var draft = drafts()[5]
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "Conferido.", context: context) == nil)
        draft.quote = ""
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "", context: context)?.contains("Copie o trecho") == true)
        draft = drafts()[5]
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "", context: context)?.contains("observação") == true)
        draft.date = "2025-02-30"
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "Conferido.", context: context)?.contains("data clínica") == true)
        draft.date = "2025-09-30"
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "Conferido.", context: context)?.contains("não consta") == true)
        draft.date = ""; draft.quote = "Trecho inexistente."
        #expect(PatientIPSFormValidation.message(draft: draft, original: nil, note: "Conferido.", context: context)?.contains("não foi encontrado") == true)
        let fact = try PatientWikiFact.bind(drafts(), to: context)[7]
        #expect(PatientIPSFormValidation.message(draft: fact.draft, original: fact, note: "", context: context) == nil)
        var edited = fact.draft; edited.text += " Conferido."
        #expect(PatientIPSFormValidation.message(draft: edited, original: fact, note: "", context: context)?.contains("ajustado") == true)
        #expect(PatientIPSFormValidation.message(draft: edited, original: fact, note: "Relato conferido.", context: context) == nil)
    }

    @Test("FHIR carries notes, codes and seven sections without fabricating performed events from plans")
    func export() throws {
        let context = try context()
        let facts = try PatientWikiFact.bind(drafts(), to: context)
        let reviews = PatientWikiReviews(schema: "openpep/wiki-reviews@2", patientID: patientID,
            records: facts.map { PatientWikiReview(fact: $0, decision: .accepted, reviewer: "Profissional Sintético",
                reviewedAt: stamp, note: "Observação humana preservada.") })
        let data = try PatientWikiExport.ips(context: context, reviews: reviews, author: "Profissional Sintético")
        let bundle = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resources = try #require(bundle["entry"] as? [[String: Any]]).compactMap { $0["resource"] as? [String: Any] }
        let condition = try #require(resources.first { $0["resourceType"] as? String == "Condition" })
        let coding = try #require((condition["code"] as? [String: Any])?["coding"] as? [[String: String]])
        #expect(coding.first?["code"] == "38341003" && coding.first?["version"] == nil)
        #expect(String(decoding: data, as: UTF8.self).contains(PatientIPSTerminology.version))
        #expect(!resources.contains { ["Immunization", "Procedure"].contains($0["resourceType"] as? String ?? "") })
        let social = resources.filter { $0["resourceType"] as? String == "Observation" }
        #expect(social.count == 3)
        #expect(social.contains { ($0["valueString"] as? String) == "Nega tabagismo." })
        #expect(social.allSatisfy { $0["valueQuantity"] == nil })
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("29762-2") && text.contains("72166-2") && text.contains("74013-4"))
        var duplicate = facts[6]; duplicate.draft.text = "Relato divergente de tabagismo."
        #expect(PatientWikiFact.conflictingIDs(in: [facts[6], duplicate]).count == 2)
        try data.write(to: URL(fileURLWithPath: "/tmp/openpep-ips-review-synthetic.json"))
        #expect(text.contains("Observação humana preservada.") && text.contains("A avaliar"))
        #expect(text.contains("Procedimentos e cirurgias") && text.contains("Imunizações") && text.contains("1 vez/dia"))
    }

    @Test("age prompts use only completed reviewed vaccination dates, never invent history or claim overdue")
    func prevention() throws {
        let date = try #require(ISO8601DateFormatter().date(from: stamp))
        #expect(PatientIPSPrevention.reminders(birthDate: nil, accepted: [], on: date).isEmpty)
        #expect(PatientIPSPrevention.reminders(birthDate: "1980-01-01", accepted: [], on: date).isEmpty)
        let facts = try PatientWikiFact.bind(drafts(), to: context())
        let pending = PatientIPSPrevention.reminders(birthDate: "1960-01-01", accepted: facts, on: date)
        #expect(pending.count == 2 && pending.allSatisfy { $0.referenceDate == nil })
        var vaccine = facts[5]; vaccine.draft.label = "Covid-19"
        vaccine.draft.ips?.eventStatus = "completed"; vaccine.draft.date = "2026-03-29"
        let completed = PatientIPSPrevention.reminders(birthDate: "1960-01-01", accepted: [vaccine], on: date)
        #expect(completed[1].referenceDate == "2026-09-29")
        vaccine.draft.date = "2027-03-29"
        #expect(PatientIPSPrevention.reminders(birthDate: "1960-01-01", accepted: [vaccine], on: date)[1].referenceDate == nil)
    }

    @MainActor @Test("native IPS stacks seven cards and expands long lists independently without changing reviews")
    func nativePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-ips-preview-" + UUID().uuidString)
        let directory = root.appending(path: patientID)
        try FileManager.default.createDirectory(at: directory.appending(path: "wiki"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var previewDrafts = drafts()
        for index in 2...6 {
            var medication = previewDrafts[1]
            medication.label = "Medicamento sintético \(index)"
            medication.quote = "Relata \(medication.label) 10 mg por via oral 1 vez/dia."
            previewDrafts.append(medication)
        }
        let context = try context(url: directory, text: previewDrafts.map(\.quote).joined(separator: "\n"))
        let facts = try PatientWikiFact.bind(previewDrafts, to: context)
        let summary = try PatientWikiStore().saveSummary(for: context.patient, input: input(context: context, facts: facts),
            expectedData: nil, expectedCorrectionsData: nil)
        let view = PatientWikiReviewView(summary: summary, sourceContext: context,
            historyContext: .init(patientID: patientID, patientName: "Paciente sintético", vaultURL: root, authorizationURL: root), canWrite: true)
        let hosting = NSHostingView(rootView: view.padding(24).frame(width: 980)
            .fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 980, height: 1100)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        hosting.frame.size = NSSize(width: 980, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        let collapsedHeight = hosting.fittingSize.height
        let reviewsBefore = try PatientWikiStore().loadReviews(for: context.patient)
        func renderedText() throws -> [VNRecognizedTextObservation] {
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["pt-BR"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }
        func pressCard(_ title: String) throws {
            let text = try #require(renderedText().first {
                $0.topCandidates(1).first?.string.localizedStandardContains(title) == true
            }, "Cabeçalho ausente: \(title)")
            let box = text.boundingBox
            let point = NSPoint(x: box.midX * hosting.bounds.width,
                y: (hosting.isFlipped ? 1 - box.midY : box.midY) * hosting.bounds.height)
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        let initialText = try renderedText().compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        for section in PatientIPSSection.allCases {
            #expect(initialText.localizedStandardContains(section.title))
        }
        let medicationTitle = PatientIPSSection.medications.title
        try pressCard(medicationTitle)
        try await Task.sleep(for: .milliseconds(200))
        hosting.frame.size.height = hosting.fittingSize.height
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > collapsedHeight + 300)
        #expect(try renderedText().contains { $0.topCandidates(1).first?.string.contains("Em acompanhamento") == true })
        try pressCard(medicationTitle)
        try await Task.sleep(for: .milliseconds(200))
        hosting.frame.size.height = hosting.fittingSize.height
        hosting.layoutSubtreeIfNeeded()
        #expect(abs(hosting.fittingSize.height - collapsedHeight) < 2)
        try pressCard(medicationTitle)
        try await Task.sleep(for: .milliseconds(200))
        hosting.frame.size.height = hosting.fittingSize.height
        hosting.layoutSubtreeIfNeeded()
        let reviewsAfter = try PatientWikiStore().loadReviews(for: context.patient)
        #expect(reviewsBefore.1 == reviewsAfter.1)
        window.orderOut(nil)
        hosting.frame.size.height = hosting.fittingSize.height
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000 && bitmap.pixelsHigh > 1200)
        try png.write(to: URL(fileURLWithPath: "/tmp/openpep-ips-native.png"))
    }

    @MainActor @Test("new item editor displays required-field guidance and source access within the window")
    func editorPreview() async throws {
        let context = try context()
        let editor = PatientIPSFactEditor(target: .init(section: .immunizations, fact: nil), context: context,
            initialNote: "", canSave: true, saving: false, issue: nil, onCancel: {}, onSave: { _, _, _ in })
        let hosting = NSHostingView(rootView: editor.frame(width: 700, height: 900)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["pt-BR"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        #expect(text.contains("Preencha o nome"))
        #expect(text.contains("Consultar documento selecionado"))
        #expect(text.contains("Confirmar") && text.contains("Cancelar"))
        #expect(!text.contains("wiki/review.json"))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/openpep-ips-editor-fix.png"))
    }

    private func context(url: URL? = nil, text: String? = nil) throws -> PatientWikiContext {
        let record = PatientRecord(schema: "openpep/patient@1", patientID: patientID, status: .active,
            fullName: "Paciente IPS Sintético", preferredName: nil, birthDate: "1960-01-01", contacts: [], identifiers: [], alerts: [],
            createdAt: stamp, updatedAt: stamp, archivedAt: nil, extensions: [:])
        let patient = PatientSummary(patientID: patientID, url: url ?? URL(fileURLWithPath: "/synthetic/" + patientID),
            record: record, rawAssets: [], encounters: [])
        let source = PatientHistoryEntry(id: "enc_0198f700-0000-7000-8000-000000000001", title: "Consulta sintética",
            timestamp: stamp, status: "Finalizada", text: text ?? drafts().map(\.quote).joined(separator: "\n"),
            source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)
        return try PatientWikiContext.make(patient: patient, entries: [source], corrections: "")
    }
    private func input(context: PatientWikiContext, facts: [PatientWikiFact]) -> PatientWikiSummaryInput {
        PatientWikiSummaryInput(markdown: "# Resumo breve\n\nRegistro sintético. [F1]", sourceFingerprint: context.fingerprint,
            model: "synthetic", generatedAt: stamp, sources: Array(Set(facts.map(\.source.id))).compactMap { id in facts.first { $0.source.id == id }?.source },
            overview: "Registro sintético.", exclusions: context.exclusions, proposals: facts, promptVersion: AIPromptCatalog.patientWiki.id)
    }
    private func drafts() -> [PatientWikiFactDraft] {
        [
            .init(kind: .problem, label: "Hipertensão arterial", text: "Em acompanhamento.", source: "F1",
                quote: "Hipertensão arterial crônica em acompanhamento.", clinicalStatus: "active", certainty: "confirmed", ips: .init(course: "chronic")),
            .init(kind: .medication, label: "Medicamento sintético", text: "Uso relatado.", source: "F1",
                quote: "Relata medicamento sintético 10 mg por via oral 1 vez/dia.", clinicalStatus: "active", medicationUse: "reported", dosage: "10 mg", ips: .init(frequency: "1 vez/dia", route: "Via oral")),
            .init(kind: .procedure, label: "Colecistectomia", text: "Procedimento documentado.", source: "F1",
                quote: "Colecistectomia realizada em 2020-02-03.", date: "2020-02-03", ips: .init(eventStatus: "completed")),
            .init(kind: .allergy, label: "Substância sintética", text: "Urticária relatada.", source: "F1",
                quote: "Relata alergia à substância sintética, com urticária.", clinicalStatus: "active", ips: .init()),
            .init(kind: .screening, label: "Rastreamento documentado", text: "Resultado sem alterações relatadas.", source: "F1",
                quote: "Rastreamento realizado em 2026-03-01, sem alterações relatadas. Próxima avaliação combinada para 2027-03-01.", date: "2026-03-01", ips: .init(eventStatus: "completed", nextDate: "2027-03-01")),
            .init(kind: .immunization, label: "Influenza", text: "Conferir carteira e indicação.", source: "F1",
                quote: "Planejado conferir carteira e indicação de influenza em 2026-10-01.", ips: .init(eventStatus: "planned", nextDate: "2026-10-01")),
            .init(kind: .socialHistory, label: "Tabagismo", text: "Nega tabagismo.", source: "F1",
                quote: "Nega tabagismo.", ips: .init(socialDomain: "tobacco")),
            .init(kind: .socialHistory, label: "Atividade física", text: "Caminhada 150 min/semana.", source: "F1",
                quote: "Relata caminhada 150 min/semana.", ips: .init(socialDomain: "activity")),
            .init(kind: .socialHistory, label: "Álcool", text: "Consumo ocasional, quantidade não informada.", source: "F1",
                quote: "Álcool: consumo ocasional, quantidade não informada.", ips: .init(socialDomain: "alcohol"))
        ]
    }
}

private extension Data {
    func replacingJSONVersion() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "wiki-reviews@2", with: "wiki-reviews@1").utf8)
    }
}
