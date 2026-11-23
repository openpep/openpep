// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct PatientRegistrationLayoutTests {
    @Test("registration fits narrow and regular windows")
    func renders() async throws {
        for (width, scheme) in [(560.0, ColorScheme.light), (760.0, ColorScheme.dark)] {
            let root = PatientFormView(title: "Novo paciente", record: nil,
                onCancel: {}, onSave: { _ in }, duplicateNames: { _ in [] })
                .frame(width: width, height: 1000)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            #expect(view.fittingSize.width <= width)
            if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appending(path: "registration-\(Int(width)).png"))
            }
            window.orderOut(nil)
        }
    }
}

extension PatientRegistrationLayoutTests {
    @Test("appointment calendar and patient next steps fit a medium window")
    func journeyModals() async throws {
        let controller = GoogleMeetIntegrationController(service: GoogleMeetService(
            credentials: .init(read: { _ in nil }, save: { _, _ in }, delete: { _ in })))
        let appointment = AppointmentFormView(title: "Novo agendamento", patients: [], appointment: nil,
            defaultDate: Date(timeIntervalSince1970: 1_788_804_000), googleMeetController: controller,
            onCancel: {}, onCancelAppointment: nil, onSave: { _ in }, onSaveAndShare: { _, _ in },
            onOpenConsultation: nil, conflicts: { _ in [] }, onCreatePatient: { _ in throw ConsultationFieldsError.ambiguous },
            duplicatePatientNames: { _ in [] }, onImportDocuments: { _, _, _ in 0 })
        let actions = NewPatientActionsView(patientName: "Marina Almeida", onStart: {}, onSchedule: {}, onDocuments: {}, onClose: {})
        let link = EncounterRemoteLinkView(patientName: "Marina Almeida", initialLink: "https://meet.google.com/aaa-bbbb-ccc",
            appointmentLabel: "Agendada · 07/09/2026, 09:00", controller: controller, onCancel: {},
            onSave: { _ in Issue.record("An existing link must not be written again") }, onPerform: { _, _ in })
        for (name, root, width, height) in [("appointment", AnyView(appointment), 680.0, 900.0),
            ("patient-next-steps", AnyView(actions), 680.0, 300.0), ("video-link", AnyView(link), 640.0, 360.0)] {
            let view = NSHostingView(rootView: root.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = view
            window.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            #expect(view.fittingSize.width <= width)
            if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: name + ".png"))
            }
            window.orderOut(nil)
        }
    }
}
