// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import OpenPEP

@Suite("BACKUP-001 verified backup and restore")
struct VaultBackupServiceTests {
    @Test("creates, verifies and restores the complete vault without changing its source")
    func roundTripsCompleteVault() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeCompleteFixture(in: parent)
            let wikiPatient = try #require(VaultReader().open(fixture.vaultURL).patients.first)
            let wikiHistory = try PatientHistoryReader().load(patientID: wikiPatient.patientID,
                vaultURL: fixture.vaultURL, authorizationURL: fixture.vaultURL)
            let wikiContext = try PatientWikiContext.make(patient: wikiPatient, entries: wikiHistory.entries, corrections: "")
            let sourceIndex = try #require(wikiContext.entries.firstIndex { $0.source.hasPrefix("content/notes/final/") })
            let source = wikiContext.entries[sourceIndex]
            let fact = try PatientWikiFact.bind([.init(kind: .problem, label: "Cefaleia sintética", text: "Registro sintético.",
                source: "F\(sourceIndex + 1)", quote: source.text)], to: wikiContext)[0]
            try PatientWikiStore().saveReview(.init(fact: fact, decision: .accepted, reviewer: "Profissional Sintético",
                reviewedAt: "2026-09-07T12:00:00Z"), for: wikiPatient, expectedData: nil, validateSources: {})
            let originalReviewBytes = try PatientWikiStore().loadReviews(for: wikiPatient).1
            let originalBefore = try fileSnapshot(at: fixture.vaultURL)
            let packageURL = parent.appending(path: "backup-package")

            let created = try VaultBackupService().create(from: fixture.vaultURL, to: packageURL)
            #expect(created.packageURL.standardizedFileURL.path == packageURL.standardizedFileURL.path)
            #expect(created.manifest.format == "openpep-backup")
            #expect(created.manifest.version == 1)
            #expect(created.manifest.vaultID == fixture.vaultID)
            #expect(created.manifest.fileCount == created.manifest.files.count)
            #expect(created.manifest.byteCount == created.manifest.files.map(\.sizeBytes).reduce(0, +))
            #expect(created.manifest.files.map(\.path) == created.manifest.files.map(\.path).sorted())
            #expect(created.manifest.directories == created.manifest.directories.sorted())
            #expect(Set(created.manifest.directories).count == created.manifest.directories.count)
            #expect(created.manifest.directories.contains("unmanaged/empty"))
            #expect(created.manifest.files.contains { $0.path == "unmanaged/notes-for-user.txt" })
            #expect(created.manifest.files.contains { $0.path == "unmanaged/\(nfdUnmanagedName)" })
            #expect(created.manifest.files.contains {
                $0.path == "patients/pt_0198f5c2-0000-7000-8000-000000000201/content/consultation-work/enc_0198f5d1-0000-7000-8000-000000000201.json"
            })
            #expect(created.manifest.files.allSatisfy { !$0.path.hasSuffix(".DS_Store") })
            #expect(created.manifestSHA256.count == 64)

            let verified = try VaultBackupService().verify(at: packageURL)
            #expect(verified.packageURL.standardizedFileURL.path == packageURL.standardizedFileURL.path)
            #expect(verified.manifestSHA256 == created.manifestSHA256)
            #expect(verified.manifest == created.manifest)

            let mismatchedRestore = parent.appending(path: "mismatched-restore")
            expectRule("backup.fingerprint_mismatch") {
                _ = try VaultBackupService().restore(
                    from: packageURL,
                    to: mismatchedRestore,
                    expectedManifestSHA256: String(repeating: "0", count: 64)
                )
            }
            #expect(!FileManager.default.fileExists(atPath: mismatchedRestore.path))

            let restoredURL = parent.appending(path: "restored-vault")
            let restoration = try VaultBackupService().restore(from: packageURL, to: restoredURL)
            #expect(restoration.vaultURL.standardizedFileURL.path == restoredURL.standardizedFileURL.path)
            #expect(restoration.backup.packageURL.standardizedFileURL.path == packageURL.standardizedFileURL.path)
            #expect(restoration.backup.manifestSHA256 == verified.manifestSHA256)
            #expect(restoration.backup.manifest == verified.manifest)

            let restored = try VaultReader().open(restoration.vaultURL)
            #expect(restored.manifest.vaultID == fixture.vaultID)
            #expect(restored.patients.count == 1)
            #expect(restored.appointments.count == 1)
            #expect(restored.unavailablePatients.isEmpty)
            #expect(restored.unavailableAppointments.isEmpty)
            let restoredPatient = try #require(restored.patients.first)
            let (restoredReviews, restoredReviewBytes) = try PatientWikiStore().loadReviews(for: restoredPatient)
            #expect(restoredReviewBytes == originalReviewBytes)
            #expect(restoredReviews.records.map(\.fact.id) == [fact.id])
            let restoredHistory = try PatientHistoryReader().load(patientID: restoredPatient.patientID,
                vaultURL: restored.url, authorizationURL: restored.url)
            let restoredWikiContext = try PatientWikiContext.make(patient: restoredPatient, entries: restoredHistory.entries, corrections: "")
            #expect(restoredReviews.accepted(in: restoredWikiContext).map(\.id) == [fact.id])
            #expect(restoredPatient.rawAssets.count == 1)
            let restoredEncounter = try #require(restoredPatient.encounters.first)
            let restoredWork = try ProgressiveConsultationWorkStore().load(binding: .init(
                vaultURL: restored.url,
                vaultID: restored.manifest.vaultID,
                patientID: restoredPatient.patientID,
                encounterID: restoredEncounter.metadata.encounterID,
                patientName: restoredPatient.displayName
            ))
            #expect(restoredWork?.status == .ready)
            guard case let .verified(finalization) = restoredEncounter.finalizationStatus else {
                Issue.record("A consulta restaurada deveria continuar verificada")
                return
            }
            #expect(finalization.addenda.count == 1)
            #expect(finalization.addenda[0].body.contains("Plano complementar sintético"))

            let sourceSearch = ClinicalSearchIndex(
                patients: try VaultReader().open(fixture.vaultURL).patients
            )
            let restoredSearch = ClinicalSearchIndex(patients: restored.patients)
            for query in ["Helena", "cefaleia persistente", "plano complementar", "hemograma"] {
                #expect(restoredSearch.search(query) == sourceSearch.search(query))
            }

            let originalAfter = try fileSnapshot(at: fixture.vaultURL)
            let restoredFiles = try fileSnapshot(at: restoration.vaultURL)
            #expect(originalAfter.keys.sorted() == originalBefore.keys.sorted())
            #expect(restoredFiles.keys.sorted() == originalBefore.keys.sorted())
            for path in originalBefore.keys.sorted() {
                #expect(originalAfter[path] == originalBefore[path])
                #expect(restoredFiles[path] == originalBefore[path])
            }
            #expect(FileManager.default.fileExists(
                atPath: restoration.vaultURL.appending(path: "unmanaged/empty").path
            ))
            #expect(
                try Data(contentsOf: restoration.vaultURL.appending(
                    path: "unmanaged/\(nfdUnmanagedName)"
                )) == nfdUnmanagedData
            )
            #expect(
                try Data(contentsOf: fixture.vaultURL.appending(path: ".DS_Store"))
                    == syntheticDSStoreData
            )
            #expect(!FileManager.default.fileExists(
                atPath: restoration.vaultURL.appending(path: ".DS_Store").path
            ))
        }
    }

    @Test("rejects changed, deleted and extra payload files")
    func rejectsPayloadInventoryChanges() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let originalPackage = parent.appending(path: "original-package")
            let summary = try VaultBackupService().create(from: vault.url, to: originalPackage)
            let firstPath = try #require(summary.manifest.files.first?.path)

            let changed = try packageCopy(originalPackage, named: "changed-package", in: parent)
            try Data("conteúdo alterado\n".utf8).write(
                to: changed.appending(path: "vault/\(firstPath)"),
                options: [.atomic]
            )
            expectRule("backup.inventory_mismatch") {
                _ = try VaultBackupService().verify(at: changed)
            }

            let deleted = try packageCopy(originalPackage, named: "deleted-package", in: parent)
            try FileManager.default.removeItem(at: deleted.appending(path: "vault/\(firstPath)"))
            expectRule("backup.inventory_mismatch") {
                _ = try VaultBackupService().verify(at: deleted)
            }

            let extra = try packageCopy(originalPackage, named: "extra-package", in: parent)
            try Data("arquivo extra sintético\n".utf8).write(
                to: extra.appending(path: "vault/extra.txt")
            )
            expectRule("backup.inventory_mismatch") {
                _ = try VaultBackupService().verify(at: extra)
            }
        }
    }

    @Test("accepts the v1 fixture shape and rejects incompatible manifest fixtures")
    func validatesManifestContractFixtures() throws {
        let validData = try Data(contentsOf: fixtureRoot.appending(path: "valid/empty/manifest.json"))
        let valid = try JSONDecoder().decode(VaultBackupManifest.self, from: validData)
        #expect(valid.format == "openpep-backup")
        #expect(valid.version == 1)
        #expect(valid.fileCount == 0)
        #expect(valid.byteCount == 0)
        #expect(valid.directories.isEmpty)
        #expect(valid.files.isEmpty)

        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let basePackage = parent.appending(path: "base-package")
            let baseSummary = try VaultBackupService().create(from: vault.url, to: basePackage)

            let invalidFixtures = [
                ("unsupported-version", "backup.manifest_version"),
                ("unknown-field", "backup.manifest_fields"),
                ("inconsistent-counts", "backup.manifest_counts"),
                ("path-traversal", "backup.manifest_path"),
                ("duplicate-path", "backup.manifest_order"),
            ]
            for (fixtureName, expectedRule) in invalidFixtures {
                let candidate = try packageCopy(
                    basePackage,
                    named: "invalid-\(fixtureName)",
                    in: parent
                )
                let fixtureManifest = fixtureRoot.appending(
                    path: "invalid/\(fixtureName)/manifest.json"
                )
                try FileManager.default.removeItem(at: candidate.appending(path: "manifest.json"))
                try FileManager.default.copyItem(
                    at: fixtureManifest,
                    to: candidate.appending(path: "manifest.json")
                )
                expectRule(expectedRule) {
                    _ = try VaultBackupService().verify(at: candidate)
                }
            }

            let collisionPackage = try packageCopy(
                basePackage,
                named: "invalid-file-directory-collision",
                in: parent
            )
            let collisionManifest = VaultBackupManifest(
                format: baseSummary.manifest.format,
                version: baseSummary.manifest.version,
                createdAt: baseSummary.manifest.createdAt,
                vaultID: baseSummary.manifest.vaultID,
                fileCount: baseSummary.manifest.fileCount,
                byteCount: baseSummary.manifest.byteCount,
                directories: (baseSummary.manifest.directories + ["vault.yaml"]).sorted(),
                files: baseSummary.manifest.files
            )
            try writeManifest(collisionManifest, to: collisionPackage)
            expectRule("backup.manifest_collision") {
                _ = try VaultBackupService().verify(at: collisionPackage)
            }
        }
    }

    @Test("does not verify a clinically invalid tree even when its transport hashes match")
    func rejectsClinicallyInvalidBackup() throws {
        try withTemporaryDirectory { parent in
            let fixture = try makeCompleteFixture(in: parent)
            let packageURL = parent.appending(path: "clinical-invalid-package")
            let created = try VaultBackupService().create(from: fixture.vaultURL, to: packageURL)
            let finalPath = try #require(created.manifest.files.first {
                $0.path.contains("/content/notes/final/") && $0.path.hasSuffix(".md")
            }?.path)
            let finalURL = packageURL.appending(path: "vault/\(finalPath)")
            let changedData = Data("Nota final sintética inválida.\n".utf8)
            try changedData.write(to: finalURL, options: [.atomic])

            let changedFiles = created.manifest.files.map { file in
                guard file.path == finalPath else { return file }
                return VaultBackupFile(
                    path: file.path,
                    sizeBytes: changedData.count,
                    sha256: sha256(changedData)
                )
            }
            let changedManifest = VaultBackupManifest(
                format: created.manifest.format,
                version: created.manifest.version,
                createdAt: created.manifest.createdAt,
                vaultID: created.manifest.vaultID,
                fileCount: changedFiles.count,
                byteCount: changedFiles.map(\.sizeBytes).reduce(0, +),
                directories: created.manifest.directories,
                files: changedFiles
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(changedManifest).write(
                to: packageURL.appending(path: "manifest.json"),
                options: [.atomic]
            )

            expectValidationIssue {
                _ = try VaultBackupService().verify(at: packageURL)
            }
        }
    }

    @Test("rejects collisions, nested destinations and symbolic links")
    func rejectsUnsafeSourcesAndDestinations() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)

            expectRule("backup.destination_inside_source") {
                _ = try VaultBackupService().create(
                    from: vault.url,
                    to: vault.url.appending(path: "nested-backup")
                )
            }

            let collision = parent.appending(path: "collision")
            try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
            expectRule("backup.destination_exists") {
                _ = try VaultBackupService().create(from: vault.url, to: collision)
            }

            let realParent = parent.appending(path: "real-destination")
            let linkedParent = parent.appending(path: "linked-destination")
            try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
            expectRule("backup.unsafe_directory") {
                _ = try VaultBackupService().create(
                    from: vault.url,
                    to: linkedParent.appending(path: "backup")
                )
            }

            let outsideFile = parent.appending(path: "outside.txt")
            try Data("fora do vault\n".utf8).write(to: outsideFile)
            try FileManager.default.createSymbolicLink(
                at: vault.url.appending(path: ".DS_Store"),
                withDestinationURL: outsideFile
            )
            expectRule("backup.symbolic_link") {
                _ = try VaultBackupService().create(
                    from: vault.url,
                    to: parent.appending(path: "symlink-source-package")
                )
            }
            try FileManager.default.removeItem(at: vault.url.appending(path: ".DS_Store"))

            let packageURL = parent.appending(path: "valid-package")
            _ = try VaultBackupService().create(from: vault.url, to: packageURL)
            expectRule("backup.destination_inside_source") {
                _ = try VaultBackupService().restore(
                    from: packageURL,
                    to: packageURL.appending(path: "vault/restored")
                )
            }
            expectRule("backup.destination_exists") {
                _ = try VaultBackupService().restore(from: packageURL, to: collision)
            }
        }
    }

    @Test("removes creation and restoration staging after injected failures")
    func removesInterruptedStaging() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let creationDestination = parent.appending(path: "interrupted-package")
            let beforeCreation = try directoryNames(at: parent)
            let creationService = VaultBackupService(faultInjector: { operation, step in
                if operation == .creation, step == .filesCopied {
                    throw BackupSyntheticFailure()
                }
            })
            #expect(throws: BackupSyntheticFailure.self) {
                _ = try creationService.create(from: vault.url, to: creationDestination)
            }
            #expect(!FileManager.default.fileExists(atPath: creationDestination.path))
            #expect(try directoryNames(at: parent) == beforeCreation)

            let packageURL = parent.appending(path: "valid-package")
            _ = try VaultBackupService().create(from: vault.url, to: packageURL)
            let restorationDestination = parent.appending(path: "interrupted-restoration")
            let beforeRestoration = try directoryNames(at: parent)
            let restorationService = VaultBackupService(faultInjector: { operation, step in
                if operation == .restoration, step == .beforePublication {
                    throw BackupSyntheticFailure()
                }
            })
            #expect(throws: BackupSyntheticFailure.self) {
                _ = try restorationService.restore(from: packageURL, to: restorationDestination)
            }
            #expect(!FileManager.default.fileExists(atPath: restorationDestination.path))
            #expect(try directoryNames(at: parent) == beforeRestoration)

            let cleanupDestination = parent.appending(path: "cleanup-failure-package")
            let cleanupService = VaultBackupService(faultInjector: { operation, step in
                if operation == .creation,
                   step == .filesCopied || step == .beforeCleanup {
                    throw BackupSyntheticFailure()
                }
            })
            do {
                _ = try cleanupService.create(from: vault.url, to: cleanupDestination)
                Issue.record("A falha de limpeza deveria ser informada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "backup.cleanup_failed")
                #expect(issue.path.contains(".openpep-backup-"))
                #expect(FileManager.default.fileExists(atPath: issue.path))
                try FileManager.default.removeItem(atPath: issue.path)
            }
            #expect(!FileManager.default.fileExists(atPath: cleanupDestination.path))
        }
    }

    @Test("detects a source change before publication and removes staging")
    func detectsSourceChangeDuringCreation() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let destination = parent.appending(path: "racing-package")
            let changedSource = vault.url.appending(path: "external-change.txt")
            let service = VaultBackupService(faultInjector: { operation, step in
                guard operation == .creation, step == .filesCopied else { return }
                try Data("Mudança concorrente sintética.\n".utf8).write(
                    to: changedSource,
                    options: [.atomic]
                )
            })

            expectRule("backup.source_changed") {
                _ = try service.create(from: vault.url, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try directoryNames(at: parent).allSatisfy { !$0.hasPrefix(".openpep-backup-") })
        }
    }

    @Test("revalidates staging after beforePublication mutation and removes it")
    func rejectsStagingMutationBeforePublication() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let destination = parent.appending(path: "mutated-staging-package")
            let service = VaultBackupService(faultInjector: { operation, step in
                guard operation == .creation, step == .beforePublication else { return }
                let stagingName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: parent.path).first {
                        $0.hasPrefix(".openpep-backup-")
                    }
                )
                try Data("manifesto do vault alterado no staging\n".utf8).write(
                    to: parent.appending(path: "\(stagingName)/vault/vault.yaml"),
                    options: [.atomic]
                )
            })

            expectRule("backup.inventory_mismatch") {
                _ = try service.create(from: vault.url, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try directoryNames(at: parent).allSatisfy { !$0.hasPrefix(".openpep-backup-") })
        }
    }

    @Test("revalidates the package after restoration copy and removes staging")
    func rejectsPackageMutationDuringRestoration() throws {
        try withTemporaryDirectory { parent in
            let vault = try makeMinimalVault(in: parent)
            let packageURL = parent.appending(path: "restore-source-package")
            _ = try VaultBackupService().create(from: vault.url, to: packageURL)
            let destination = parent.appending(path: "restore-after-package-change")
            let service = VaultBackupService(faultInjector: { operation, step in
                guard operation == .restoration, step == .filesCopied else { return }
                try Data("pacote alterado durante restauração\n".utf8).write(
                    to: packageURL.appending(path: "vault/vault.yaml"),
                    options: [.atomic]
                )
            })

            expectRule("backup.inventory_mismatch") {
                _ = try service.restore(from: packageURL, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try directoryNames(at: parent).allSatisfy { !$0.hasPrefix(".openpep-restore-") })
        }
    }

    private func makeCompleteFixture(in parent: URL) throws -> BackupFixture {
        let date = Date(timeIntervalSince1970: 1_788_195_600)
        let vault = try makeVault(in: parent, date: date, suffix: "201")
        let patientID = "pt_0198f5c2-0000-7000-8000-000000000201"
        let encounterID = "enc_0198f5d1-0000-7000-8000-000000000201"
        let noteID = "note_0198f5d3-0000-7000-8000-000000000201"
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Helena Sintética do Backup",
                preferredName: "Helena",
                birthDate: "1980-01-01",
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )

        _ = try AppointmentWriter().create(
            in: vault.url,
            patient: patient,
            identity: AppointmentCreationIdentity(
                appointmentID: "appt_0198f5c4-0000-7000-8000-000000000201"
            ),
            input: AppointmentInput(
                patientID: patientID,
                startsAt: date.addingTimeInterval(3_600),
                endsAt: date.addingTimeInterval(5_400),
                timeZone: "America/Sao_Paulo",
                modality: .inPerson,
                status: .scheduled,
                location: "Consultório sintético",
                remoteAccessURL: nil,
                administrativeNote: "Agendamento exclusivo de teste"
            ),
            createdAt: date
        )

        let template = try ClinicalTemplateChoice.imported(
            data: Data("Cefaleia persistente exclusivamente sintética.\n".utf8),
            fileName: "backup-sintetico.md"
        )
        _ = try ClinicalDraftCreator().create(
            in: patient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000201"
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
        _ = try #require(opened.patients[0].encounters.first)
        let binding = EncounterTranscriptionBinding(
            vaultURL: opened.url,
            vaultID: opened.manifest.vaultID,
            patientID: patientID,
            encounterID: encounterID,
            patientName: opened.patients[0].displayName
        )
        var work = ProgressiveConsultationWork(
            binding: binding,
            source: .imported,
            summaryIntervalSeconds: 180,
            transcriptionEngine: "apple/SpeechTranscriber",
            transcriptionModel: "pt-BR",
            summaryEngine: "apple/FoundationModels.SystemLanguageModel",
            summaryModel: nil,
            now: date
        )
        work.status = .ready
        work.capture.status = .ready
        work.capture.endedAt = date
        work.updatedAt = date
        _ = try ProgressiveConsultationWorkStore().save(work, binding: binding)
        opened = try VaultReader().open(vault.url)
        let documentSource = parent.appending(path: "hemograma-sintetico.txt")
        try Data("Hemograma sintético sem valor clínico.\n".utf8).write(to: documentSource)
        _ = try GeneralDocumentImporter().importDocument(
            from: documentSource,
            into: opened.patients[0],
            encounterID: encounterID,
            deviceID: opened.manifest.deviceID,
            identity: RawAssetCreationIdentity(
                assetID: "asset_0198f5d7-0000-7000-8000-000000000201"
            ),
            importedAt: date.addingTimeInterval(60)
        )

        opened = try VaultReader().open(vault.url)
        _ = try ClinicalFinalizer().finalize(
            patient: opened.patients[0],
            encounter: opened.patients[0].encounters[0],
            identity: FinalizationIdentity(
                eventID: "evt_0198f5d4-0000-7000-8000-000000000201"
            ),
            finalizedAt: date.addingTimeInterval(120)
        )
        opened = try VaultReader().open(vault.url)
        _ = try ClinicalAddendumWriter().add(
            patient: opened.patients[0],
            encounter: opened.patients[0].encounters[0],
            identity: AddendumIdentity(
                addendumID: "add_0198f5d5-0000-7000-8000-000000000201",
                eventID: "evt_0198f5d6-0000-7000-8000-000000000201"
            ),
            reason: "Complemento sintético",
            body: "Plano complementar sintético.",
            createdAt: date.addingTimeInterval(180)
        )

        let unmanaged = vault.url.appending(path: "unmanaged")
        try FileManager.default.createDirectory(
            at: unmanaged.appending(path: "empty"),
            withIntermediateDirectories: true
        )
        try Data("Conteúdo não gerenciado sintético.\n".utf8).write(
            to: unmanaged.appending(path: "notes-for-user.txt")
        )
        try nfdUnmanagedData.write(to: unmanaged.appending(path: nfdUnmanagedName))
        try syntheticDSStoreData.write(to: vault.url.appending(path: ".DS_Store"))

        return BackupFixture(
            vaultURL: vault.url,
            vaultID: vault.manifest.vaultID
        )
    }

    private func makeMinimalVault(in parent: URL) throws -> VaultSummary {
        try makeVault(
            in: parent,
            date: Date(timeIntervalSince1970: 1_788_195_600),
            suffix: "202"
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

    private func packageCopy(_ source: URL, named name: String, in parent: URL) throws -> URL {
        let destination = parent.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func fileSnapshot(at root: URL) throws -> [String: Data] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else { return [:] }
        let rootComponents = root.standardizedFileURL.pathComponents
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            guard url.lastPathComponent != ".DS_Store" else { continue }
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    private func writeManifest(_ manifest: VaultBackupManifest, to packageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appending(path: "manifest.json"),
            options: [.atomic]
        )
    }

    private func directoryNames(at url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectValidationIssue(
        _ context: String = "validation",
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("A operação deveria falhar: \(context)")
        } catch is VaultValidationIssue {
            // Expected rejection through the shared validation error contract.
        } catch {
            Issue.record("Erro inesperado em \(context): \(error)")
        }
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
            path: "openpep-backup-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureRoot: URL {
        repositoryRoot.appending(path: "fixtures/backup-v1")
    }

    private var nfdUnmanagedName: String { "cafe\u{301}.txt" }
    private var nfdUnmanagedData: Data { Data("Nome NFD preservado com bytes sintéticos.\n".utf8) }
    private var syntheticDSStoreData: Data { Data("DS_Store regular sintético.\n".utf8) }
}

private struct BackupFixture {
    let vaultURL: URL
    let vaultID: String
}

private struct BackupSyntheticFailure: Error {}
