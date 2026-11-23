// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import OpenPEP

@Suite("ASSISTANT-001 native focus and prompt keyboard", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OPENPEP_ASSISTANT_UI_TESTS"] == "1"))
@MainActor struct AssistantPanelTests {
    @Test func closePreservesDraftSelectionAndUndo() async throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let editor = NSTextView(frame: window.contentLayoutRect)
        editor.isRichText = false; editor.allowsUndo = true
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(editor)
        editor.insertText("Rascunho sintético sem quebra", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 3, length: 5))
        let text = editor.string, selection = editor.selectedRange(), undo = editor.undoManager
        let controller = AssistantPanelController(); controller.owner = window
        defer { controller.close(restoreFocus: false); window.orderOut(nil) }
        var submitted = 0
        controller.show(submit: { submitted += 1 }, settings: {})
        let panel = try #require(window.childWindows?.first as? NSPanel)
        try await until { panel.firstResponder is NSTextView }
        // This host is not activated by macOS. Check native responder state;
        // actual key-window activation and the app-menu shortcut need manual acceptance.
        #expect(controller.isPresented && panel.canBecomeKey)
        if !NSApp.isActive { #expect(!controller.canNavigate) }
        let input = try #require(panel.firstResponder as? NSTextView)
        input.insertText("Busque Ana Fictícia", replacementRange: NSRange(location: 0, length: 0))
        try sendReturn(to: panel, modifiers: .shift)
        #expect(submitted == 0)
        #expect(input.string.contains("\n"))
        try sendReturn(to: panel)
        #expect(submitted == 1)
        #expect(editor.string == text && editor.selectedRange() == selection)
        controller.close()
        #expect(window.firstResponder === editor)
        #expect(editor.string == text && editor.selectedRange() == selection)
        #expect(editor.undoManager === undo && editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string.isEmpty)
    }

    @Test func panelAboveSheetDoesNotAllowNavigation() async throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.beginSheet(sheet, completionHandler: { _ in })
        let controller = AssistantPanelController(); controller.owner = window
        defer { controller.close(restoreFocus: false); window.endSheet(sheet); sheet.orderOut(nil); window.orderOut(nil) }
        controller.show(submit: {}, settings: {})
        let panel = try #require(sheet.childWindows?.first as? NSPanel)
        try await until { panel.isVisible }
        #expect(controller.isPresented && !controller.canNavigate)
        #expect(window.attachedSheet === sheet)
    }

    @Test func homePromptSubmitsOnceWithoutTypingInDraft() throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let draft = NSTextView(frame: window.contentLayoutRect)
        draft.string = "Rascunho sintético preservado"
        window.contentView = draft; window.orderFront(nil)
        let controller = AssistantPanelController(); controller.owner = window
        defer { controller.close(restoreFocus: false); window.orderOut(nil) }
        var submitted: [String] = []
        controller.show(initialPrompt: "Busque Ana Fictícia", autoSubmit: true,
                        submit: { submitted.append(controller.session.prompt) }, settings: {})
        #expect(submitted == ["Busque Ana Fictícia"])
        #expect(draft.string == "Rascunho sintético preservado")
        controller.show(submit: { submitted.append("unexpected") }, settings: {})
        #expect(submitted.count == 1)
    }

    private func sendReturn(to window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(event)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
