// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct LayoutPolishTests {
    @Test("home, populated diagnoses and settings fit compact and wide layouts")
    func layouts() async throws {
        var profile = DoctorProfile()
        profile.preferredName = "Dr. Carlos"
        var fields = try ConsultationFields.read(from: "Nota sintética.")
        fields.items.append(.init(kind: .diagnosis, values: [.code: "I25", .title: "Doença isquêmica crônica do coração", .course: "Crônico"]))
        let body = try fields.replacing(in: "Nota sintética.")
        for (name, width, height, root) in [
            ("home", 1000.0, 700.0, AnyView(HomeView(searchText: .constant(""), canWrite: true,
                onStartEncounter: {}, onOpenAgenda: {}, onIssueDocument: {}, onSearch: {}, doctorProfile: profile))),
            ("diagnoses", 520.0, 160.0, AnyView(DiagnosisEditor(bodyText: .constant(body)).padding(20))),
            ("settings", 760.0, 900.0, AnyView(SettingsIndexView(onOpen: { _ in })))
        ] {
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView: root.frame(width: width, height: height)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = view
                window.orderFront(nil)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                #expect(view.fittingSize.width <= width)
                if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(
                        to: directory.appending(path: "polish-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
                window.orderOut(nil)
            }
        }
    }
}
