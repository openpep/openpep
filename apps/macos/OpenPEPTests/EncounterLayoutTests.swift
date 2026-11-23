// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct EncounterLayoutTests {
    private let syntheticSummary = "Acompanhamento clínico sintético.\nRetorno previsto em três meses."
    @Test("renders consultation at half screen and full width in both appearances", arguments: [false, true])
    func rendersEncounter(withTranscription: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-wiki-view-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = try VaultCreator().create(
            in: directory,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")!
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(
                patientID: "pt_0198f5c2-0000-7000-8000-000000000001"
            ),
            input: PatientRecordInput(
                fullName: "Paciente Wiki Sintético",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: ISO8601DateFormatter().date(from: "2026-09-05T12:01:00Z")!
        )
        _ = try PatientWikiStore().saveSummary(
            for: patient,
            input: PatientWikiSummaryInput(
                markdown: syntheticSummary,
                sourceFingerprint: String(repeating: "a", count: 64),
                model: "synthetic-model",
                generatedAt: "2026-09-05T12:34:56Z",
                sources: [PatientWikiSource(
                    id: "enc_0198f5c3-0000-7000-8000-000000000001",
                    path: "content/notes/final/note_0198f5c3-0000-7000-8000-000000000001.md",
                    sha256: String(repeating: "b", count: 64)
                )]
            ),
            expectedData: nil,
            expectedCorrectionsData: nil
        )
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: "enc_0198f5c4-0000-7000-8000-000000000001",
                noteID: "note_0198f5c5-0000-7000-8000-000000000001",
                syntheticActorID: "usr_0198f5c6-0000-7000-8000-000000000001"
            ),
            startedAt: ISO8601DateFormatter().date(from: "2026-09-05T12:02:00Z")!
        )
        let draftVault = try VaultReader().open(vault.url)
        let draftPatient = try #require(draftVault.patients.first)
        let draftEncounter = try #require(draftPatient.encounters.first)
        _ = try ClinicalDraftSaver().save(
            encounter: draftEncounter,
            patientID: patient.patientID,
            body: "Evolução sintética persistida para a linha do tempo incorporada.",
            updatedAt: ISO8601DateFormatter().date(from: "2026-09-05T12:03:00Z")!
        )
        let refreshedVault = try VaultReader().open(vault.url)

        let defaultsName = "openpep-wiki-view-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(false, forKey: AITextSettings.enabledKey)
        defaults.set(false, forKey: AITextSettings.autoWikiKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }


        let session = EncounterTranscriptionSession()
        defer { session.shutdown() }
        if withTranscription {
            let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            var fixture = try String(contentsOf: repository.appending(path:
                "fixtures/progressive-summary-work-v2/valid/incremental/work.json"), encoding: .utf8)
            fixture = fixture.replacingOccurrences(of: "vlt_0198f7a1-0000-4000-8000-000000000002", with: refreshedVault.manifest.vaultID)
                .replacingOccurrences(of: "pt_0198f7a2-0000-7000-8000-000000000002", with: patient.patientID)
                .replacingOccurrences(of: "enc_0198f7a3-0000-7000-8000-000000000002", with: draftEncounter.metadata.encounterID)
            let data = Data(fixture.utf8)
            let work = try ProgressiveConsultationWorkStore().decode(data: data)
            #expect(session.prepare(binding: .init(vaultURL: refreshedVault.url,
                vaultID: refreshedVault.manifest.vaultID, patientID: patient.patientID,
                encounterID: draftEncounter.metadata.encounterID, patientName: "Paciente Wiki Sintético"),
                onPersist: { _, _, _ in }, onLoadWork: { (work, data) }, onPersistWork: { _, _ in data }))
        }

        for (name, width, height, scheme) in [
            ("half-light", 820.0, 760.0, ColorScheme.light),
            ("medium-light", 1280.0, 850.0, ColorScheme.light),
            ("full-light", 1720.0, 980.0, ColorScheme.light),
            ("half-dark", 820.0, 760.0, ColorScheme.dark),
            ("full-dark", 1720.0, 980.0, ColorScheme.dark),
        ] {
            let root = ContentView(previewVault: refreshedVault, previewEncounterPatientID: patient.patientID,
                                   previewEncounterID: draftEncounter.metadata.encounterID, previewTranscriptionSession: session, previewDocuments: withTranscription)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(defaults)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            #expect(view.fittingSize.width <= width)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appending(path: "encounter-\(withTranscription ? "transcription-" : "")\(name).png"))
            }
            window.orderOut(nil)
        }
    }
}
