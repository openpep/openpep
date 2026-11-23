// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import OpenPEP

@Suite("Direct document import batches")
struct DocumentImportBatchTests {
    private let date = ISO8601DateFormatter().date(from: "2026-09-05T18:00:00Z")!
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000031"
    private let encounterID = "enc_0198f5d1-0000-7000-8000-000000000031"

    @Test("imports multiple formats only to the selected patient")
    @MainActor
    func importsToPatient() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let text = Data("Documento sintético com acentuação.\n".utf8)
        let pdf = Data("%PDF-1.7\n% arquivo sintético\n%%EOF\n".utf8)
        let textURL = try writeSource("registro-sintético.txt", data: text, in: context.root)
        let pdfURL = try writeSource("registro-sintético.pdf", data: pdf, in: context.root)
        let droppedURLs = [textURL, pdfURL].compactMap { PatientFileDropModifier.fileURL(from: $0.dataRepresentation) }
        #expect(droppedURLs == [textURL, pdfURL])
        let items = [
            item(droppedURLs[0], suffix: 1),
            item(droppedURLs[1], suffix: 2),
        ]

        let changes = ClinicalChangeRecorder(patientURL: context.patient.url)
        let result = DocumentImportBatch().run(
            items: items,
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date
        )

        #expect(result.succeeded)
        #expect(changes.count == 2)
        #expect(result.completed.map(\.item) == items)
        #expect(result.pending.isEmpty)
        #expect(result.failure == nil)
        let reopened = try VaultReader().open(context.vault.url)
        let assets = try #require(reopened.patients.first).rawAssets
        let unchangedText = try Data(contentsOf: textURL)
        let unchangedPDF = try Data(contentsOf: pdfURL)
        #expect(assets.count == 2)
        #expect(assets.allSatisfy { $0.encounterID == nil })
        #expect(unchangedText == text)
        #expect(unchangedPDF == pdf)
    }

    @Test("copies opaque, extensionless and empty files into raw without changing bytes")
    func importsAnyFileFormat() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        for (index, sample) in [("arquivo.zip", Data([0, 255, 1])), ("SEMEXTENSAO", Data([3, 2, 1])), ("vazio.txt", Data()), ("arquivo.null", Data([4]))].enumerated() {
            let source = try writeSource(sample.0, data: sample.1, in: context.root)
            let result = DocumentImportBatch().run(items: [item(source, suffix: 50 + index)],
                in: context.vault.url, expectedVaultID: context.vault.manifest.vaultID,
                patientID: patientID, encounterID: nil, importedAt: date)
            #expect(result.succeeded)
            let reopened = try VaultReader().open(context.vault.url)
            let asset = try #require(reopened.patients.first?.rawAssets.first(where: { $0.originalName == sample.0 }))
            #expect(asset.originalURL.path.contains("/raw/"))
            #expect(asset.mediaType == "application/octet-stream")
            #expect(try Data(contentsOf: asset.originalURL) == sample.1)
            #expect(try Data(contentsOf: source) == sample.1)
        }
    }

    @Test("imports to one encounter and refuses that destination after it is trashed")
    func importsToEncounterAndRefusesTrash() throws {
        var context = try makeContext(encounter: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let sourceData = Data("Documento vinculado à consulta sintética.\n".utf8)
        let sourceURL = try writeSource("consulta.txt", data: sourceData, in: context.root)
        let importItem = item(sourceURL, suffix: 3)
        let changes = ClinicalChangeRecorder(patientURL: context.patient.url)
        let imported = DocumentImportBatch().run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: encounterID,
            importedAt: date
        )
        #expect(imported.succeeded)
        #expect(changes.count == 0)

        context = try reopen(context)
        let asset = try #require(context.patient.rawAssets.first)
        #expect(asset.encounterID == encounterID)
        let encounter = try #require(context.patient.encounters.first)
        let moved = try DraftTrashService().discard(
            in: context.vault,
            patient: context.patient,
            encounter: encounter,
            expectedData: Data(contentsOf: encounter.url),
            at: date.addingTimeInterval(60)
        )
        #expect(moved)

        let retry = DocumentImportBatch().run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: encounterID,
            importedAt: date.addingTimeInterval(120)
        )
        #expect(retry.completed.isEmpty)
        #expect(retry.pending == [importItem])
        #expect(retry.failure?.rule == "document_import_batch.encounter_unavailable")
        let afterTrash = try VaultReader().open(context.vault.url)
        let unchangedSource = try Data(contentsOf: sourceURL)
        #expect(afterTrash.patients.first?.rawAssets.isEmpty == true)
        #expect(afterTrash.patients.first?.trashedRawAssets.map(\.assetID) == [importItem.identity.assetID])
        #expect(unchangedSource == sourceData)
    }

    @Test("an invalid file reports completed and pending items without touching sources")
    func invalidFileReturnsPartialResult() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let firstData = Data("Primeiro documento sintético.\n".utf8)
        let invalidData = Data(count: DocumentImportDescriptor.maximumBytes + 1)
        let lastData = Data("Documento pendente sintético.\n".utf8)
        let firstURL = try writeSource("primeiro.txt", data: firstData, in: context.root)
        let invalidURL = try writeSource("inválido.pdf", data: invalidData, in: context.root)
        let lastURL = try writeSource("último.txt", data: lastData, in: context.root)
        let items = [
            item(firstURL, suffix: 4),
            item(invalidURL, suffix: 5),
            item(lastURL, suffix: 6),
        ]

        let result = DocumentImportBatch().run(
            items: items,
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date
        )
        #expect(result.completed.map(\.item) == [items[0]])
        #expect(result.pending == Array(items.dropFirst()))
        #expect(result.failure?.rule == "document_import.source")

        let retry = DocumentImportBatch().run(
            items: [items[2]],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date.addingTimeInterval(60)
        )
        #expect(retry.succeeded)
        let reopened = try VaultReader().open(context.vault.url)
        let reopenedAssets = try #require(reopened.patients.first).rawAssets
        let unchangedFirst = try Data(contentsOf: firstURL)
        let unchangedInvalid = try Data(contentsOf: invalidURL)
        let unchangedLast = try Data(contentsOf: lastURL)
        #expect(Set(reopenedAssets.map(\.assetID)) == Set([
            items[0].identity.assetID,
            items[2].identity.assetID,
        ]))
        #expect(unchangedFirst == firstData)
        #expect(unchangedInvalid == invalidData)
        #expect(unchangedLast == lastData)
    }

    @Test("retry reuses an item published before a reread failure and detects later source changes")
    func partialPublicationRetryAndConflict() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let original = Data("Conteúdo estável da tentativa sintética.\n".utf8)
        let sourceURL = try writeSource("tentativa.txt", data: original, in: context.root)
        let importItem = item(sourceURL, suffix: 7)
        let failing = DocumentImportBatch(faultInjector: { step in
            if step == .itemPublished(importItem.identity.assetID) {
                throw SyntheticBatchFailure()
            }
        })

        let partial = failing.run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date
        )
        #expect(partial.completed.isEmpty)
        #expect(partial.pending == [importItem])
        #expect(partial.failure?.rule == "document_import_batch.failed")
        var reopened = try VaultReader().open(context.vault.url)
        #expect(reopened.patients.first?.rawAssets.map(\.assetID) == [importItem.identity.assetID])

        let retry = DocumentImportBatch().run(
            items: partial.pending,
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date.addingTimeInterval(60)
        )
        #expect(retry.succeeded)
        reopened = try VaultReader().open(context.vault.url)
        let stored = try #require(reopened.patients.first?.rawAssets.first)
        let storedAfterRetry = try Data(contentsOf: stored.originalURL)
        #expect(storedAfterRetry == original)

        let changed = Data("Fonte alterada depois da publicação.\n".utf8)
        try changed.write(to: sourceURL, options: [.atomic])
        let conflict = DocumentImportBatch().run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date.addingTimeInterval(120)
        )
        #expect(conflict.completed.isEmpty)
        #expect(conflict.pending == [importItem])
        #expect(conflict.failure?.rule == "document_import_batch.identity_conflict")
        let storedAfterConflict = try Data(contentsOf: stored.originalURL)
        let sourceAfterConflict = try Data(contentsOf: sourceURL)
        #expect(storedAfterConflict == original)
        #expect(sourceAfterConflict == changed)
    }

    @Test("a changed vault identity refuses every pending item")
    func changedVault() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let sourceURL = try writeSource("troca-vault.txt", data: Data("Sintético.\n".utf8), in: context.root)
        let importItem = item(sourceURL, suffix: 8)
        try replaceVaultID(
            at: context.vault.url,
            from: context.vault.manifest.vaultID,
            to: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a220"
        )

        let result = DocumentImportBatch().run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date
        )
        #expect(result.completed.isEmpty)
        #expect(result.pending == [importItem])
        #expect(result.failure?.rule == "document_import_batch.vault_changed")
        let reopened = try VaultReader().open(context.vault.url)
        #expect(reopened.patients.first?.rawAssets.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("an archived patient refuses every pending item")
    func archivedPatient() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let record = try #require(context.patient.record)
        _ = try PatientEditor().update(
            patient: context.patient,
            input: PatientRecordInput(
                fullName: record.fullName ?? "",
                preferredName: record.preferredName,
                birthDate: record.birthDate,
                contacts: record.contacts,
                identifiers: record.identifiers,
                alerts: record.alerts
            ),
            status: .archived,
            updatedAt: date.addingTimeInterval(60)
        )
        let sourceURL = try writeSource("paciente-arquivado.txt", data: Data("Sintético.\n".utf8), in: context.root)
        let importItem = item(sourceURL, suffix: 9)

        let result = DocumentImportBatch().run(
            items: [importItem],
            in: context.vault.url,
            expectedVaultID: context.vault.manifest.vaultID,
            patientID: patientID,
            encounterID: nil,
            importedAt: date
        )
        #expect(result.completed.isEmpty)
        #expect(result.pending == [importItem])
        #expect(result.failure?.rule == "document_import_batch.patient_unavailable")
        let reopened = try VaultReader().open(context.vault.url)
        #expect(reopened.patients.first?.rawAssets.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    private func makeContext(encounter: Bool = false) throws -> BatchTestContext {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-document-batch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let vault = try VaultCreator().create(
            in: root,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: date
        )
        var patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente de Importação Sintético",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )
        if encounter {
            _ = try ClinicalDraftCreator().create(
                in: patient,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: encounterID,
                    noteID: "note_0198f5d3-0000-7000-8000-000000000031",
                    syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000031"
                ),
                startedAt: date
            )
            patient = try #require(VaultReader().open(vault.url).patients.first)
        }
        return BatchTestContext(root: root, vault: try VaultReader().open(vault.url), patient: patient)
    }

    private func reopen(_ context: BatchTestContext) throws -> BatchTestContext {
        let vault = try VaultReader().open(context.vault.url)
        return BatchTestContext(root: context.root, vault: vault, patient: try #require(vault.patients.first))
    }

    private func item(_ url: URL, suffix: Int) -> DocumentImportBatchItem {
        DocumentImportBatchItem(
            sourceURL: url,
            identity: RawAssetCreationIdentity(
                assetID: "asset_0198f5e0-0000-7000-8000-0000000000\(String(format: "%02d", suffix))"
            )
        )
    }

    private func writeSource(_ name: String, data: Data, in root: URL) throws -> URL {
        let url = root.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: [.withoutOverwriting])
        return url
    }

    private func replaceVaultID(at vaultURL: URL, from oldID: String, to newID: String) throws {
        for relativePath in ["vault.yaml", "operations/manifest.yaml"] {
            let url = vaultURL.appending(path: relativePath)
            let original = try String(contentsOf: url, encoding: .utf8)
            let changed = original.replacingOccurrences(of: oldID, with: newID)
            guard changed != original else { throw SyntheticBatchFailure() }
            try Data(changed.utf8).write(to: url, options: [.atomic])
        }
    }
}

private struct BatchTestContext {
    let root: URL
    let vault: VaultSummary
    let patient: PatientSummary
}

private struct SyntheticBatchFailure: Error {}
