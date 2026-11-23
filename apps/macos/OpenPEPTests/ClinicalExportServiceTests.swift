// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct ClinicalExportServiceTests {
    @Test("exports a draft explicitly and rejects a consultation from another patient")
    func exportsDraftAndRejectsCrossPatientSelection() throws {
        try withTemporaryDirectory { parent in
            let date = Date(timeIntervalSince1970: 1_788_195_600)
            let vault = try makeVault(in: parent, date: date, suffix: "101")
            let firstPatientID = "pt_0198f5c2-0000-7000-8000-000000000101"
            let secondPatientID = "pt_0198f5c2-0000-7000-8000-000000000102"
            let first = try makePatient(
                in: vault.url,
                patientID: firstPatientID,
                name: "Primeiro Paciente Sintético",
                date: date
            )
            let second = try makePatient(
                in: vault.url,
                patientID: secondPatientID,
                name: "Segundo Paciente Sintético",
                date: date
            )
            let firstEncounterID = "enc_0198f5d1-0000-7000-8000-000000000101"
            let secondEncounterID = "enc_0198f5d1-0000-7000-8000-000000000102"
            try makeDraft(
                in: first,
                encounterID: firstEncounterID,
                noteID: "note_0198f5d3-0000-7000-8000-000000000101",
                actorID: "usr_0198f4a0-0000-7000-8000-000000000101",
                date: date
            )
            try makeDraft(
                in: second,
                encounterID: secondEncounterID,
                noteID: "note_0198f5d3-0000-7000-8000-000000000102",
                actorID: "usr_0198f4a0-0000-7000-8000-000000000102",
                date: date
            )

            let destination = parent.appending(path: "draft-export")
            let result = try ClinicalExportService().export(
                scope: .encounter(patientID: firstPatientID, encounterID: firstEncounterID),
                from: vault.url,
                to: destination
            )
            #expect(result.encounterCount == 1)
            #expect(result.documentCount == 0)
            #expect(try html(at: destination).contains("Rascunho"))
            #expect(!FileManager.default.fileExists(atPath: destination.appending(
                path: "consultas/\(firstEncounterID)/finais"
            ).path))

            expectRule("clinical_export.encounter_not_found") {
                _ = try ClinicalExportService().export(
                    scope: .encounter(patientID: firstPatientID, encounterID: secondEncounterID),
                    from: vault.url,
                    to: parent.appending(path: "cross-patient-export")
                )
            }
        }
    }

    @Test("exports fresh verified content with escaped HTML and scoped document bindings")
    func exportsReadableScopedPackages() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let before = try VaultReader().open(fixture.vaultURL)
            let sourceDraft = try #require(before.patients.first?.encounters.first?.draft.persistedData)

            let encounterDestination = parent.appending(path: "encounter-export")
            let encounterResult = try ClinicalExportService().export(
                scope: .encounter(
                    patientID: fixture.patientID,
                    encounterID: fixture.encounterID
                ),
                from: fixture.vaultURL,
                to: encounterDestination
            )

            #expect(
                encounterResult.directoryURL.standardizedFileURL.path
                    == encounterDestination.standardizedFileURL.path
            )
            #expect(encounterResult.encounterCount == 1)
            #expect(encounterResult.documentCount == 1)
            #expect(FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "consultas/\(fixture.encounterID)/\(fixture.encounterID).md"
            ).path))
            #expect(FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "consultas/\(fixture.encounterID)/rascunhos/\(fixture.noteID).md"
            ).path))
            #expect(FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "consultas/\(fixture.encounterID)/finais/\(fixture.noteID).md"
            ).path))
            #expect(FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "consultas/\(fixture.encounterID)/adendos/\(fixture.addendumID).md"
            ).path))
            #expect(FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "documentos/\(fixture.boundAssetID).txt"
            ).path))
            #expect(!FileManager.default.fileExists(atPath: encounterDestination.appending(
                path: "documentos/\(fixture.unboundAssetID).txt"
            ).path))

            let encounterHTML = try html(at: encounterDestination)
            #expect(encounterHTML.contains("&lt;script&gt;alert(&quot;teste&quot;)&lt;/script&gt;"))
            #expect(encounterHTML.contains("Complemento &lt;seguro&gt; &amp; sintético"))
            #expect(!encounterHTML.contains("<script>"))
            #expect(encounterHTML.contains(fixture.boundAssetID))
            #expect(!encounterHTML.contains(fixture.unboundAssetID))

            let patientDestination = parent.appending(path: "patient-export")
            let patientResult = try ClinicalExportService().export(
                scope: .patient(patientID: fixture.patientID),
                from: fixture.vaultURL,
                to: patientDestination
            )
            #expect(patientResult.encounterCount == 1)
            #expect(patientResult.documentCount == 2)
            #expect(try html(at: patientDestination).contains(fixture.unboundAssetID))

            let after = try VaultReader().open(fixture.vaultURL)
            #expect(after.patients.count == 1)
            #expect(after.patients[0].encounters[0].draft.persistedData == sourceDraft)
        }
    }

    @Test("refuses altered clinical content and unsafe destinations")
    func refusesTamperAndUnsafeDestinations() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let opened = try VaultReader().open(fixture.vaultURL)
            let encounter = try #require(opened.patients.first?.encounters.first)
            guard case let .verified(finalization) = encounter.finalizationStatus else {
                Issue.record("A consulta sintética deveria estar finalizada")
                return
            }
            try Data("Nota final adulterada.\n".utf8).write(
                to: finalization.finalNote.url,
                options: [.atomic]
            )

            expectRule("clinical_export.altered_encounter") {
                _ = try ClinicalExportService().export(
                    scope: .encounter(
                        patientID: fixture.patientID,
                        encounterID: fixture.encounterID
                    ),
                    from: fixture.vaultURL,
                    to: parent.appending(path: "tampered-export")
                )
            }

            expectRule("clinical_export.altered_encounter") {
                _ = try ClinicalExportService().export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: parent.appending(path: "tampered-patient-export")
                )
            }

            expectRule("clinical_export.destination_inside_vault") {
                _ = try ClinicalExportService().export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: fixture.vaultURL.appending(path: "export-inside")
                )
            }

            let existing = parent.appending(path: "existing")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            expectRule("clinical_export.destination_exists") {
                _ = try ClinicalExportService().export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: existing
                )
            }

            let realParent = parent.appending(path: "real-parent")
            let linkedParent = parent.appending(path: "linked-parent")
            try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: realParent.appending(path: "nested"),
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
            expectRule("clinical_export.unsafe_directory") {
                _ = try ClinicalExportService().export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: linkedParent.appending(path: "nested/linked-export")
                )
            }
        }
    }

    @Test("refuses a document changed after import")
    func refusesDocumentTamper() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let opened = try VaultReader().open(fixture.vaultURL)
            let document = try #require(opened.patients.first?.rawAssets.first {
                $0.assetID == fixture.boundAssetID
            })
            try Data("Documento adulterado.\n".utf8).write(
                to: document.originalURL,
                options: [.atomic]
            )

            expectRule("clinical_export.patient_not_found") {
                _ = try ClinicalExportService().export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: parent.appending(path: "document-tamper-export")
                )
            }
        }
    }

    @Test("removes staging after an interrupted export")
    func removesInterruptedStaging() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let destination = parent.appending(path: "interrupted-export")
            let service = ClinicalExportService(faultInjector: { step in
                if step == .contentWritten { throw ExportSyntheticFailure() }
            })

            #expect(throws: ExportSyntheticFailure.self) {
                _ = try service.export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(remaining.allSatisfy { !$0.hasPrefix(".openpep-export-") })
            #expect(try VaultReader().open(fixture.vaultURL).patients.count == 1)
        }
    }

    @Test("detects a source mutation after staging and removes the partial package")
    func detectsMutationDuringExport() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let opened = try VaultReader().open(fixture.vaultURL)
            let document = try #require(opened.patients.first?.rawAssets.first {
                $0.assetID == fixture.boundAssetID
            })
            let source = document.originalURL
            let destination = parent.appending(path: "racing-export")
            let service = ClinicalExportService(faultInjector: { step in
                if step == .stagingCreated {
                    try Data("Mudança concorrente sintética.\n".utf8).write(
                        to: source,
                        options: [.atomic]
                    )
                }
            })

            expectRule("clinical_export.document_hash_mismatch") {
                _ = try service.export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(remaining.allSatisfy { !$0.hasPrefix(".openpep-export-") })
        }
    }

    @Test("detects sidecar mutation before publication")
    func detectsSidecarMutationDuringExport() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let opened = try VaultReader().open(fixture.vaultURL)
            let document = try #require(opened.patients.first?.rawAssets.first {
                $0.assetID == fixture.boundAssetID
            })
            let sidecar = document.originalURL.deletingLastPathComponent().appending(
                path: "\(document.assetID).meta.md"
            )
            let destination = parent.appending(path: "sidecar-racing-export")
            let service = ClinicalExportService(faultInjector: { step in
                guard step == .stagingCreated else { return }
                let original = try String(contentsOf: sidecar, encoding: .utf8)
                let changed = original.replacingOccurrences(
                    of: "original_name: \"vinculado.txt\"",
                    with: "original_name: \"renomeado-sintetico.txt\""
                )
                try Data(changed.utf8).write(to: sidecar, options: [.atomic])
            })

            expectRule("clinical_export.source_changed") {
                _ = try service.export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(remaining.allSatisfy { !$0.hasPrefix(".openpep-export-") })
        }
    }

    @Test("reports the exact residual staging path when cleanup fails")
    func reportsCleanupFailure() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeFixture(in: parent)
            let destination = parent.appending(path: "cleanup-failure-export")
            let service = ClinicalExportService(faultInjector: { step in
                if step == .contentWritten || step == .beforeStagingCleanup {
                    throw ExportSyntheticFailure()
                }
            })

            do {
                _ = try service.export(
                    scope: .patient(patientID: fixture.patientID),
                    from: fixture.vaultURL,
                    to: destination
                )
                Issue.record("A falha de limpeza deveria ser informada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_export.cleanup_failed")
                #expect(issue.path.contains(".openpep-export-"))
                #expect(FileManager.default.fileExists(atPath: issue.path))
                try FileManager.default.removeItem(atPath: issue.path)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func makeFixture(in parent: URL) throws -> ExportFixture {
        let patientID = "pt_0198f5c2-0000-7000-8000-000000000091"
        let encounterID = "enc_0198f5d1-0000-7000-8000-000000000091"
        let noteID = "note_0198f5d3-0000-7000-8000-000000000091"
        let addendumID = "add_0198f5d5-0000-7000-8000-000000000091"
        let boundAssetID = "asset_0198f5d7-0000-7000-8000-000000000091"
        let unboundAssetID = "asset_0198f5d7-0000-7000-8000-000000000092"
        let date = Date(timeIntervalSince1970: 1_788_195_600)
        let vault = try makeVault(in: parent, date: date, suffix: "091")
        let patient = try makePatient(
            in: vault.url,
            patientID: patientID,
            name: "Paciente <Sintético> & Seguro",
            date: date
        )
        let template = try ClinicalTemplateChoice.imported(
            data: Data("<script>alert(\"teste\")</script>\nTexto clínico sintético.\n".utf8),
            fileName: "template-sintetico.md"
        )
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000091"
            ),
            appointmentID: nil,
            input: EncounterStartInput(
                modality: .inPerson,
                template: template,
                telemedicine: nil
            ),
            startedAt: date
        )

        var opened = try VaultReader().open(vault.url)
        let boundSource = parent.appending(path: "vinculado.txt")
        try Data("Documento vinculado sintético.\n".utf8).write(to: boundSource)
        _ = try GeneralDocumentImporter().importDocument(
            from: boundSource,
            into: opened.patients[0],
            encounterID: encounterID,
            deviceID: opened.manifest.deviceID,
            identity: RawAssetCreationIdentity(assetID: boundAssetID),
            importedAt: date.addingTimeInterval(60)
        )

        opened = try VaultReader().open(vault.url)
        let unboundSource = parent.appending(path: "sem-vinculo.txt")
        try Data("Documento sem vínculo sintético.\n".utf8).write(to: unboundSource)
        _ = try GeneralDocumentImporter().importDocument(
            from: unboundSource,
            into: opened.patients[0],
            encounterID: nil,
            deviceID: opened.manifest.deviceID,
            identity: RawAssetCreationIdentity(assetID: unboundAssetID),
            importedAt: date.addingTimeInterval(120)
        )

        opened = try VaultReader().open(vault.url)
        _ = try ClinicalFinalizer().finalize(
            patient: opened.patients[0],
            encounter: opened.patients[0].encounters[0],
            identity: FinalizationIdentity(
                eventID: "evt_0198f5d4-0000-7000-8000-000000000091"
            ),
            finalizedAt: date.addingTimeInterval(180)
        )
        opened = try VaultReader().open(vault.url)
        _ = try ClinicalAddendumWriter().add(
            patient: opened.patients[0],
            encounter: opened.patients[0].encounters[0],
            identity: AddendumIdentity(
                addendumID: addendumID,
                eventID: "evt_0198f5d6-0000-7000-8000-000000000091"
            ),
            reason: "Complemento sintético",
            body: "Complemento <seguro> & sintético",
            createdAt: date.addingTimeInterval(240)
        )

        return ExportFixture(
            vaultURL: vault.url,
            patientID: patientID,
            encounterID: encounterID,
            noteID: noteID,
            addendumID: addendumID,
            boundAssetID: boundAssetID,
            unboundAssetID: unboundAssetID
        )
    }

    private func makeVault(in parent: URL, date: Date, suffix: String) throws -> VaultSummary {
        try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-0000-7000-8000-000000000\(suffix)",
                deviceID: "dev_0198f5c1-0000-7000-8000-000000000\(suffix)"
            ),
            createdAt: date
        )
    }

    private func makePatient(
        in vaultURL: URL,
        patientID: String,
        name: String,
        date: Date
    ) throws -> PatientSummary {
        try PatientCreator().createRegistered(
            in: vaultURL,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: name,
                preferredName: nil,
                birthDate: "2000-02-29",
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )
    }

    private func makeDraft(
        in patient: PatientSummary,
        encounterID: String,
        noteID: String,
        actorID: String,
        date: Date
    ) throws {
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: actorID
            ),
            startedAt: date
        )
    }

    private func html(at directory: URL) throws -> String {
        let data = try Data(contentsOf: directory.appending(path: "index.html"))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func expectRule(_ expected: String, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("A regra \(expected) deveria recusar a operação")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == expected)
        } catch {
            Issue.record("Erro inesperado para \(expected): \(error)")
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-export-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct ExportFixture {
    let vaultURL: URL
    let patientID: String
    let encounterID: String
    let noteID: String
    let addendumID: String
    let boundAssetID: String
    let unboundAssetID: String
}

private struct ExportSyntheticFailure: Error {}
