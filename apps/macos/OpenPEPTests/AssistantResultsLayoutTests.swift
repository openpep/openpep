// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
import Vision
@testable import OpenPEP

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENPEP_ASSISTANT_UI_TESTS"] == "1"))
@MainActor struct AssistantResultsLayoutTests {
    @Test func filteredListActuallyDisplaysCandidates() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "assistant-results-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try VaultCreator().create(in: directory, identity: .init(
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
            deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: Date())
        for (index, name) in ["Ana Fictícia", "José Sintético", "José Sintético", "Outro Exemplo"].enumerated() {
            _ = try PatientCreator().createRegistered(in: vault.url,
                identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-00000000000\(index + 1)"),
                input: .init(fullName: name, preferredName: nil, birthDate: "199\(index)-01-01", contacts: [], identifiers: [], alerts: []))
        }
        let loaded = try VaultReader().open(vault.url)
        let suite = "assistant-results-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AITextSettings.enabledKey)
        defaults.set(false, forKey: AITextSettings.autoWikiKey)
        for (query, expectedName, count, history) in [
            ("Ana Fictícia", "Ana Fictícia", 1, false),
            ("José Sintético", "José Sintético", 2, false),
            ("José Sintetco", "José Sintético", 2, false),
            ("José Sintético", "José Sintético", 2, true)
        ] {
            let matches = AssistantPatientMatches.resolve(query, in: loaded.patients)
            let filter = AssistantPatientFilter(query: query, matches: matches, opensHistory: history)
            #expect(filter.patientIDs.count == count)
            let root = ContentView(previewVault: loaded, previewPatientID: nil, previewAssistantFilter: filter)
                .frame(width: 1000, height: 820)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.light).defaultAppStorage(defaults)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            // Check rendered rows: the reported regression passed model tests
            // but drew no candidates. This request is local and sees synthetic pixels only.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["pt-BR"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .map { $0.precomposedStringWithCanonicalMapping }
            #expect(labels.contains { $0.contains(expectedName) })
            #expect(!labels.contains { $0.contains("Outro Exemplo") })
            if expectedName == "José Sintético" {
                #expect(!labels.contains { $0.contains("Ana Fictícia") })
                // Exclude the search field; name and age may be separate OCR observations.
                let visibleNames = (request.results ?? []).filter {
                    $0.boundingBox.midY < 0.84 &&
                    $0.topCandidates(1).first?.string.precomposedStringWithCanonicalMapping.contains("José Sintético") == true
                }
                #expect(visibleNames.count == 2)
            }
            if history { #expect(labels.filter { $0.contains("Ver histórico") }.count == 2) }
            if let output = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let path = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])).write(to: path.appending(path: "assistant-results-\(query)-\(history ? "history" : "patient").png"))
            }
        }
    }
    @Test func answerAndSourceRemainVisibleInTheSamePanel() async throws {
        let session = AssistantSession(), voice = AssistantVoiceSession()
        let patient = PatientSummary(patientID: "synthetic", url: URL(fileURLWithPath: "/synthetic"),
                                     record: nil, rawAssets: [], encounters: [])
        session.prompt = "Como está a função renal deste paciente?"
        session.submit(interpret: { _ in .askPatient("") },
            resolve: { _ in .init(patients: [patient], approximate: false) }, navigate: { _, _ in Issue.record("Unexpected navigation") },
            answer: { _, _ in syntheticAssistantAnswer() })
        while session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let answer = try #require(session.answer)
        let suite = "assistant-answer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AITextSettings.enabledKey)
        defaults.set(true, forKey: AITextSettings.assistantEnabledKey)
        let host = NSHostingView(rootView: AssistantView(session: session, voice: voice,
            contextLabel: "Ana Fictícia", startVoice: {}, submit: {}, close: {}, settings: {})
            .defaultAppStorage(defaults).preferredColorScheme(.light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
        defer { window.orderOut(nil) }
        for mode in ["answer", "source", "return"] {
            session.source = mode == "source" ? answer.entries[0] : nil
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["pt-BR"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").precomposedStringWithCanonicalMapping
            #expect(labels.contains("Enviar") && !labels.contains("Busca comum") && !labels.contains("OpenAI"))
            #expect(labels.contains(mode == "source" ? "Voltar à resposta" : "Fontes da resposta"))
            #expect(labels.contains("1,0 mg/dL"))
            if let output = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let path = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: path.appending(path: "assistant-\(mode).png"))
            }
        }
    }

}

extension AssistantResultsLayoutTests {
    @Test func wikiIsReadableOfflineAndHasPatientPicker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wiki-browser-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try SyntheticReleaseSeeder().seed(in: root, at: Date())
        let patient = try #require(vault.patients.first)
        let before = try #require(PatientWikiStore().load(for: patient).summary).persistedData
        let suite = "wiki-browser-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AITextSettings.enabledKey)
        defaults.set(true, forKey: AITextSettings.autoWikiKey)
        for patientID in [nil, patient.patientID] as [String?] {
            let host = NSHostingView(rootView: PatientWikiBrowser(vault: vault, authorizationURL: root,
                initialPatientID: patientID, onClose: {}).defaultAppStorage(defaults)
                .preferredColorScheme(.light).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["pt-BR"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").precomposedStringWithCanonicalMapping
            // Text recognition may return the window title in lower case.
            #expect(labels.localizedCaseInsensitiveContains("Wiki") && labels.contains("Fechar"))
            #expect(labels.contains(patient.displayName))
            #expect(labels.contains(patientID == nil ? "Escolha um paciente" : "Resumo Internacional do Paciente"))
            if patientID != nil {
                // The IPS is the main view: items are proposals until the professional confirms them.
                #expect(labels.contains("Confirme ou ajuste cada informação"))
                #expect(!labels.contains("Um resumo com fontes ficará disponível"))
            }
            #expect(try PatientWikiStore().load(for: patient).summary?.persistedData == before)
            if let output = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appending(path: patientID == nil ? "wiki-picker.png" : "wiki-reader.png"))
            }
        }
    }
}
