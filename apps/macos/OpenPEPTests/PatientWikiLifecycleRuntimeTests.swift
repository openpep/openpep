// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import OpenPEP

@Suite("Patient wiki lifecycle runtime", .serialized)
struct PatientWikiLifecycleRuntimeTests {
    @MainActor
    @Test("manual generation works with auto wiki disabled and survives its own change event")
    func manualGenerationPublishesAfterOwnEvent() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .success)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)

        var generated: PatientWikiSummary?
        for _ in 0..<100 {
            generated = try PatientWikiStore().load(for: fixture.patient).summary
            if generated?.markdown.contains("Atualização sintética") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await requester.calls() == 1)
        #expect(generated?.markdown.contains("Atualização sintética") == true)
        #expect(generated?.generatedAt != fixture.original.generatedAt)
    }

    @MainActor
    @Test("partial generation publishes its narrative and omission status")
    func partialGenerationPublishesNarrative() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .partialSuccess)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)
        var generated: PatientWikiSummary?
        for _ in 0..<150 {
            generated = try PatientWikiStore().load(for: fixture.patient).summary
            if generated?.omittedFactCount == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var displayedText = ""
        for _ in 0..<100 {
            hosted.hosting.layoutSubtreeIfNeeded()
            displayedText = try renderedText(hosted.hosting)
            if displayedText.contains("Dados não incluídos no IPS: 1") { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await requester.calls() == 1)
        #expect(generated?.markdown.contains("Resposta parcial sintética") == true)
        #expect(generated?.proposals.isEmpty == true)
        #expect(generated?.omittedFactCount == 1)
        #expect(displayedText.contains("Dados não incluídos no IPS: 1"))
        #expect(displayedText.contains("nenhum item passou"))
        #expect(!displayedText.contains("Sem propostas pendentes"))
        #expect(!displayedText.contains("citação"))
    }

    @MainActor
    @Test("generation failure remains visible after the change-event refresh")
    func generationFailureRemainsVisible() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .failure)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)

        for _ in 0..<100 {
            if await requester.calls() == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(450))
        hosted.hosting.layoutSubtreeIfNeeded()

        #expect(await requester.calls() == 1)
        #expect(try PatientWikiStore().load(for: fixture.patient).summary == fixture.original)
        #expect(try renderedText(hosted.hosting).contains("Falha sintética de geração"))
    }

    @MainActor
    @Test("a local response reason remains visible after its own change-event refresh")
    func localResponseReasonRemainsVisible() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .invalidSources)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)
        for _ in 0..<150 where await requester.calls() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<150 {
            hosted.hosting.layoutSubtreeIfNeeded()
            if try renderedText(hosted.hosting).contains("sem fonte vinculada") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(450))
        hosted.hosting.layoutSubtreeIfNeeded()

        #expect(await requester.calls() == 1)
        #expect(try PatientWikiStore().load(for: fixture.patient).summary == fixture.original)
        #expect(try renderedText(hosted.hosting).contains("sem fonte vinculada"))
    }

    @MainActor
    @Test("automatic refresh includes a finalized measurement and saved correction")
    func automaticRefreshIncludesFinalWeightAndCorrections() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try addFinalWeightNote(to: fixture.patient)
        _ = try PatientWikiStore().saveCorrections(
            for: fixture.patient,
            markdown: "Priorizar a revisão do peso sintético.",
            expectedData: nil)
        fixture.defaults.set(true, forKey: AITextSettings.autoWikiKey)
        let prepared = try PatientWikiContext.load(
            context: fixture.context,
            corrections: "Priorizar a revisão do peso sintético.")
        #expect(prepared.entries.contains { $0.text.contains("Peso 72 kg.") })
        #expect(prepared.input.contains("Priorizar a revisão do peso sintético."))
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .successWithWeight)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        for _ in 0..<150 where await requester.calls() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<150 {
            if try PatientWikiStore().load(for: fixture.patient).summary?.proposals.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let generated = try #require(PatientWikiStore().load(for: fixture.patient).summary)
        #expect(await requester.calls() == 1)
        #expect(await requester.lastInput()?.contains("Peso 72 kg.") == true)
        #expect(await requester.lastInput()?.contains("Priorizar a revisão do peso sintético.") == true)
        #expect(generated.proposals.contains { $0.draft.measurement == "weight" && $0.draft.value == "72" })
        #expect(generated.sourceFingerprint != fixture.original.sourceFingerprint)
        #expect(generated.generatedAt != fixture.original.generatedAt)
        var displayedText = ""
        for _ in 0..<100 {
            hosted.hosting.layoutSubtreeIfNeeded()
            displayedText = try renderedText(hosted.hosting)
            if !displayedText.contains("Atualização pendente")
                && !displayedText.contains("Resumo desatualizado") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!displayedText.contains("Atualização pendente"))
        #expect(!displayedText.contains("Resumo desatualizado"))
    }

    @MainActor
    @Test("a source changed during generation preserves the previous summary and exposes the conflict")
    func sourceChangePreservesLastGoodSummary() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .changeSource)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)
        for _ in 0..<150 where await requester.calls() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(550))
        hosted.hosting.layoutSubtreeIfNeeded()
        #expect(await requester.calls() == 1)
        #expect(try PatientWikiStore().load(for: fixture.patient).summary == fixture.original)
        #expect(try renderedText(hosted.hosting).contains("As fontes ou correções mudaram durante a geração"))
    }

    @MainActor
    @Test("a global publication conflict is not masked by an omitted fact")
    func globalPublicationConflictKeepsItsReason() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let requester = SyntheticWikiRequester(patient: fixture.patient, outcome: .partialGlobalConflict)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }

        try await pressButton(named: "Atualizar IPS", in: hosted)
        for _ in 0..<150 where await requester.calls() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<150 {
            hosted.hosting.layoutSubtreeIfNeeded()
            if try renderedText(hosted.hosting).contains("A wiki mudou") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        hosted.hosting.layoutSubtreeIfNeeded()

        #expect(await requester.calls() == 1)
        #expect(try PatientWikiStore().load(for: fixture.patient).summary?.markdown
            .contains("Versão concorrente") == true)
        let finalText = try renderedText(hosted.hosting)
        #expect(finalText.contains("A wiki mudou"))
        #expect(!finalText.contains("citação"))
    }

    @MainActor
    @Test("adding a sourced item persists across reopen and review events do not regenerate or flash the source loader")
    func addingAndReviewRefresh() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try addFinalWeightNote(to: fixture.patient)
        let context = try PatientWikiContext.load(context: fixture.context, corrections: "")
        let store = PatientWikiStore()
        let summary = try store.saveSummary(for: context.patient, input: .init(
            markdown: "# Resumo breve\n\nRegistro sintético. [F1]", sourceFingerprint: context.fingerprint,
            model: "synthetic", generatedAt: "2026-09-01T12:05:00Z",
            sources: context.entries.map { .init(id: $0.id, path: $0.source, sha256: PatientAIContext.digest(Data($0.text.utf8))) },
            overview: "Registro sintético.", exclusions: context.exclusions, proposals: [], promptVersion: PatientWikiGeneration.prompt.id),
            expectedData: fixture.original.persistedData, expectedCorrectionsData: nil)
        fixture.defaults.set(true, forKey: AITextSettings.autoWikiKey)
        let requester = SyntheticWikiRequester(patient: context.patient, outcome: .success)
        let hosted = try makeHostingView(fixture: fixture, requester: requester)
        defer { hosted.window.contentView = nil; hosted.window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(650))
        let index = try #require(context.entries.firstIndex { $0.text.contains("Peso 72 kg.") })
        let draft = PatientWikiFactDraft(kind: .measurement, label: "Peso", text: "Peso documentado.",
            source: "F\(index + 1)", quote: "Peso 72 kg.", date: "2026-09-01", measurement: "weight", value: "72", unit: "kg")
        try PatientIPSReviewService.add(draft: draft, decision: .accepted, note: "Conferido na fonte sintética.",
            summary: summary, context: context, historyContext: fixture.context, expectedReviews: nil, reviewer: "Profissional Sintético")
        let reopened = try store.loadReviews(for: context.patient)
        #expect(reopened.0.records.count == 1)
        #expect(reopened.0.accepted(in: context).first?.draft.value == "72")
        #expect(reopened.0.records.first?.note == "Conferido na fonte sintética.")
        // A stale writer still cannot overwrite a decision even though background rechecks are quiet.
        #expect(throws: (any Error).self) {
            try PatientIPSReviewService.add(draft: draft, decision: .accepted, note: "Outra revisão.",
                summary: summary, context: context, historyContext: fixture.context, expectedReviews: nil, reviewer: "Profissional Sintético")
        }
        #expect(try store.loadReviews(for: context.patient).1 == reopened.1)
        for _ in 0..<3 {
            PatientClinicalChange.post(for: context.patient, kind: .reviews)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            try await Task.sleep(for: .milliseconds(280))
            let text = try renderedText(hosted.hosting)
            #expect(!text.contains("Conferindo fontes locais"))
            #expect(!text.contains("Atualização pendente"))
        }
        #expect(await requester.calls() == 0)
        #expect(try store.load(for: context.patient).summary?.persistedData == summary.persistedData)
    }

    @MainActor
    private func makeHostingView(
        fixture: Fixture,
        requester: SyntheticWikiRequester
    ) throws -> HostedWiki {
        let root = AnyView(ScrollView {
            PatientWikiView(
                patient: fixture.patient,
                context: fixture.context,
                canWrite: true,
                textRequester: { input, instructions, responseFormat in
                    try await requester.request(input: input, instructions: instructions, responseFormat: responseFormat)
                }
            )
            .padding(24)
        }
        .frame(width: 960, height: 900)
        .background(Color.white)
        .defaultAppStorage(fixture.defaults)
        .environment(\.colorScheme, .light))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        return HostedWiki(hosting: hosting, window: window)
    }

    @MainActor
    private func pressButton(named title: String, in hosted: HostedWiki) async throws {
        let hosting = hosted.hosting
        for _ in 0..<150 {
            hosting.layoutSubtreeIfNeeded()
            if let button = allButtons(in: hosting).first(where: { $0.title == title }) {
                if button.isEnabled {
                    button.performClick(nil)
                    return
                }
            }
            if let button = allAccessibilityButtons(in: hosting).first(where: { $0.accessibilityLabel() == title }),
               button.accessibilityPerformPress() {
                return
            }
            if let frame = textFrame(containing: title, in: hosting) {
                sendClick(at: NSPoint(x: frame.midX, y: frame.midY), in: hosted.window, from: hosting)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let native = allButtons(in: hosting).map { "\(type(of: $0)):\($0.title):\($0.isEnabled)" }
        let accessible = allAccessibilityElements(in: hosting).compactMap { element -> String? in
            guard let element = element as? NSAccessibilityElement else { return nil }
            return "\(String(describing: element.accessibilityRole())):\(element.accessibilityTitle() ?? element.accessibilityLabel() ?? ""):\(element.isAccessibilityEnabled())"
        }
        throw SyntheticWikiTestIssue.missingButton(title + " native=\(native) ax=\(accessible)")
    }

    @MainActor
    private func textFrame(containing needle: String, in view: NSView) -> NSRect? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        guard let request = try? makeWikiScreenshotTextRequest() else { return nil }
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        guard let observation = request.results?.first(where: {
            $0.topCandidates(1).first?.string.localizedStandardContains(needle) == true
        }) else { return nil }
        let box = observation.boundingBox
        let visionY = box.midY * view.bounds.height
        return NSRect(
            x: view.bounds.minX + box.midX * view.bounds.width,
            y: view.isFlipped ? view.bounds.maxY - visionY : view.bounds.minY + visionY,
            width: 1,
            height: 1
        )
    }

    @MainActor
    private func sendClick(at viewPoint: NSPoint, in window: NSWindow, from view: NSView) {
        let windowPoint = view.convert(viewPoint, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
            modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
            modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        if let down { window.sendEvent(down) }
        if let up { window.sendEvent(up) }
    }

    @MainActor
    private func renderedText(_ view: NSView) throws -> String {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = try makeWikiScreenshotTextRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    @MainActor
    private func snapshot(_ view: NSView, named name: String) throws -> URL {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/openpep-wiki-lifecycle-\(name).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private func allButtons(in view: NSView) -> [NSButton] {
        ([view] + view.subviews.flatMap(allButtons)).compactMap { $0 as? NSButton }
    }

    @MainActor
    private func allAccessibilityElements(in view: NSView) -> [NSAccessibilityElement] {
        let roots = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        return roots + roots.flatMap(accessibilityDescendants)
    }

    @MainActor
    private func accessibilityDescendants(of element: NSAccessibilityElement) -> [NSAccessibilityElement] {
        let children = element.accessibilityChildren() ?? []
        let elements = children.compactMap { $0 as? NSAccessibilityElement }
        return elements + elements.flatMap(accessibilityDescendants)
    }

    @MainActor
    private func allAccessibilityButtons(in view: NSView) -> [NSAccessibilityButton] {
        allAccessibilityElements(in: view).compactMap { $0 as? NSAccessibilityButton }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-wiki-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let vault = try VaultCreator().create(
            in: root,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-0000-7000-8000-000000000001",
                deviceID: "dev_0198f5c1-0000-7000-8000-000000000001"),
            createdAt: ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")!)
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: "pt_0198f5c2-0000-7000-8000-000000000001"),
            input: PatientRecordInput(
                fullName: "Pessoa Wiki Sintética", preferredName: nil, birthDate: "1990-01-01",
                contacts: [], identifiers: [], alerts: []),
            createdAt: ISO8601DateFormatter().date(from: "2026-09-01T12:01:00Z")!)
        let original = try PatientWikiStore().saveSummary(
            for: patient,
            input: PatientWikiSummaryInput(
                markdown: "# Resumo breve\n\nVersão sintética anterior. [F1]\n",
                sourceFingerprint: String(repeating: "a", count: 64),
                model: "synthetic-model-old",
                generatedAt: "2026-09-01T12:02:00Z",
                sources: [PatientWikiSource(
                    id: patient.patientID,
                    path: "patient.yaml",
                    sha256: String(repeating: "b", count: 64))],
                overview: "Versão sintética anterior.",
                exclusions: PatientWikiExclusions(),
                promptVersion: PatientWikiGeneration.prompt.id),
            expectedData: nil,
            expectedCorrectionsData: nil)
        let suiteName = "openpep-wiki-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: AITextSettings.enabledKey)
        defaults.set(false, forKey: AITextSettings.autoWikiKey)
        let context = PatientHistoryContext(
            patientID: patient.patientID,
            patientName: patient.displayName,
            vaultURL: vault.url,
            authorizationURL: vault.url)
        return Fixture(root: root, patient: patient, context: context, original: original,
                       defaults: defaults, defaultsName: suiteName)
    }

    private func addFinalWeightNote(to patient: PatientSummary) throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-01T12:03:00Z"))
        let encounterID = "enc_0198f5c3-0000-7000-8000-000000000001"
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: "note_0198f5d3-0000-7000-8000-000000000001",
                syntheticActorID: "usr_0198f5d4-0000-7000-8000-000000000001"),
            startedAt: date)
        let currentPatient = try #require(VaultReader().open(patient.url.deletingLastPathComponent().deletingLastPathComponent()).patients.first {
            $0.patientID == patient.patientID
        })
        let currentEncounter = try #require(currentPatient.encounters.first {
            $0.metadata.encounterID == encounterID
        })
        _ = try ClinicalDraftSaver().save(
            encounter: currentEncounter,
            patientID: patient.patientID,
            body: "Consulta final sintética.\nPeso 72 kg.\n",
            updatedAt: date.addingTimeInterval(60))
        let savedPatient = try #require(VaultReader().open(patient.url.deletingLastPathComponent().deletingLastPathComponent()).patients.first {
            $0.patientID == patient.patientID
        })
        let savedEncounter = try #require(savedPatient.encounters.first {
            $0.metadata.encounterID == encounterID
        })
        _ = try ClinicalFinalizer().finalize(
            patient: savedPatient,
            encounter: savedEncounter,
            identity: FinalizationIdentity(eventID: "evt_0198f5e4-0000-7000-8000-000000000001"),
            finalizedAt: date.addingTimeInterval(120))
    }
}

@MainActor
private struct HostedWiki {
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
}

private struct Fixture {
    let root: URL
    let patient: PatientSummary
    let context: PatientHistoryContext
    let original: PatientWikiSummary
    let defaults: UserDefaults
    let defaultsName: String

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

    private actor SyntheticWikiRequester {
    enum Outcome: Sendable {
        case success, failure, successWithWeight, changeSource, invalidSources, partialSuccess, partialGlobalConflict
    }

    private let patient: PatientSummary
    private let outcome: Outcome
    private var requestCount = 0
    private var inputs: [String] = []

    init(patient: PatientSummary, outcome: Outcome) {
        self.patient = patient
        self.outcome = outcome
    }

    func request(
        input: String,
        instructions: String,
        responseFormat: OpenAITextResponseFormat?
    ) async throws -> OpenAITextResult {
        inputs.append(input)
        _ = instructions
        _ = responseFormat
        requestCount += 1
        if outcome == .changeSource, let record = patient.record {
            _ = try PatientEditor().update(
                patient: patient,
                input: PatientRecordInput(
                    fullName: (record.fullName ?? "Pessoa Wiki Sintética") + " atualizado",
                    preferredName: record.preferredName,
                    birthDate: record.birthDate,
                    contacts: record.contacts,
                    identifiers: record.identifiers,
                    alerts: record.alerts),
                updatedAt: Date(timeIntervalSince1970: 1_788_274_000))
        }
        if outcome == .partialGlobalConflict,
           let existing = try PatientWikiStore().load(for: patient).summary {
            _ = try PatientWikiStore().saveSummary(
                for: patient,
                input: PatientWikiSummaryInput(
                    markdown: "# Resumo breve\n\nVersão concorrente. [F1]\n",
                    sourceFingerprint: existing.sourceFingerprint,
                    model: "synthetic-concurrent",
                    generatedAt: "2026-09-13T12:10:00Z",
                    sources: existing.sources,
                    overview: "Versão concorrente.",
                    exclusions: existing.exclusions,
                    proposals: existing.proposals,
                    promptVersion: existing.promptVersion,
                    omittedFactCount: existing.omittedFactCount),
                expectedData: existing.persistedData,
                expectedCorrectionsData: nil)
        }
        PatientClinicalChange.post(for: patient)
        try await Task.sleep(for: .milliseconds(100))
        if outcome == .failure { throw SyntheticWikiTestIssue.generationFailed }
        if outcome == .invalidSources {
            return OpenAITextResult(
                text: #"{"overview":{"text":"Resposta sintética sem fonte.","sources":[]},"sections":[],"facts":[]}"#,
                model: "synthetic-model-invalid",
                responseID: "resp_synthetic_invalid")
        }
        if outcome == .partialSuccess || outcome == .partialGlobalConflict {
            return OpenAITextResult(
                text: #"{"overview":{"text":"Resposta parcial sintética.","sources":["F1"]},"sections":[],"facts":[{"kind":"problem","label":"Febre","text":"Fato sintético.","source":"F1","quote":"Trecho inexistente","date":"","clinicalStatus":"unknown","certainty":"unknown","medicationUse":"unknown","dosage":"","measurement":"","value":"","unit":"","method":"","observationStatus":"unknown"}]}"#,
                model: "synthetic-model-partial",
                responseID: outcome == .partialSuccess ? "resp_synthetic_partial" : "resp_synthetic_partial_conflict")
        }
        let response: String
        if outcome == .successWithWeight {
            response = #"{"overview":{"text":"Peso sintético registrado.","sources":["F1"]},"sections":[],"facts":[{"kind":"measurement","label":"Peso","text":"Peso sintético documentado.","source":"F1","quote":"Peso 72 kg.","date":"2026-09-01","clinicalStatus":"unknown","certainty":"unknown","medicationUse":"unknown","dosage":"","measurement":"weight","value":"72","unit":"kg","method":"Balança sintética","observationStatus":"unknown"}]}"#
        } else {
            response = #"{"overview":{"text":"Atualização sintética","sources":["F1"]},"sections":[],"facts":[]}"#
        }
        return OpenAITextResult(
            text: response,
            model: "synthetic-model-new",
            responseID: "resp_synthetic_wiki")
    }

    func calls() -> Int { requestCount }
    func lastInput() -> String? { inputs.last }
}

private enum SyntheticWikiTestIssue: Error, LocalizedError {
    case missingButton(String)
    case generationFailed

    var errorDescription: String? {
        switch self {
        case let .missingButton(title): "Botão sintético ausente: \(title)"
        case .generationFailed: "Falha sintética de geração"
        }
    }
}
