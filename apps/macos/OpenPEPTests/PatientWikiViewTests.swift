// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
import Vision
@testable import OpenPEP

@Suite("Patient wiki and timeline SwiftUI rendering")
struct PatientWikiViewTests {
    @Test("wiki sections have stable topic identities and preserve inline source markers")
    func parsesExpandableWikiSections() {
        let summary = PatientWikiSummary(markdown: """
        # Resumo breve

        Uma linha sintética. [F1]

        ## Problemas registrados

        Texto sintético do problema. [F2]

        ## Exames

        Resultado sintético. [F3]
        """, sourceFingerprint: String(repeating: "a", count: 64), model: "synthetic",
            generatedAt: "2026-09-07T12:00:00Z", sources: [], overview: "Uma linha sintética. [F1]",
            exclusions: nil, proposals: [], persistedData: Data())

        let sections = PatientWikiMarkdownPresentation.sections(summary: summary)
        #expect(sections.map(\.id) == ["overview", "topic-problemas-registrados", "topic-exames"])
        #expect(sections.filter(\.isOverview).count == 1)
        #expect(sections.allSatisfy { !$0.text.isEmpty })
        #expect(PatientWikiMarkdownPresentation.sourceLabels(in: sections[0].text) == ["F1"])
        #expect(PatientWikiMarkdownPresentation.cleanSourceLabels(sections[1].text) == "Texto sintético do problema.")
    }

    @MainActor
    @Test(
        "renders wiki, app roots and embedded timeline while environment and layout update",
        arguments: [0, 1, 2, 3]
    )
    func rendersPersistedWikiAcrossUpdates(variant: Int) async throws {
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
        let refreshedPatient = try #require(refreshedVault.patients.first)

        let defaultsName = "openpep-wiki-view-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(false, forKey: AITextSettings.enabledKey)
        defaults.set(false, forKey: AITextSettings.autoWikiKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let context = PatientHistoryContext(
            patientID: patient.patientID,
            patientName: patient.displayName,
            vaultURL: vault.url,
            authorizationURL: vault.url
        )
        let makeRoot: (ColorScheme, DynamicTypeSize) -> AnyView = { scheme, typeSize in
            if variant == 1 {
                AnyView(
                    ContentView(
                        previewVault: refreshedVault,
                        previewPatientID: patient.patientID
                    )
                    .frame(width: 860, height: 760)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .defaultAppStorage(defaults)
                )
            } else if variant == 2 {
                AnyView(
                    ContentView(
                        previewVault: refreshedVault,
                        previewPatientID: nil
                    )
                    .frame(width: 860, height: 760)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .defaultAppStorage(defaults)
                )
            } else if variant == 3 {
                AnyView(
                    ScrollView {
                        PatientHistoryView(
                            context: context,
                            onOpen: { _ in },
                            onClose: {},
                            isEmbedded: true,
                            patientRevision: refreshedPatient
                        )
                        .padding(24)
                    }
                    .frame(maxWidth: .infinity, minHeight: 760)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .defaultAppStorage(defaults)
                )
            } else {
                AnyView(
                    ScrollView {
                        PatientWikiView(
                            patient: patient,
                            context: context,
                            canWrite: true
                        )
                        .padding(24)
                    }
                    .frame(width: 860, height: 760)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .defaultAppStorage(defaults)
                )
            }
        }

        let hostingView = NSHostingView(rootView: makeRoot(.light, .large).background(Color.white))
        hostingView.frame = NSRect(x: 0, y: 0, width: variant == 3 ? 1000 : 860, height: 760)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        if variant == 0 { window.orderFront(nil) }
        defer { window.orderOut(nil) }

        for index in 0..<24 {
            try await Task.sleep(for: .milliseconds(20))
            hostingView.rootView = makeRoot(
                index.isMultiple(of: 2) ? .dark : .light,
                index.isMultiple(of: 3) ? .accessibility2 : .large
            ).background(Color.white)
            hostingView.frame.size.width = index.isMultiple(of: 2)
                ? (variant == 3 ? 620 : 720)
                : (variant == 3 ? 1000 : 860)
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
        }

        if variant == 0 {
            // Keep the same mounted view: a committed wiki change must replace its displayed snapshot.
            let store = PatientWikiStore()
            let before = try store.load(for: patient)
            _ = try store.saveSummary(for: patient,
                input: PatientWikiSummaryInput(markdown: "Síntese sintética atualizada pelo evento local.",
                    sourceFingerprint: String(repeating: "c", count: 64), model: "synthetic-model",
                    generatedAt: "2026-09-10T12:00:00Z", sources: []),
                expectedData: before.summary?.persistedData, expectedCorrectionsData: before.corrections?.persistedData)
            var displayed = ""
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(200))
                hostingView.layoutSubtreeIfNeeded()
                displayed = try renderedText(hostingView)
                if displayed.localizedStandardContains("10 de set") { break }
            }
            // The IPS is primary: a changed generated-at label proves the mounted snapshot refreshed.
            // The narrative remains collapsed until explicitly opened.
            #expect(displayed.localizedStandardContains("10 de set"))
            #expect(!displayed.localizedStandardContains("evento local"))
        }

        #expect(hostingView.fittingSize.width > 0)
        #expect(hostingView.fittingSize.height > 0)
        window.contentView = nil
    }

    @MainActor
    private func renderedText(_ view: NSView) throws -> String {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/openpep-wiki-live-refresh.png"), options: .atomic)
        }
        let image = try #require(bitmap.cgImage)
        let request = try makeWikiScreenshotTextRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private var syntheticSummary: String {
        """
        ## Contexto

        Paciente inteiramente sintético, acompanhado apenas para reproduzir a composição SwiftUI [F1].

        ## Problemas registrados

        - Informação sintética com **ênfase**.
        - Negação sintética preservada.

        ## Evolução

        Texto sintético com data 05/09/2026 e referência [F1].

        ## Pendências documentadas

        Nenhuma conduta real foi registrada neste teste.
        """
    }
}
