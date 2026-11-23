// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OpenPEP

@Suite("Assistant local wiki reading presentation", .serialized)
@MainActor struct AssistantWikiReadingViewTests {
    @Test("local reading renders in both appearances and invalidation preserves the mounted note")
    func localReadingAndNoteSurvivePresentation() async throws {
        let snapshot = try syntheticLocalWikiReading()
        for scheme in [ColorScheme.light, .dark] {
            let session = AssistantSession()
            session.readWiki { snapshot }
            try await until { session.localReading != nil }
            let note = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
            note.isRichText = false; note.allowsUndo = true
            let root = AssistantView(session: session, voice: AssistantVoiceSession(),
                contextLabel: snapshot.patient.displayName, startVoice: {}, submit: {
                    Issue.record("Local rendering must not submit a provider request")
                }, close: {}, settings: {})
                .environment(\.colorScheme, scheme)
            let hosted = NSHostingView(rootView: root)
            hosted.frame = NSRect(x: 0, y: 120, width: 520, height: 800)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 920))
            container.addSubview(note); container.addSubview(hosted)
            let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = container
            note.insertText("Nota clínica de ensaio preservada", replacementRange: NSRange(location: 0, length: 0))
            note.setSelectedRange(NSRange(location: 5, length: 7))
            let original = note.string, selection = note.selectedRange(), undo = note.undoManager
            defer { window.contentView = nil; window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            hosted.layoutSubtreeIfNeeded()
            #expect(nativeTexts(in: hosted).contains { $0.contains("Leitura inteiramente sintética") })
            #expect(note.string == original && note.selectedRange() == selection && note.undoManager === undo)
            session.source = snapshot.entries.first
            await Task.detached { PatientClinicalChange.post(for: snapshot.patient) }.value
            try await until { session.localReading == nil }
            #expect(session.source == nil && session.message?.contains("fontes atuais") == true)
            #expect(note.string == original && note.selectedRange() == selection && note.undoManager === undo)
            session.readWiki { snapshot }
            try await until { session.localReading != nil }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try await until { session.localReading == nil }
            var continuation: CheckedContinuation<PatientWikiReadingSnapshot, Never>?
            session.readWiki { await withCheckedContinuation { continuation = $0 } }
            try await until { continuation != nil }
            await Task.detached { PatientClinicalChange.post(for: snapshot.patient) }.value
            try await until { !session.isBusy }
            continuation?.resume(returning: snapshot)
            for _ in 0..<20 { await Task.yield() }
            #expect(session.localReading == nil && !session.isReadingWiki)
            #expect(note.string == original && note.selectedRange() == selection)
            #expect(note.undoManager?.canUndo == true)
            note.undoManager?.undo()
            #expect(note.string.isEmpty)
        }
    }

    private func nativeTexts(in view: NSView) -> [String] {
        (view as? NSTextView).map { [$0.string] } ?? view.subviews.flatMap { nativeTexts(in: $0) }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
