// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct EncounterTranscriptStoreTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let encounterID = "enc_0198f5d1-0000-7000-8000-000000000001"
    private let noteID = "note_0198f5d3-0000-7000-8000-000000000001"
    private let actorID = "usr_0198f4a0-0000-7000-8000-000000000001"
    private let assetID = "asset_0198f5d5-0000-7000-8000-000000000001"
    private let operationID = "0198f5d5-0000-7000-8000-000000000002"
    private let date = Date(timeIntervalSince1970: 1_788_110_400)

    @Test("persists a local transcript as one linked text asset without changing the draft")
    func persistsLinkedTextOnly() throws {
        try withEncounter { vault, patient, encounter in
            let result = try EncounterTranscriptStore().save(
                in: vault,
                patient: patient,
                encounter: encounter,
                input: input(text: "Transcrição sintética com acentuação."),
                identity: RawAssetCreationIdentity(assetID: assetID),
                deviceID: vault.manifest.deviceID,
                savedAt: date
            )
            let text = try String(contentsOf: result.originalURL, encoding: .utf8)
            #expect(text.contains("Motor: SpeechTranscriber"))
            #expect(text.contains("Localidade: pt-BR"))
            #expect(text.contains("SHA-256 do áudio: \(String(repeating: "a", count: 64))"))
            #expect(text.contains("Transcrição sintética com acentuação."))

            let reopened = try VaultReader().open(vault.url)
            let currentPatient = try #require(reopened.patients.first)
            let asset = try #require(currentPatient.rawAssets.first)
            #expect(currentPatient.rawAssets.count == 1)
            #expect(asset.assetID == assetID)
            #expect(asset.encounterID == encounterID)
            #expect(asset.mediaType == "text/plain")
            #expect(asset.fileExtension == "txt")
            #expect(try #require(currentPatient.encounters.first).draft.persistedData == encounter.draft.persistedData)
            #expect(try FileManager.default.contentsOfDirectory(
                at: result.originalURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension != "md" }.map(\.pathExtension) == ["txt"])

            let documents = try EncounterTranscriptDocumentReader().read(
                vaultURL: vault.url,
                patientID: patientID,
                encounterID: encounterID
            )
            let document = try #require(documents.first)
            #expect(documents.count == 1)
            #expect(document.id == assetID)
            #expect(document.name.hasPrefix("Transcrição · "))
            #expect(document.text == "Transcrição sintética com acentuação.\n")
            #expect(!document.text.contains("Motor: SpeechTranscriber"))
        }
    }

    @Test("reader refuses a transcript whose original bytes were changed")
    func readerRejectsTamperedTranscript() throws {
        try withEncounter { vault, patient, encounter in
            let result = try EncounterTranscriptStore().save(
                in: vault,
                patient: patient,
                encounter: encounter,
                input: input(text: "Transcrição sintética íntegra."),
                identity: RawAssetCreationIdentity(assetID: assetID),
                deviceID: vault.manifest.deviceID,
                savedAt: date
            )
            try Data("Transcrição sintética adulterada.\n".utf8).write(
                to: result.originalURL,
                options: [.atomic]
            )

            expectPatientAIChanged {
                _ = try EncounterTranscriptDocumentReader().read(
                    vaultURL: vault.url,
                    patientID: patientID,
                    encounterID: encounterID
                )
            }
        }
    }

    @Test("reader reopens stable live transcript from consultation work")
    func reopensLiveTranscriptFromConsultationWork() throws {
        try withEncounter { vault, patient, encounter in
            let binding = EncounterTranscriptionBinding(
                vaultURL: vault.url,
                vaultID: vault.manifest.vaultID,
                patientID: patientID,
                encounterID: encounterID,
                patientName: patient.displayName
            )
            var work = ProgressiveConsultationWork(
                binding: binding,
                source: .microphone,
                summaryIntervalSeconds: 60,
                transcriptionEngine: "apple/SpeechTranscriber",
                transcriptionModel: "pt-BR",
                summaryEngine: "apple/FoundationModels.SystemLanguageModel",
                summaryModel: nil,
                now: date
            )
            work.capture.startedAt = date
            work.capture.capturedSeconds = 81.8
            work.segments = [ConsultationTranscriptSegment(
                id: "segment_0198f5da-0000-7000-8000-000000000099",
                revision: 1,
                range: .init(startSeconds: 0, endSeconds: 81.8006875, isApproximate: false),
                text: "Queixa sintética estabilizada.\nNega febre.",
                engine: "apple/SpeechTranscriber",
                model: "pt-BR",
                attemptID: work.capture.attemptID
            )]
            _ = try ProgressiveConsultationWorkStore().save(work, binding: binding)

            let documents = try EncounterTranscriptDocumentReader().read(
                vaultURL: vault.url,
                patientID: patientID,
                encounterID: encounterID
            )

            let document = try #require(documents.first)
            #expect(documents.count == 1)
            #expect(document.id == work.sessionID)
            #expect(document.name.hasPrefix("Transcrição ao vivo · "))
            #expect(document.text == "Queixa sintética estabilizada.\nNega febre.\n")
            #expect(try Data(contentsOf: encounter.draft.url) == encounter.draft.persistedData)
        }
    }

    @Test("saves against the current draft after an intervening note edit")
    func savesAgainstCurrentEncounter() throws {
        try withEncounter { vault, patient, encounter in
            let latestBody = "Edição sintética feita enquanto a transcrição era processada.\n"
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: latestBody,
                updatedAt: date.addingTimeInterval(30)
            )

            let result = try EncounterTranscriptStore().saveToCurrentEncounter(
                in: vault.url,
                vaultID: vault.manifest.vaultID,
                patientID: patientID,
                encounterID: encounterID,
                input: input(text: "Transcrição concluída após a edição."),
                identity: RawAssetCreationIdentity(assetID: assetID),
                deviceID: vault.manifest.deviceID,
                savedAt: date.addingTimeInterval(60)
            )

            let reopened = try VaultReader().open(vault.url)
            let currentPatient = try #require(reopened.patients.first)
            let currentEncounter = try #require(currentPatient.encounters.first)
            let asset = try #require(currentPatient.rawAssets.first)
            #expect(currentEncounter.draft.body == latestBody)
            #expect(asset.assetID == assetID)
            #expect(asset.encounterID == encounterID)
            #expect(asset.originalURL == result.originalURL)
            #expect(try String(contentsOf: asset.originalURL, encoding: .utf8)
                .contains("Transcrição concluída após a edição."))
        }
    }

    @Test("current encounter save rejects a different vault identity")
    func currentEncounterRejectsWrongVaultIdentity() throws {
        try withEncounter { vault, patient, _ in
            expectRule("transcript.encounter_changed") {
                _ = try EncounterTranscriptStore().saveToCurrentEncounter(
                    in: vault.url,
                    vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536ffff",
                    patientID: patientID,
                    encounterID: encounterID,
                    input: input(text: "Não publicar em outro prontuário."),
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date
                )
            }
            let files = try rawFiles(in: patient)
            #expect(files.isEmpty)
        }
    }

    @Test("current encounter save rejects a finalized encounter")
    func currentEncounterRejectsFinalizedEncounter() throws {
        try withEncounter { vault, patient, encounter in
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: "Nota sintética pronta para finalizar.\n",
                updatedAt: date.addingTimeInterval(30)
            )
            let currentPatient = try #require(VaultReader().open(vault.url).patients.first)
            let currentEncounter = try #require(currentPatient.encounters.first)
            _ = try ClinicalFinalizer().finalize(
                patient: currentPatient,
                encounter: currentEncounter,
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5d6-0000-7000-8000-000000000001"
                ),
                finalizedAt: date.addingTimeInterval(60)
            )

            expectRule("transcript.encounter_changed") {
                _ = try EncounterTranscriptStore().saveToCurrentEncounter(
                    in: vault.url,
                    vaultID: vault.manifest.vaultID,
                    patientID: patientID,
                    encounterID: encounterID,
                    input: input(text: "Não publicar após finalizar."),
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date.addingTimeInterval(90)
                )
            }
            let files = try rawFiles(in: patient)
            #expect(files.isEmpty)
        }
    }

    @Test("current encounter save rejects a trashed encounter")
    func currentEncounterRejectsTrashedEncounter() throws {
        try withEncounter { vault, patient, encounter in
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: "Rascunho sintético destinado à lixeira.\n",
                updatedAt: date.addingTimeInterval(30)
            )
            let reopened = try VaultReader().open(vault.url)
            let currentPatient = try #require(reopened.patients.first)
            let currentEncounter = try #require(currentPatient.encounters.first)
            _ = try DraftTrashService().discard(
                in: reopened,
                patient: currentPatient,
                encounter: currentEncounter,
                expectedData: Data(contentsOf: currentEncounter.url),
                at: date.addingTimeInterval(60)
            )

            expectRule("transcript.encounter_changed") {
                _ = try EncounterTranscriptStore().saveToCurrentEncounter(
                    in: vault.url,
                    vaultID: vault.manifest.vaultID,
                    patientID: patientID,
                    encounterID: encounterID,
                    input: input(text: "Não publicar na lixeira."),
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date.addingTimeInterval(90)
                )
            }
            let files = try rawFiles(in: patient)
            #expect(files.isEmpty)
        }
    }

    @Test("an empty draft with a transcript round-trips through trash byte for byte")
    func transcriptKeepsEmptyDraftRecoverableThroughTrash() throws {
        try withEncounter { vault, _, encounter in
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: "",
                updatedAt: date.addingTimeInterval(30)
            )
            var reopened = try VaultReader().open(vault.url)
            var currentPatient = try #require(reopened.patients.first)
            let clearedEncounter = try #require(currentPatient.encounters.first)
            let saved = try EncounterTranscriptStore().save(
                in: reopened,
                patient: currentPatient,
                encounter: clearedEncounter,
                input: input(text: "Transcrição sintética recuperável."),
                identity: RawAssetCreationIdentity(assetID: assetID),
                deviceID: vault.manifest.deviceID,
                savedAt: date.addingTimeInterval(60)
            )
            let transcriptData = try Data(contentsOf: saved.originalURL)

            reopened = try VaultReader().open(vault.url)
            currentPatient = try #require(reopened.patients.first)
            let activeEncounter = try #require(currentPatient.encounters.first)
            #expect(activeEncounter.draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let moved = try DraftTrashService().discard(
                in: reopened,
                patient: currentPatient,
                encounter: activeEncounter,
                expectedData: Data(contentsOf: activeEncounter.url),
                at: date.addingTimeInterval(90)
            )
            #expect(moved)

            reopened = try VaultReader().open(vault.url)
            currentPatient = try #require(reopened.patients.first)
            #expect(currentPatient.encounters.isEmpty)
            #expect(currentPatient.rawAssets.isEmpty)
            let trashedEncounter = try #require(currentPatient.trashedEncounters.first)
            let trashedTranscript = try #require(currentPatient.trashedRawAssets.first)
            #expect(currentPatient.trashedEncounters.count == 1)
            #expect(currentPatient.trashedRawAssets.count == 1)
            #expect(trashedTranscript.assetID == assetID)
            #expect(try Data(contentsOf: trashedTranscript.originalURL) == transcriptData)
            expectPatientAIChanged {
                _ = try EncounterTranscriptDocumentReader().read(
                    vaultURL: vault.url,
                    patientID: patientID,
                    encounterID: encounterID
                )
            }

            try DraftTrashService().restore(
                in: reopened,
                patient: currentPatient,
                encounter: trashedEncounter,
                expectedData: Data(contentsOf: trashedEncounter.url)
            )

            reopened = try VaultReader().open(vault.url)
            currentPatient = try #require(reopened.patients.first)
            #expect(currentPatient.trashedEncounters.isEmpty)
            #expect(currentPatient.trashedRawAssets.isEmpty)
            #expect(currentPatient.encounters.count == 1)
            let restoredTranscript = try #require(currentPatient.rawAssets.first)
            #expect(currentPatient.rawAssets.count == 1)
            #expect(restoredTranscript.assetID == assetID)
            #expect(restoredTranscript.encounterID == encounterID)
            #expect(try Data(contentsOf: restoredTranscript.originalURL) == transcriptData)
            let restoredDocuments = try EncounterTranscriptDocumentReader().read(
                vaultURL: vault.url,
                patientID: patientID,
                encounterID: encounterID
            )
            #expect(restoredDocuments.map(\.text) == ["Transcrição sintética recuperável.\n"])
        }
    }

    @Test("retries the same operation idempotently and rejects different content")
    func idempotentRetryAndConflict() throws {
        try withEncounter { vault, patient, encounter in
            let store = EncounterTranscriptStore()
            let identity = RawAssetCreationIdentity(assetID: assetID)
            let first = try store.save(
                in: vault,
                patient: patient,
                encounter: encounter,
                input: input(text: "Mesmo resultado sintético."),
                identity: identity,
                deviceID: vault.manifest.deviceID,
                savedAt: date
            )
            let retried = try store.save(
                in: vault,
                patient: patient,
                encounter: encounter,
                input: input(text: "Mesmo resultado sintético."),
                identity: identity,
                deviceID: vault.manifest.deviceID,
                savedAt: date
            )
            #expect(retried == first)
            #expect(try VaultReader().open(vault.url).patients.first?.rawAssets.count == 1)

            expectRule("transcript.identity_conflict") {
                _ = try store.save(
                    in: vault,
                    patient: patient,
                    encounter: encounter,
                    input: input(text: "Resultado diferente."),
                    identity: identity,
                    deviceID: vault.manifest.deviceID,
                    savedAt: date
                )
            }
            #expect(try VaultReader().open(vault.url).patients.first?.rawAssets.count == 1)
        }
    }

    @Test("refuses a changed or discarded encounter before import")
    func refusesChangedEncounter() throws {
        try withEncounter { vault, patient, encounter in
            let changed = encounter.draft.persistedData + Data("mudança concorrente\n".utf8)
            try changed.write(to: encounter.draft.url, options: [.atomic])
            expectRule("transcript.encounter_changed") {
                _ = try EncounterTranscriptStore().save(
                    in: vault,
                    patient: patient,
                    encounter: encounter,
                    input: input(text: "Não publicar."),
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date
                )
            }
            let files = try rawFiles(in: patient)
            #expect(files.isEmpty)
        }
    }

    @Test("reports a concurrent encounter change after import and preserves the linked transcript")
    func preservesImportAfterConcurrentChange() throws {
        try withEncounter { vault, patient, encounter in
            let store = EncounterTranscriptStore(faultInjector: { step in
                if step == .imported {
                    let changed = encounter.draft.persistedData + Data("mudança após importação\n".utf8)
                    try changed.write(to: encounter.draft.url, options: [.atomic])
                }
            })
            expectRule("transcript.encounter_changed_after_import") {
                _ = try store.save(
                    in: vault,
                    patient: patient,
                    encounter: encounter,
                    input: input(text: "Texto que deve permanecer recuperável."),
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date
                )
            }
            let reopened = try VaultReader().open(vault.url)
            let asset = try #require(reopened.patients.first?.rawAssets.first)
            #expect(asset.assetID == assetID)
            #expect(try String(contentsOf: asset.originalURL, encoding: .utf8)
                .contains("Texto que deve permanecer recuperável."))
        }
    }

    @Test("rejects invalid audio provenance without writing raw files")
    func validatesProvenance() throws {
        try withEncounter { vault, patient, encounter in
            let invalid = EncounterTranscriptInput(
                text: "Texto sintético",
                audioSHA256: "não é hash",
                localeIdentifier: "pt-BR",
                operationID: operationID
            )
            expectRule("transcript.invalid_input") {
                _ = try EncounterTranscriptStore().save(
                    in: vault,
                    patient: patient,
                    encounter: encounter,
                    input: invalid,
                    identity: RawAssetCreationIdentity(assetID: assetID),
                    deviceID: vault.manifest.deviceID,
                    savedAt: date
                )
            }
            let files = try rawFiles(in: patient)
            #expect(files.isEmpty)
        }
    }

    private func input(text: String) -> EncounterTranscriptInput {
        EncounterTranscriptInput(
            text: text,
            audioSHA256: String(repeating: "a", count: 64),
            localeIdentifier: "pt-BR",
            operationID: operationID
        )
    }

    private func rawFiles(in patient: PatientSummary) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: patient.url.appending(path: "raw"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
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

    private func expectPatientAIChanged(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("a transcrição indisponível não deveria ser exibida")
        } catch let issue as PatientAIIssue {
            guard case .changed = issue else {
                Issue.record("era esperado changed, recebido \(issue)")
                return
            }
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
    }

    private func withEncounter(
        _ body: (VaultSummary, PatientSummary, EncounterSummary) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-transcript-store-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let createdVault = try VaultCreator().create(
            in: root,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: date
        )
        let createdPatient = try PatientCreator().createRegistered(
            in: createdVault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente de Transcrição Sintético",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )
        _ = try ClinicalDraftCreator().create(
            in: createdPatient,
            identity: ClinicalDraftCreationIdentity(
                encounterID: encounterID,
                noteID: noteID,
                syntheticActorID: actorID
            ),
            startedAt: date
        )
        let vault = try VaultReader().open(createdVault.url)
        let patient = try #require(vault.patients.first)
        let encounter = try #require(patient.encounters.first)
        try body(vault, patient, encounter)
    }
}
