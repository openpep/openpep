// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientWikiStoreTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let encounterID = "enc_0198f5c3-0000-7000-8000-000000000001"
    private let firstHash = String(repeating: "1", count: 64)
    private let secondHash = String(repeating: "2", count: 64)

    @Test("version 2 registration source belongs to this patient only")
    func registrationSourceBinding() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let candidate = PatientWikiSummaryInput(markdown: "Cadastro sintético [F1]", sourceFingerprint: firstHash,
                model: "synthetic", generatedAt: "2026-09-07T12:00:00Z",
                sources: [.init(id: patientID, path: "patient.yaml", sha256: firstHash)],
                overview: "Cadastro sintético [F1]", exclusions: .init())
            let saved = try store.saveSummary(for: patient, input: candidate, expectedData: nil, expectedCorrectionsData: nil)
            let wrong = PatientWikiSummaryInput(markdown: "Outro cadastro", sourceFingerprint: firstHash,
                model: "synthetic", generatedAt: "2026-09-07T12:00:00Z",
                sources: [.init(id: "pt_0198f5c2-0000-7000-8000-000000000099", path: "patient.yaml", sha256: firstHash)],
                overview: "Outro cadastro", exclusions: .init())
            #expect(throws: (any Error).self) {
                try store.saveSummary(for: patient, input: wrong, expectedData: saved.persistedData, expectedCorrectionsData: nil)
            }
            #expect(try store.load(for: patient).summary == saved)
        }
    }

    @Test("version 2 preserves overview and coverage while version 1 stays readable")
    func versionTwoCompatibility() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let legacy = try store.saveSummary(for: patient, input: input(markdown: "Legado", fingerprint: firstHash),
                expectedData: nil, expectedCorrectionsData: nil)
            #expect(legacy.overview == nil)
            var candidate = input(markdown: "# Resumo breve\n\nTexto sintético [F1]", fingerprint: secondHash)
            candidate.overview = "Texto sintético [F1]"
            candidate.exclusions = PatientWikiExclusions(drafts: 1, aiProvenance: 0, unavailable: 2)
            let saved = try store.saveSummary(for: patient, input: candidate,
                expectedData: legacy.persistedData, expectedCorrectionsData: nil)
            #expect(saved.overview == candidate.overview)
            #expect(saved.exclusions == candidate.exclusions)
            #expect(String(decoding: saved.persistedData, as: UTF8.self).contains("openpep/patient-wiki@2"))
            #expect(try store.load(for: patient).summary == saved)
            candidate.exclusions = PatientWikiExclusions(drafts: -1)
            #expect(throws: (any Error).self) {
                try store.saveSummary(for: patient, input: candidate,
                    expectedData: saved.persistedData, expectedCorrectionsData: nil)
            }
            #expect(try store.load(for: patient).summary == saved)
        }
    }

    @Test("version 3 preserves a recoverable prompt identity while older versions stay explicit")
    func versionThreePromptIdentity() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            var candidate = input(markdown: "# Resumo breve\n\nTexto sintético [F1]", fingerprint: firstHash)
            candidate.overview = "Texto sintético [F1]"
            candidate.exclusions = PatientWikiExclusions()
            candidate.promptVersion = AIPromptCatalog.patientWiki.id
            let saved = try store.saveSummary(
                for: patient,
                input: candidate,
                expectedData: nil,
                expectedCorrectionsData: nil
            )
            #expect(saved.promptVersion == AIPromptCatalog.patientWiki.id)
            #expect(String(decoding: saved.persistedData, as: UTF8.self).contains("openpep/patient-wiki@3"))
            #expect(try store.load(for: patient).summary == saved)

            candidate.promptVersion = "openpep/patient-wiki-pt-BR@1"
            let legacyPrompt = try store.saveSummary(
                for: patient,
                input: candidate,
                expectedData: saved.persistedData,
                expectedCorrectionsData: nil
            )
            #expect(legacyPrompt.promptVersion == candidate.promptVersion)
            #expect(try store.load(for: patient).summary == legacyPrompt)

            candidate.promptVersion = AIPromptCatalog.patientHistoryOpenAI.id
            expectRule("wiki.prompt_version") {
                _ = try store.saveSummary(
                    for: patient,
                    input: candidate,
                    expectedData: legacyPrompt.persistedData,
                    expectedCorrectionsData: nil
                )
            }
            #expect(try store.load(for: patient).summary == legacyPrompt)
        }
    }

    @Test("persists an offline summary and preserves human corrections across regeneration")
    func roundTripAndCorrectionsSurviveRegeneration() throws {
        try withPatient { vault, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(
                for: patient,
                markdown: "Manter a preferência registrada pelo profissional.",
                expectedData: nil
            )
            var validatedSources = false
            let first = try store.saveSummary(
                for: patient,
                input: input(markdown: "# Resumo\n\nVersão inicial.", fingerprint: firstHash),
                expectedData: nil,
                expectedCorrectionsData: corrections.persistedData,
                validateSources: { validatedSources = true }
            )
            #expect(validatedSources)

            let reopened = try store.load(for: patient)
            #expect(reopened.summary == first)
            #expect(reopened.corrections == corrections)
            #expect(reopened.summaryIssue == nil)
            #expect(reopened.correctionsIssue == nil)

            let regenerated = try store.saveSummary(
                for: patient,
                input: input(markdown: "# Resumo\n\nVersão regenerada.", fingerprint: secondHash),
                expectedData: first.persistedData,
                expectedCorrectionsData: corrections.persistedData
            )
            let afterRegeneration = try store.load(for: patient)
            #expect(afterRegeneration.summary == regenerated)
            #expect(afterRegeneration.corrections == corrections)
            #expect(try VaultReader().open(vault.url).patients.map(\.patientID) == [patientID])
        }
    }

    @Test("refuses stale summary and corrections bytes")
    func compareAndSwapConflicts() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient, markdown: "Correção A", expectedData: nil)
            let summary = try store.saveSummary(
                for: patient,
                input: input(markdown: "Primeira versão", fingerprint: firstHash),
                expectedData: nil,
                expectedCorrectionsData: corrections.persistedData
            )
            _ = try store.saveCorrections(
                for: patient,
                markdown: "Correção B",
                expectedData: corrections.persistedData
            )

            expectRule("wiki.revision_conflict") {
                _ = try store.saveSummary(
                    for: patient,
                    input: input(markdown: "Não publicar", fingerprint: secondHash),
                    expectedData: summary.persistedData,
                    expectedCorrectionsData: corrections.persistedData
                )
            }
            #expect(try store.load(for: patient).summary == summary)

            expectRule("wiki.revision_conflict") {
                _ = try store.saveCorrections(for: patient, markdown: "Não publicar", expectedData: nil)
            }
        }
    }

    @Test("revalidates sources and corrections at the publication boundary")
    func validatesSourcesInsideCoordinatedPublication() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient, markdown: "Correção A", expectedData: nil)
            expectRule("wiki.revision_conflict") {
                _ = try store.saveSummary(
                    for: patient,
                    input: input(markdown: "Não publicar", fingerprint: firstHash),
                    expectedData: nil,
                    expectedCorrectionsData: corrections.persistedData,
                    validateSources: {
                        try Data("Correção concorrente\n".utf8).write(
                            to: patient.url.appending(path: "wiki/corrections.md"),
                            options: [.atomic]
                        )
                    }
                )
            }
            #expect(try store.load(for: patient).summary == nil)
        }
    }

    @Test("isolates corrupt managed files and ignores unknown wiki content")
    func corruptionIsIsolatedFromClinicalRecord() throws {
        try withPatient { vault, patient in
            let wiki = patient.url.appending(path: "wiki", directoryHint: .isDirectory)
            try Data([0xff, 0x00, 0xfe]).write(to: wiki.appending(path: "summary.md"))
            try Data("Correção legível\n".utf8).write(to: wiki.appending(path: "corrections.md"))
            try FileManager.default.createDirectory(
                at: wiki.appending(path: "future/nested"),
                withIntermediateDirectories: true
            )
            try Data("formato futuro".utf8).write(to: wiki.appending(path: "future/nested/data.bin"))

            let loaded = try PatientWikiStore().load(for: patient)
            #expect(loaded.summary == nil)
            #expect(loaded.summaryIssue != nil)
            #expect(loaded.corrections?.markdown == "Correção legível\n")
            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients.map(\.patientID) == [patientID])
            #expect(reopened.unavailablePatients.isEmpty)
            #expect(reopened.writingAllowed)
        }
    }

    @Test("does not follow a managed wiki symbolic link")
    func symbolicLinkIsIsolated() throws {
        try withPatient { vault, patient in
            let outside = vault.url.deletingLastPathComponent().appending(path: "outside-summary.md")
            let outsideData = Data("outside must remain untouched\n".utf8)
            try outsideData.write(to: outside)
            let summaryURL = patient.url.appending(path: "wiki/summary.md")
            try FileManager.default.createSymbolicLink(at: summaryURL, withDestinationURL: outside)

            let loaded = try PatientWikiStore().load(for: patient)
            #expect(loaded.summary == nil)
            #expect(loaded.summaryIssue != nil)
            expectRule("wiki.revision_conflict") {
                _ = try PatientWikiStore().saveSummary(
                    for: patient,
                    input: input(markdown: "Não publicar", fingerprint: firstHash),
                    expectedData: nil,
                    expectedCorrectionsData: nil
                )
            }
            #expect(try Data(contentsOf: outside) == outsideData)
            #expect(try VaultReader().open(vault.url).patients.map(\.patientID) == [patientID])
        }
    }

    @Test("restores prior summary bytes when publication fails")
    func failedPublicationDoesNotLoseLastVersion() throws {
        try withPatient { _, patient in
            let original = try PatientWikiStore().saveSummary(
                for: patient,
                input: input(markdown: "Versão preservada", fingerprint: firstHash),
                expectedData: nil,
                expectedCorrectionsData: nil
            )
            let failing = PatientWikiStore(faultInjector: { step in
                if step == .published { throw SyntheticWikiFailure() }
            })
            do {
                _ = try failing.saveSummary(
                    for: patient,
                    input: input(markdown: "Versão interrompida", fingerprint: secondHash),
                    expectedData: original.persistedData,
                    expectedCorrectionsData: nil
                )
                Issue.record("a falha injetada deveria interromper a publicação")
            } catch is SyntheticWikiFailure {
                // Expected.
            }
            #expect(try PatientWikiStore().load(for: patient).summary == original)
        }
    }

    @Test("rejects drafts, invalid text hashes and an unsafe wiki directory")
    func validatesBindingsAndDirectory() throws {
        try withPatient { _, patient in
            let invalidSource = PatientWikiSummaryInput(
                markdown: "Resumo",
                sourceFingerprint: firstHash,
                model: "synthetic-model",
                generatedAt: "2026-09-05T12:34:56.123Z",
                sources: [PatientWikiSource(
                    id: encounterID,
                    path: "content/notes/drafts/\(encounterID).md",
                    sha256: "invalid"
                )]
            )
            expectRule("wiki.source_path") {
                _ = try PatientWikiStore().saveSummary(
                    for: patient,
                    input: invalidSource,
                    expectedData: nil,
                    expectedCorrectionsData: nil
                )
            }

            let wiki = patient.url.appending(path: "wiki")
            let outside = patient.url.appending(path: "raw")
            try FileManager.default.removeItem(at: wiki)
            try FileManager.default.createSymbolicLink(at: wiki, withDestinationURL: outside)
            expectRule("filesystem.directory") {
                _ = try PatientWikiStore().load(for: patient)
            }
        }
    }

    @Test("confirmation removes only selected correction occurrences and keeps the summary")
    func confirmedCorrectionsArePartial() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient,
                markdown: "Priorizar cronologia.\nPreservar orientação.\nPriorizar cronologia.", expectedData: nil)
            let summary = try store.saveSummary(for: patient,
                input: input(markdown: "Resumo sintético conferido.", fingerprint: firstHash),
                expectedData: nil, expectedCorrectionsData: corrections.persistedData)
            // Regeneration alone kept every correction; confirmation is separate.
            #expect(try store.load(for: patient).corrections == corrections)
            expectRule("wiki.correction_selection") {
                _ = try store.removeConfirmedCorrectionLines(for: patient, lineIndices: [],
                    generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData)
            }
            #expect(try store.load(for: patient).corrections == corrections)
            let remaining = try store.removeConfirmedCorrectionLines(for: patient, lineIndices: [0],
                generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData)
            #expect(remaining.markdown == "Preservar orientação.\nPriorizar cronologia.\n")
            #expect(try store.load(for: patient).summary == summary)
            #expect(try store.load(for: patient).corrections == remaining)
        }
    }

    @Test("confirmation preserves concurrent corrections or a replacement summary", arguments: [false, true])
    func confirmationRejectsConcurrentChanges(changeSummary: Bool) throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient, markdown: "Correção usada.", expectedData: nil)
            let summary = try store.saveSummary(for: patient,
                input: input(markdown: "Resumo sintético.", fingerprint: firstHash),
                expectedData: nil, expectedCorrectionsData: corrections.persistedData)
            if changeSummary {
                _ = try store.saveSummary(for: patient,
                    input: input(markdown: "Outro resumo.", fingerprint: secondHash),
                    expectedData: summary.persistedData, expectedCorrectionsData: corrections.persistedData)
            } else {
                _ = try store.saveCorrections(for: patient, markdown: "Correção usada.\nCorreção nova.",
                    expectedData: corrections.persistedData)
            }
            let before = try store.load(for: patient)
            expectRule("wiki.revision_conflict") {
                _ = try store.removeConfirmedCorrectionLines(for: patient, lineIndices: [0],
                    generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData)
            }
            #expect(try store.load(for: patient) == before)
        }
    }

    @Test("confirmation rechecks summary at publication and rolls back failed correction writes", arguments: [false, true])
    func confirmationPublicationFailures(changeAtBoundary: Bool) throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient,
                markdown: "Correção usada.\nCorreção mantida.", expectedData: nil)
            let summary = try store.saveSummary(for: patient,
                input: input(markdown: "Resumo sintético.", fingerprint: firstHash),
                expectedData: nil, expectedCorrectionsData: corrections.persistedData)
            let failing = PatientWikiStore(faultInjector: { step in
                if changeAtBoundary, step == .candidateWritten {
                    try Data("Resumo concorrente".utf8).write(to: patient.url.appending(path: "wiki/summary.md"), options: .atomic)
                } else if !changeAtBoundary, step == .published { throw SyntheticWikiFailure() }
            })
            #expect(throws: (any Error).self) {
                _ = try failing.removeConfirmedCorrectionLines(for: patient, lineIndices: [0],
                    generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData)
            }
            #expect(try store.load(for: patient).corrections == corrections)
            if !changeAtBoundary { #expect(try store.load(for: patient).summary == summary) }
        }
    }

    @Test("changed clinical sources refuse confirmation before and during publication", arguments: [0, 1, 2])
    func confirmationRejectsChangedSources(timing: Int) throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient, markdown: "Priorizar cronologia.", expectedData: nil)
            var sourceText = "Fonte clínica inteiramente sintética."
            func currentContext() throws -> PatientWikiContext {
                try PatientWikiContext.make(patient: patient, entries: [PatientHistoryEntry(
                    id: encounterID, title: "Consulta sintética", timestamp: "2026-09-05T12:00:00Z",
                    status: "Finalizada", text: sourceText,
                    source: "content/notes/final/\(encounterID).md", assetID: nil, issue: nil)],
                    corrections: corrections.markdown)
            }
            let generatedContext = try currentContext()
            let summary = try store.saveSummary(for: patient,
                input: input(markdown: "Resumo sintético conferido.", fingerprint: generatedContext.fingerprint),
                expectedData: nil, expectedCorrectionsData: corrections.persistedData)
            if timing == 0 { sourceText = "Fonte clínica sintética alterada." }
            let checking = PatientWikiStore(faultInjector: { step in
                if (timing == 1 && step == .candidateWritten) || (timing == 2 && step == .published) {
                    sourceText = "Fonte clínica sintética alterada."
                }
            })
            #expect(throws: PatientAIIssue.self) {
                _ = try checking.removeConfirmedCorrectionLines(for: patient, lineIndices: [0],
                    generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData,
                    validateSources: {
                        guard try currentContext().fingerprint == generatedContext.fingerprint else { throw PatientAIIssue.changed }
                    })
            }
            #expect(try store.load(for: patient).corrections == corrections)
            #expect(try store.load(for: patient).summary == summary)
        }
    }

    @Test("a summary changed after correction publication rolls the correction write back")
    func confirmationRechecksPublishedCompanion() throws {
        try withPatient { _, patient in
            let store = PatientWikiStore()
            let corrections = try store.saveCorrections(for: patient, markdown: "Correção sintética.", expectedData: nil)
            let summary = try store.saveSummary(for: patient,
                input: input(markdown: "Resumo sintético.", fingerprint: firstHash),
                expectedData: nil, expectedCorrectionsData: corrections.persistedData)
            let concurrent = Data("Resumo concorrente preservado".utf8)
            let checking = PatientWikiStore(faultInjector: { step in
                if step == .published {
                    try concurrent.write(to: patient.url.appending(path: "wiki/summary.md"), options: .atomic)
                }
            })
            expectRule("wiki.revision_conflict") {
                _ = try checking.removeConfirmedCorrectionLines(for: patient, lineIndices: [0],
                    generatedSummaryData: summary.persistedData, usedCorrectionsData: corrections.persistedData)
            }
            #expect(try store.load(for: patient).corrections == corrections)
            #expect(try Data(contentsOf: patient.url.appending(path: "wiki/summary.md")) == concurrent)
        }
    }

    private func input(markdown: String, fingerprint: String) -> PatientWikiSummaryInput {
        PatientWikiSummaryInput(
            markdown: markdown,
            sourceFingerprint: fingerprint,
            model: "synthetic-model",
            generatedAt: "2026-09-05T12:34:56.123Z",
            sources: [PatientWikiSource(
                id: encounterID,
                path: "content/notes/final/\(encounterID).md",
                // Hash of the extracted source text supplied to the model.
                sha256: String(repeating: "a", count: 64)
            )]
        )
    }

    private func expectRule(_ rule: String, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("a operação deveria falhar com \(rule)")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == rule)
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
    }

    private func withPatient(_ body: (VaultSummary, PatientSummary) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-wiki-tests-\(UUID().uuidString)",
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
            identity: PatientCreationIdentity(patientID: patientID),
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
        try body(try VaultReader().open(vault.url), patient)
    }
}

private struct SyntheticWikiFailure: Error {}
