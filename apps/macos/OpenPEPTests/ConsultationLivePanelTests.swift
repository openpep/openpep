// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct ConsultationLivePanelTests {
    @Test("consultation strip and summary panel render at wide and compact widths")
    func rendersAdaptiveLayouts() async throws {
        let fixtureURL = repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v2/valid/incremental/work.json"
        )
        let data = try Data(contentsOf: fixtureURL)
        let work = try ProgressiveConsultationWorkStore().decode(data: data)
        let binding = EncounterTranscriptionBinding(
            vaultURL: repositoryRoot,
            vaultID: work.vaultID,
            patientID: work.patientID,
            encounterID: work.encounterID,
            patientName: "Ana Sintética"
        )
        let session = EncounterTranscriptionSession()
        #expect(session.prepare(
            binding: binding,
            onPersist: { _, _, _ in },
            onLoadWork: { (work, data) },
            onPersistWork: { _, _ in data }
        ))

        for (name, width, height, colorScheme, collapsed) in [
            ("wide-light", 1_000.0, 450.0, ColorScheme.light, false),
            ("wide-dark", 1_000.0, 450.0, ColorScheme.dark, false),
            ("compact-dark", 460.0, 380.0, ColorScheme.dark, false),
            ("compact-light", 460.0, 380.0, ColorScheme.light, false),
            ("collapsed-light", 460.0, 112.0, ColorScheme.light, true),
        ] {
            let root = ConsultationLivePanel(session: session, onAccept: { _ in }, onUndo: { _ in },
                                             isCollapsed: .constant(collapsed), onResume: {})
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, colorScheme)
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            window.contentView = hostingView
            window.orderFront(nil)
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            #expect(hostingView.fittingSize.width <= width)
            #expect(hostingView.fittingSize.height <= height)
            try writeSnapshotIfRequested(hostingView, name: name)
            window.orderOut(nil)
        }
        session.shutdown()
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func writeSnapshotIfRequested(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] else { return }
        let outputURL = URL(filePath: directory).appending(path: "consultation-live-\(name).png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("Não foi possível criar a imagem da interface")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Não foi possível codificar a imagem da interface")
            return
        }
        try png.write(to: outputURL, options: .atomic)
    }
}
