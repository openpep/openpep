// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("Prepared clinical document archival")
struct PreparedDocumentArchiverTests {
    private let date = ISO8601DateFormatter().date(from: "2026-09-05T15:00:00Z")!
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let encounterID = "enc_0198f5d1-0000-7000-8000-000000000001"
    private let secondEncounterID = "enc_0198f5d1-0000-7000-8000-000000000002"

    @Test("stores exact PDF and source bytes with their encounter binding and reopens them in history")
    func storesAndReopensPreparedDocument() throws {
        try withContext(encounterIDs: [encounterID]) { root, vault, patient in
            let document = try preparedDocument(title: "Orientações sintéticas")
            let stored = try ClinicalDocumentArchiver().archive(
                document,
                patient: patient,
                encounterID: encounterID,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date
            )

            let storedPDFData = try Data(contentsOf: stored.pdf.originalURL)
            #expect(storedPDFData == document.data)
            let sourceData = try Data(contentsOf: stored.source.originalURL)
            let source = try IndependentClinicalDocument.read(try #require(String(data: sourceData, encoding: .utf8)))
            #expect(source.body == document.sourceText)
            #expect(source.header.pdf_asset_id == stored.pdf.assetID)
            #expect(source.header.pdf_sha256 == stored.pdf.sha256)
            #expect(source.header.encounter_id == encounterID)

            let reopened = try VaultReader().open(vault.url)
            let reopenedPatient = try #require(reopened.patients.first)
            #expect(reopenedPatient.rawAssets.count == 2)
            #expect(reopenedPatient.rawAssets.allSatisfy { $0.encounterID == encounterID })
            let history = try PatientHistoryReader().load(
                patientID: patientID,
                vaultURL: vault.url,
                authorizationURL: root
            )
            let entry = try #require(history.entries.first(where: { $0.assetID == stored.pdf.assetID }))
            #expect(entry.text == document.sourceText)
            #expect(entry.status == "Documento da consulta")
            let search = ClinicalSearchIndex(patients: [reopenedPatient])
            let documents = search.search("", filter: .documents)
            #expect(documents.count == 1)
            #expect(documents.first?.title == "Orientações sintéticas")
            #expect(documents.first?.target == .document(stored.pdf.assetID))
            #expect(search.search("", filter: .documents, includesSupplementaryFiles: true).count == 2)
            // A stale or altered source must never cause a result to disappear.
            try Data("Fonte alterada de ensaio".utf8).write(to: stored.source.originalURL)
            let staleSearch = ClinicalSearchIndex(patients: [reopenedPatient])
            #expect(staleSearch.search("", filter: .documents).count == 2)

        }
    }

    @Test("repeating one preparation reuses both assets without duplicates")
    func idempotentRetry() throws {
        try withContext { _, vault, patient in
            let document = try preparedDocument(title: "Relatório sintético")
            let first = try ClinicalDocumentArchiver().archive(
                document,
                patient: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date
            )
            let second = try ClinicalDocumentArchiver().archive(
                document,
                patient: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date.addingTimeInterval(60)
            )

            #expect(second.pdf == first.pdf)
            #expect(second.source == first.source)
            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients.first?.rawAssets.map(\.assetID).sorted() == [
                document.pdfIdentity.assetID,
                document.sourceIdentity.assetID,
            ].sorted())
        }
    }

    @Test("a new preparation with edited content keeps the earlier version")
    func changedPreparationKeepsEarlierVersion() throws {
        try withContext { _, vault, patient in
            let firstDocument = try preparedDocument(title: "Relatório sintético")
            let first = try ClinicalDocumentArchiver().archive(
                firstDocument,
                patient: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date
            )
            let editedDocument = try preparedDocument(
                title: "Relatório sintético",
                text: "Texto sintético revisado em uma nova preparação."
            )
            let edited = try ClinicalDocumentArchiver().archive(
                editedDocument,
                patient: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date.addingTimeInterval(60)
            )

            #expect(first.pdf.assetID != edited.pdf.assetID)
            #expect(first.source.assetID != edited.source.assetID)
            let reopened = try VaultReader().open(vault.url)
            let reopenedPatient = try #require(reopened.patients.first)
            #expect(reopenedPatient.rawAssets.count == 4)
            let firstPDFData = try Data(contentsOf: first.pdf.originalURL)
            let firstSourceText = try String(contentsOf: first.source.originalURL, encoding: .utf8)
            let firstSource = try IndependentClinicalDocument.read(firstSourceText)
            #expect(firstPDFData == firstDocument.data)
            #expect(firstSource.body == firstDocument.sourceText)
        }
    }

    @Test("a partial failure retains the PDF and retry completes the same preparation")
    func partialFailureThenRetry() throws {
        try withContext { _, vault, patient in
            let document = try preparedDocument(title: "Declaração sintética")
            let failing = ClinicalDocumentArchiver(faultInjector: { step in
                if step == .pdfStored { throw SyntheticPreparedArchiveFailure() }
            })
            expectRule("document.source_publication") {
                _ = try failing.archive(
                    document,
                    patient: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    expectedVaultID: vault.manifest.vaultID,
                    now: date
                )
            }

            var reopened = try VaultReader().open(vault.url)
            var reopenedPatient = try #require(reopened.patients.first)
            #expect(reopenedPatient.rawAssets.map(\.assetID) == [document.pdfIdentity.assetID])
            let retainedPDF = try #require(reopenedPatient.rawAssets.first)
            let retainedPDFData = try Data(contentsOf: retainedPDF.originalURL)
            #expect(retainedPDFData == document.data)

            let completed = try ClinicalDocumentArchiver().archive(
                document,
                patient: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date.addingTimeInterval(60)
            )
            #expect(completed.pdf.assetID == retainedPDF.assetID)
            reopened = try VaultReader().open(vault.url)
            reopenedPatient = try #require(reopened.patients.first)
            #expect(reopenedPatient.rawAssets.count == 2)
            #expect(Set(reopenedPatient.rawAssets.map(\.assetID)) == Set([
                document.pdfIdentity.assetID,
                document.sourceIdentity.assetID,
            ]))
        }
    }

    @Test("reserved identities refuse different content and a different encounter binding")
    func contentAndBindingConflicts() throws {
        try withContext(encounterIDs: [encounterID, secondEncounterID]) { root, vault, patient in
            let document = try preparedDocument(title: "Conflito sintético")
            let otherPDF = try ClinicalDocumentPDF.make(
                title: document.title,
                patientName: "Paciente Sintético",
                professional: "",
                body: "Conteúdo concorrente sintético.",
                date: date
            )
            let sourceURL = root.appending(path: "Conflito sintético.pdf")
            try otherPDF.write(to: sourceURL, options: .withoutOverwriting)
            _ = try GeneralDocumentImporter().importDocument(
                from: sourceURL,
                into: patient,
                encounterID: nil,
                deviceID: vault.manifest.deviceID,
                identity: document.pdfIdentity,
                importedAt: date
            )
            expectRule("document_archive.identity_conflict") {
                _ = try ClinicalDocumentArchiver().archive(
                    document,
                    patient: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    expectedVaultID: vault.manifest.vaultID,
                    now: date
                )
            }
            let afterContentConflict = try VaultReader().open(vault.url)
            let conflictingAsset = try #require(afterContentConflict.patients.first?.rawAssets.first)
            let conflictingData = try Data(contentsOf: conflictingAsset.originalURL)
            #expect(conflictingData == otherPDF)
            #expect(afterContentConflict.patients.first?.rawAssets.count == 1)

            let linkedDocument = try preparedDocument(title: "Vínculo sintético")
            _ = try ClinicalDocumentArchiver().archive(
                linkedDocument,
                patient: patient,
                encounterID: encounterID,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date.addingTimeInterval(60)
            )
            expectRule("document_archive.identity_conflict") {
                _ = try ClinicalDocumentArchiver().archive(
                    linkedDocument,
                    patient: patient,
                    encounterID: secondEncounterID,
                    deviceID: vault.manifest.deviceID,
                    expectedVaultID: vault.manifest.vaultID,
                    now: date.addingTimeInterval(120)
                )
            }
            let afterBindingConflict = try VaultReader().open(vault.url)
            let linkedAssets = try #require(afterBindingConflict.patients.first).rawAssets.filter {
                [linkedDocument.pdfIdentity.assetID, linkedDocument.sourceIdentity.assetID].contains($0.assetID)
            }
            #expect(linkedAssets.count == 2)
            #expect(linkedAssets.allSatisfy { $0.encounterID == encounterID })
        }
    }

    @Test("an encounter change after the PDF blocks completion and a fresh retry recovers")
    func encounterChangeAfterPDF() throws {
        try withContext(encounterIDs: [encounterID]) { _, vault, patient in
            let document = try preparedDocument(title: "Atestado sintético")
            let originalEncounter = try #require(patient.encounters.first)
            let conflicting = ClinicalDocumentArchiver(faultInjector: { step in
                guard step == .pdfStored else { return }
                _ = try ClinicalDraftSaver().save(
                    encounter: originalEncounter,
                    patientID: patient.patientID,
                    body: "Edição concorrente sintética.",
                    updatedAt: self.date.addingTimeInterval(30)
                )
            })
            expectRule("document.source_publication") {
                _ = try conflicting.archive(
                    document,
                    patient: patient,
                    encounterID: encounterID,
                    deviceID: vault.manifest.deviceID,
                    expectedVaultID: vault.manifest.vaultID,
                    now: date
                )
            }
            var reopened = try VaultReader().open(vault.url)
            var freshPatient = try #require(reopened.patients.first)
            #expect(freshPatient.rawAssets.map(\.assetID) == [document.pdfIdentity.assetID])

            _ = try ClinicalDocumentArchiver().archive(
                document,
                patient: freshPatient,
                encounterID: encounterID,
                deviceID: vault.manifest.deviceID,
                expectedVaultID: vault.manifest.vaultID,
                now: date.addingTimeInterval(60)
            )
            reopened = try VaultReader().open(vault.url)
            freshPatient = try #require(reopened.patients.first)
            #expect(freshPatient.rawAssets.count == 2)
            #expect(freshPatient.rawAssets.allSatisfy { $0.encounterID == encounterID })
        }
    }

    @Test("a different vault identity after the PDF blocks completion")
    func vaultIdentityChangeAfterPDF() throws {
        try withContext { _, vault, patient in
            let document = try preparedDocument(title: "Documento de identidade sintético")
            let replacementVaultID = "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a220"
            let conflicting = ClinicalDocumentArchiver(faultInjector: { step in
                guard step == .pdfStored else { return }
                try replaceVaultID(
                    at: vault.url,
                    from: vault.manifest.vaultID,
                    to: replacementVaultID
                )
            })
            expectRule("document.source_publication") {
                _ = try conflicting.archive(
                    document,
                    patient: patient,
                    encounterID: nil,
                    deviceID: vault.manifest.deviceID,
                    expectedVaultID: vault.manifest.vaultID,
                    now: date
                )
            }

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.manifest.vaultID == replacementVaultID)
            #expect(reopened.manifest.deviceID == vault.manifest.deviceID)
            let reopenedPatient = try #require(reopened.patients.first)
            #expect(reopenedPatient.patientID == patient.patientID)
            #expect(reopenedPatient.rawAssets.map(\.assetID) == [document.pdfIdentity.assetID])
        }
    }

    private func preparedDocument(
        title: String,
        text: String = "Texto sintético recuperável com acentuação."
    ) throws -> PreparedClinicalDocument {
        let data = try ClinicalDocumentPDF.make(
            title: title,
            patientName: "Paciente Sintético",
            professional: "",
            body: text,
            date: date
        )
        return try PreparedClinicalDocument(title: title, data: data, sourceText: text, createdAt: date)
    }

    private func withContext(
        encounterIDs: [String] = [],
        _ body: (URL, VaultSummary, PatientSummary) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-prepared-archive-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
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
                fullName: "Paciente Sintético",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )
        for (offset, encounterID) in encounterIDs.enumerated() {
            _ = try ClinicalDraftCreator().create(
                in: patient,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: encounterID,
                    noteID: "note_0198f5d3-0000-7000-8000-00000000000\(offset + 1)",
                    syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"
                ),
                startedAt: date.addingTimeInterval(Double(offset))
            )
            patient = try #require(VaultReader().open(vault.url).patients.first)
        }
        try body(root, try VaultReader().open(vault.url), patient)
    }

    private func replaceVaultID(at vaultURL: URL, from oldID: String, to newID: String) throws {
        for relativePath in ["vault.yaml", "operations/manifest.yaml"] {
            let url = vaultURL.appending(path: relativePath)
            let original = try String(contentsOf: url, encoding: .utf8)
            let changed = original.replacingOccurrences(of: oldID, with: newID)
            guard changed != original else {
                throw SyntheticPreparedArchiveFailure()
            }
            try Data(changed.utf8).write(to: url, options: [.atomic])
        }
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
}

private struct SyntheticPreparedArchiveFailure: Error {}
