// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct DemoHistoryLayoutTests {
    @Test("realistic history remains readable in narrow and wide windows")
    func layouts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-history-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z"))
        let vault = try SyntheticReleaseSeeder().seed(in: root, at: date)
        let patient = try #require(vault.patients.first)
        let source = root.appending(path: "Resultado de exames laboratoriais e avaliação complementar para acompanhamento ambulatorial em setembro de 2026.txt")
        try Data("Exames recebidos para revisão na consulta.".utf8).write(to: source)
        _ = try GeneralDocumentImporter().importDocument(
            from: source, into: patient, encounterID: nil,
            deviceID: vault.manifest.deviceID,
            identity: try RawAssetCreationIdentity.generate(at: date.addingTimeInterval(120)),
            importedAt: date.addingTimeInterval(120))
        let reopened = try VaultReader().open(vault.url)
        #expect(reopened.unavailablePatients.isEmpty)
        _ = try #require(reopened.patients.first { $0.patientID == patient.patientID })
        let context = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
            vaultURL: vault.url, authorizationURL: root)
        for (width, scheme) in [(560.0, ColorScheme.light), (1100.0, ColorScheme.dark)] {
            let content = PatientHistoryView(context: context, onOpen: { _ in }, onClose: {})
                .frame(width: width, height: 850).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .seconds(1))
            #expect(view.fittingSize.width <= width)
            if let directory = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appending(path: "history-\(Int(width)).png"))
            }
            window.orderOut(nil)
        }
    }
}

extension DemoHistoryLayoutTests {
    @Test("long history scrolls repeatedly with bounded previews")
    func repeatedScrolling() async throws {
        let context = PatientHistoryContext(patientID: "pt_test", patientName: "Pessoa de ensaio",
            vaultURL: URL(fileURLWithPath: "/tmp/openpep-preview"), authorizationURL: URL(fileURLWithPath: "/tmp"))
        let longText = String(repeating: "Evolução registrada para ensaio de interface.\n\n", count: 600)
        let entries = (0..<60).map { index in
            PatientHistoryEntry(id: "enc_preview_\(index)", title: "Consulta \(index + 1)",
                timestamp: String(format: "2026-09-%02dT12:00:00Z", 1 + index % 28), status: "Finalizada", text: longText,
                source: "note.md", assetID: nil, issue: nil)
        }
        for width in [560.0, 1100.0] {
            let view = NSHostingView(rootView: PatientHistoryView.preview(context: context,
                snapshot: PatientHistorySnapshot(patientName: context.patientName, entries: entries))
                .frame(width: width, height: 850))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let scroll = try #require(scrollViews(view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
            let document = try #require(scroll.documentView)
            #expect(document.frame.height > 8000)
            for _ in 0..<3 {
                for fraction in [0.25, 0.5, 0.75, 1.0, 0.0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height) * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(document.frame.height.isFinite)
                }
            }
            #expect(view.fittingSize.width <= width)
            if let directory = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appending(path: "history-long-\(Int(width)).png"))
            }
            window.orderOut(nil)
        }
    }
}

@MainActor @Observable
private final class HistoryEditingState {
    var body = ""
    var showingHistory = false
}

@MainActor
private struct HistoryAfterEditingFixture: View {
    @Bindable var state: HistoryEditingState
    let context: PatientHistoryContext
    var body: some View {
        ScrollView {
            ConsultationFieldsEditor(bodyText: $state.body, onPrepare: { _, _ in }, includesDocuments: false)
                .padding(24)
        }
        .sheet(isPresented: $state.showingHistory) {
            PatientHistoryView(context: context, onOpen: { _ in }, onClose: { state.showingHistory = false })
        }
    }
}

extension DemoHistoryLayoutTests {
    @Test("editing and saving a current consultation never publishes its draft in history")
    func historyAfterEditingAndSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-edited-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z"))
        let vault = try SyntheticReleaseSeeder().seed(in: root, at: date)
        let patient = try #require(vault.patients.first)
        let encounterID = "enc_0198f5c4-0000-7000-8000-000000000001"
        _ = try ClinicalDraftCreator().create(in: patient, identity: ClinicalDraftCreationIdentity(
            encounterID: encounterID, noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"), startedAt: date)
        let current = try #require(VaultReader().open(vault.url).patients.first { $0.patientID == patient.patientID })
        let encounter = try #require(current.encounters.first { $0.metadata.encounterID == encounterID })
        let context = PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
            vaultURL: vault.url, authorizationURL: root, insertionEncounter: encounter)
        let state = HistoryEditingState()
        let host = NSHostingView(rootView: HistoryAfterEditingFixture(state: state, context: context))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        // Exercise the real editor before presenting a separately scrolling history sheet.
        state.body = String(repeating: "Anotação atual de ensaio, ainda em edição.\n", count: 150)
        try await Task.sleep(for: .milliseconds(250))
        _ = try ClinicalDraftSaver().save(encounter: encounter, patientID: patient.patientID,
            body: state.body, updatedAt: date.addingTimeInterval(60))
        let reader = PatientHistoryReader()
        let all = try reader.load(patientID: patient.patientID, vaultURL: vault.url, authorizationURL: root)
        #expect(all.entries.contains { $0.id == encounterID && $0.isDraft })
        let historical = try reader.load(patientID: patient.patientID, vaultURL: vault.url, authorizationURL: root, includeDrafts: false)
        #expect(!historical.entries.contains { $0.id == encounterID })
        #expect(historical.entries.allSatisfy { !$0.isDraft })
        #expect(historical.entries.contains { $0.status == "Finalizada" })
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for _ in 0..<3 {
            state.showingHistory = true
            try await Task.sleep(for: .seconds(1))
            let sheet = try #require(window.sheets.first)
            let content = try #require(sheet.contentView)
            let scroll = try #require(scrollViews(content).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
            let document = try #require(scroll.documentView)
            for fraction in [0.4, 1.0, 0.0, 1.0, 0.0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height) * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(80))
                #expect(document.frame.height.isFinite)
            }
            state.showingHistory = false
            try await Task.sleep(for: .milliseconds(250))
        }
        let beforeFinal = try #require(VaultReader().open(vault.url).patients.first { $0.patientID == patient.patientID })
        _ = try ClinicalFinalizer().finalize(patient: beforeFinal,
            encounter: try #require(beforeFinal.encounters.first { $0.metadata.encounterID == encounterID }),
            identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000003"), finalizedAt: date.addingTimeInterval(120))
        let finalizedHistory = try reader.load(patientID: patient.patientID, vaultURL: vault.url, authorizationURL: root, includeDrafts: false)
        #expect(finalizedHistory.entries.contains { $0.id == encounterID && $0.status == "Finalizada" })
    }

    @Test("delivery contact selection always resolves to an available picker tag")
    func contactSelectionOnChannelChange() {
        let email = "email:paciente07@example.invalid", phone = "phone:+12025550100"
        #expect(DocumentDeliveryView.validContactID(email, available: [phone]) == phone)
        #expect(DocumentDeliveryView.validContactID(phone, available: [email]) == email)
        #expect(DocumentDeliveryView.validContactID(email, available: []) == "")
        #expect(DocumentDeliveryView.validContactID(email, available: [email]) == email)
    }
}
