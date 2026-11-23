// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct FinalizedNoteAccessibilityTests {
    @Test("finalized note exposes readable accessibility labels without recursive overrides")
    func finalizedNoteCanBeRead() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-finalized-accessibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try SyntheticReleaseSeeder().seed(in: root, at: Date(timeIntervalSince1970: 1_788_195_600))
        let patient = try #require(vault.patients.first)
        let encounter = try #require(patient.encounters.first)
        guard case let .verified(finalization) = encounter.finalizationStatus else { Issue.record("Expected verified synthetic final note"); return }
        let view = NSHostingView(rootView: ContentView(previewVault: vault,
            previewEncounterPatientID: patient.patientID, previewEncounterID: encounter.metadata.encounterID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        view.layoutSubtreeIfNeeded()
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        // SwiftUI's accessibility nodes implement the selectors without always
        // declaring conformance to the full AppKit accessibility protocol.
        func read(_ object: Any, depth: Int = 0) {
            guard depth < 60, let element = object as? NSObject,
                  visited.insert(ObjectIdentifier(element)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if element.responds(to: selector),
                   let label = element.perform(selector)?.takeUnretainedValue() as? String { labels.append(label) }
            }
            for attribute in [NSAccessibility.Attribute.title, .value, .description] {
                if let text = element.accessibilityAttributeValue(attribute) as? String { labels.append(text) }
            }
            for child in element.accessibilityAttributeValue(.children) as? [Any] ?? [] { read(child, depth: depth + 1) }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: childrenSelector),
               let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
                for child in children { read(child, depth: depth + 1) }
            }
            if let native = element as? NSView {
                for child in native.subviews { read(child, depth: depth + 1) }
            }
        }
        read(view)
        #expect(visited.count > 5)
        #expect(labels.contains(ClinicalTextPresentation.clean(finalization.finalNote.body)))
    }
}
