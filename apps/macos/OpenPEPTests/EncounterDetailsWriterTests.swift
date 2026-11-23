// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("ENCOUNTER-UX-005 synthetic encounter details")
struct EncounterDetailsWriterTests {
    @Test("round trips telemedicine details without changing the draft or encounter extensions")
    func roundTripsDetailsAndPreservesClinicalText() throws {
        try withContext { initialVault in
            var vault = try VaultReader().open(initialVault.url)
            var encounter = vault.patients[0].encounters[0]
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: "Texto sintético salvo antes de editar os detalhes.\n",
                updatedAt: date.addingTimeInterval(60)
            )
            vault = try VaultReader().open(initialVault.url)
            encounter = vault.patients[0].encounters[0]
            var encounterText = try String(contentsOf: encounter.url, encoding: .utf8)
            encounterText = encounterText.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: "x_fixture_label: synthetic\nx_actor_assurance: synthetic_unauthenticated\n"
            )
            try Data(encounterText.utf8).write(to: encounter.url, options: [.atomic])
            vault = try VaultReader().open(initialVault.url)
            encounter = vault.patients[0].encounters[0]
            let draftBytes = try Data(contentsOf: encounter.draft.url)

            let telemedicine = try EncounterDetailsWriter().save(
                in: vault,
                patient: vault.patients[0],
                encounter: encounter,
                expectedData: try Data(contentsOf: encounter.url),
                input: EncounterDetailsInput(
                    modality: .telemedicine,
                    telemedicine: TelemedicineEncounterInput(
                        consent: .confirmed,
                        declaredLocation: " Recife,   PE ",
                        participants: ["Paciente sintético", " Acompanhante sintético "],
                        limitations: "  Áudio instável ",
                        contingency: " Retorno presencial "
                    )
                ),
                remoteAccessURL: " https://meet.google.com/synthetic-room "
            )
            #expect(telemedicine.metadata.modality == "telemedicine")
            #expect(telemedicine.metadata.remoteAccessURL == "https://meet.google.com/synthetic-room")
            #expect(telemedicine.metadata.telemedicine == TelemedicineEncounterMetadata(
                consent: .confirmed,
                declaredLocation: "Recife, PE",
                participants: ["Acompanhante sintético", "Paciente sintético"],
                limitations: "Áudio instável",
                contingency: "Retorno presencial"
            ))
            #expect(try Data(contentsOf: telemedicine.draft.url) == draftBytes)
            #expect(try String(contentsOf: telemedicine.url, encoding: .utf8).contains("x_fixture_label: synthetic\n"))

            vault = try VaultReader().open(initialVault.url)
            encounter = vault.patients[0].encounters[0]
            #expect(encounter.metadata == telemedicine.metadata)
            #expect(try Data(contentsOf: encounter.draft.url) == draftBytes)
            let inPerson = try EncounterDetailsWriter().save(
                in: vault,
                patient: vault.patients[0],
                encounter: encounter,
                expectedData: try Data(contentsOf: encounter.url),
                input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil)
            )
            #expect(inPerson.metadata.modality == "in_person")
            #expect(inPerson.metadata.telemedicine == nil)
            #expect(inPerson.metadata.remoteAccessURL == "https://meet.google.com/synthetic-room")
            #expect(try Data(contentsOf: inPerson.draft.url) == draftBytes)
            #expect(try String(contentsOf: inPerson.url, encoding: .utf8).contains("x_fixture_label: synthetic\n"))

            vault = try VaultReader().open(initialVault.url)
            encounter = vault.patients[0].encounters[0]
            #expect(encounter.metadata.remoteAccessURL == "https://meet.google.com/synthetic-room")
            let returnedToTelemedicine = try EncounterDetailsWriter().save(
                in: vault,
                patient: vault.patients[0],
                encounter: encounter,
                expectedData: try Data(contentsOf: encounter.url),
                input: remoteInput
            )
            #expect(returnedToTelemedicine.metadata.modality == "telemedicine")
            #expect(returnedToTelemedicine.metadata.remoteAccessURL == "https://meet.google.com/synthetic-room")
            #expect(returnedToTelemedicine.metadata.telemedicine?.consent == .notRecorded)
            #expect(try Data(contentsOf: returnedToTelemedicine.draft.url) == draftBytes)
            #expect(try VaultReader().open(initialVault.url).patients[0].encounters[0].metadata.remoteAccessURL
                == "https://meet.google.com/synthetic-room")
        }
    }

    @Test("a saved encounter link cannot be replaced")
    func savedLinkIsFixed() throws {
        try withContext { initial in
            var vault = try VaultReader().open(initial.url)
            var encounter = vault.patients[0].encounters[0]
            _ = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0], encounter: encounter,
                expectedData: Data(contentsOf: encounter.url), input: remoteInput,
                remoteAccessURL: "https://meet.google.com/test-room")
            vault = try VaultReader().open(initial.url); encounter = vault.patients[0].encounters[0]
            let bytes = try Data(contentsOf: encounter.url)
            #expect(throws: VaultValidationIssue.self) {
                _ = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0], encounter: encounter,
                    expectedData: bytes, input: remoteInput, remoteAccessURL: "https://meet.google.com/other-room")
            }
            #expect(try Data(contentsOf: encounter.url) == bytes)
        }
    }

    @Test("rejects invalid or in-person remote links without changing encounter bytes")
    func rejectsInvalidOrInPersonRemoteLinks() throws {
        try withContext { initialVault in
            var vault = try VaultReader().open(initialVault.url)
            var encounter = vault.patients[0].encounters[0]
            let initialBytes = try Data(contentsOf: encounter.url)

            #expect(throws: VaultValidationIssue.self) {
                _ = try EncounterDetailsWriter().save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: encounter,
                    expectedData: initialBytes,
                    input: remoteInput,
                    remoteAccessURL: "http://meet.google.com/synthetic-room"
                )
            }
            #expect(try Data(contentsOf: encounter.url) == initialBytes)

            vault = try VaultReader().open(initialVault.url)
            encounter = vault.patients[0].encounters[0]
            #expect(throws: VaultValidationIssue.self) {
                _ = try EncounterDetailsWriter().save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: encounter,
                    expectedData: initialBytes,
                    input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil),
                    remoteAccessURL: "https://meet.google.com/synthetic-room"
                )
            }
            #expect(try Data(contentsOf: encounter.url) == initialBytes)
        }
    }

    @Test("rejects a stale draft and a finalized encounter without replacing encounter bytes")
    func rejectsStaleAndFinalizedEncounters() throws {
        try withContext { initialVault in
            var vault = try VaultReader().open(initialVault.url)
            let staleEncounter = vault.patients[0].encounters[0]
            let originalEncounterBytes = try Data(contentsOf: staleEncounter.url)
            _ = try ClinicalDraftSaver().save(
                encounter: staleEncounter,
                patientID: patientID,
                body: "Edição concorrente sintética.\n",
                updatedAt: date.addingTimeInterval(60)
            )
            do {
                _ = try EncounterDetailsWriter().save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: staleEncounter,
                    expectedData: try Data(contentsOf: staleEncounter.url),
                    input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil)
                )
                Issue.record("o rascunho obsoleto deveria impedir a atualização")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "encounter_details.revision_conflict")
            }
            #expect(try Data(contentsOf: staleEncounter.url) == originalEncounterBytes)

            vault = try VaultReader().open(initialVault.url)
            let currentPatient = vault.patients[0]
            let currentEncounter = currentPatient.encounters[0]
            _ = try ClinicalFinalizer().finalize(
                patient: currentPatient,
                encounter: currentEncounter,
                identity: FinalizationIdentity(eventID: "evt_0198f5d4-0000-7000-8000-000000000001"),
                finalizedAt: date.addingTimeInterval(120)
            )
            vault = try VaultReader().open(initialVault.url)
            let finalized = vault.patients[0].encounters[0]
            let finalizedEncounterBytes = try Data(contentsOf: finalized.url)
            do {
                _ = try EncounterDetailsWriter().save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: finalized,
                    expectedData: try Data(contentsOf: finalized.url),
                    input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil)
                )
                Issue.record("a consulta finalizada deveria ser somente leitura")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "encounter_details.finalized")
            }
            #expect(try Data(contentsOf: finalized.url) == finalizedEncounterBytes)
        }
    }

    @Test("restores the complete encounter after a simulated publication failure")
    func restoresAfterPublicationFailure() throws {
        try withContext { initialVault in
            let vault = try VaultReader().open(initialVault.url)
            let encounter = vault.patients[0].encounters[0]
            let originalEncounterBytes = try Data(contentsOf: encounter.url)
            let originalDraftBytes = try Data(contentsOf: encounter.draft.url)
            let writer = EncounterDetailsWriter(faultInjector: { step in
                if step == .published { throw DetailsSyntheticFailure() }
            })
            #expect(throws: DetailsSyntheticFailure.self) {
                _ = try writer.save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: encounter,
                    expectedData: try Data(contentsOf: encounter.url),
                    input: EncounterDetailsInput(
                        modality: .telemedicine,
                        telemedicine: TelemedicineEncounterInput(
                            consent: .notRecorded,
                            declaredLocation: nil,
                            participants: [],
                            limitations: nil,
                            contingency: nil
                        )
                    )
                )
            }
            let reopened = try VaultReader().open(initialVault.url).patients[0].encounters[0]
            #expect(try Data(contentsOf: reopened.url) == originalEncounterBytes)
            #expect(try Data(contentsOf: reopened.draft.url) == originalDraftBytes)
            #expect(reopened.finalizationStatus == .draft)
        }
    }

    @Test("keeps an appointment binding and refuses changing its modality")
    func preservesLinkedAppointmentModality() throws {
        try withTemporaryDirectory { root in
            let initialVault = try createVault(in: root)
            let initialPatient = try createPatient(in: initialVault)
            _ = try AppointmentWriter().create(
                in: initialVault.url,
                patient: initialPatient,
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: AppointmentInput(
                    patientID: patientID,
                    startsAt: date,
                    endsAt: date.addingTimeInterval(1_800),
                    timeZone: "America/Sao_Paulo",
                    modality: .telemedicine,
                    status: .scheduled,
                    location: "Consultório sintético",
                    remoteAccessURL: nil,
                    administrativeNote: nil
                ),
                createdAt: date
            )
            var vault = try VaultReader().open(initialVault.url)
            _ = try EncounterStartService().start(
                in: vault,
                patient: vault.patients[0],
                appointment: vault.appointments[0],
                identity: identity,
                input: .scheduled(vault.appointments[0].record),
                startedAt: date
            )
            vault = try VaultReader().open(initialVault.url)
            let encounter = vault.patients[0].encounters[0]
            let encounterBytes = try Data(contentsOf: encounter.url)
            let appointmentBytes = try Data(contentsOf: vault.appointments[0].url)
            #expect(throws: VaultValidationIssue.self) {
                _ = try EncounterDetailsWriter().save(
                    in: vault,
                    patient: vault.patients[0],
                    encounter: encounter,
                    expectedData: try Data(contentsOf: encounter.url),
                    input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil)
                )
            }
            #expect(try Data(contentsOf: encounter.url) == encounterBytes)
            #expect(try Data(contentsOf: vault.appointments[0].url) == appointmentBytes)
            let saved = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0],
                encounter: encounter, expectedData: encounterBytes, input: EncounterDetailsInput(
                    modality: .telemedicine, telemedicine: TelemedicineEncounterInput(
                        consent: .declined, declaredLocation: "Local sintético", participants: [],
                        limitations: nil, contingency: nil)))
            #expect(saved.metadata.telemedicine?.consent == .declined)
            #expect(try Data(contentsOf: vault.appointments[0].url) == appointmentBytes)
            let savedData = try Data(contentsOf: saved.url)
            try FileManager.default.removeItem(at: vault.appointments[0].url)
            #expect(throws: VaultValidationIssue.self) {
                _ = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0],
                    encounter: saved, expectedData: savedData, input: remoteInput)
            }
            #expect(try Data(contentsOf: saved.url) == savedData)
        }
    }

    @Test("detects extension-only changes and refuses nested custom facts without loss")
    func preservesCustomExtensions() throws {
        try withContext { initialVault in
            let vault = try VaultReader().open(initialVault.url)
            let encounter = vault.patients[0].encounters[0]
            let baseline = try Data(contentsOf: encounter.url)
            let updated = String(decoding: baseline, as: UTF8.self).replacingOccurrences(
                of: "x_actor_assurance:", with: "x_custom: synthetic\nx_actor_assurance:"
            )
            try Data(updated.utf8).write(to: encounter.url)
            do {
                _ = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0],
                    encounter: encounter, expectedData: baseline,
                    input: EncounterDetailsInput(modality: .inPerson, telemedicine: nil))
                Issue.record("extension-only conflict must be rejected")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "encounter_details.revision_conflict")
            }
            #expect(try Data(contentsOf: encounter.url) == Data(updated.utf8))
            let remote = try EncounterDetailsWriter().save(in: vault, patient: vault.patients[0],
                encounter: encounter, expectedData: Data(updated.utf8), input: remoteInput)
            let nested = try String(contentsOf: remote.url, encoding: .utf8).replacingOccurrences(
                of: "telemedicine:\n", with: "telemedicine:\n  x_custom: synthetic\n"
            )
            try Data(nested.utf8).write(to: remote.url)
            let freshVault = try VaultReader().open(vault.url)
            for input in [remoteInput, EncounterDetailsInput(modality: .inPerson, telemedicine: nil)] {
                do {
                    _ = try EncounterDetailsWriter().save(in: freshVault, patient: freshVault.patients[0],
                        encounter: freshVault.patients[0].encounters[0], expectedData: Data(nested.utf8), input: input)
                    Issue.record("unsupported nested facts must remain intact")
                } catch let issue as VaultValidationIssue {
                    #expect(issue.rule == "encounter_details.custom_facts")
                }
                #expect(try Data(contentsOf: remote.url) == Data(nested.utf8))
            }
        }
    }

    @Test("preserves a newer external edit and backup when rollback cannot safely restore")
    func preservesExternalEditDuringRollback() throws {
        try withContext { initialVault in
            let vault = try VaultReader().open(initialVault.url)
            let encounter = vault.patients[0].encounters[0]
            let baseline = try Data(contentsOf: encounter.url)
            var externalData = Data()
            let writer = EncounterDetailsWriter(faultInjector: { step in
                if step == .published {
                    let current = try String(contentsOf: encounter.url, encoding: .utf8)
                    externalData = Data(current.replacingOccurrences(of: "x_actor_assurance:",
                        with: "x_newer: synthetic\nx_actor_assurance:").utf8)
                    try externalData.write(to: encounter.url)
                    throw DetailsSyntheticFailure()
                }
            })
            do {
                _ = try writer.save(in: vault, patient: vault.patients[0], encounter: encounter,
                    expectedData: baseline, input: remoteInput)
                Issue.record("rollback conflict must be reported")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "encounter_details.rollback_failed")
            }
            #expect(try Data(contentsOf: encounter.url) == externalData)
            let backups = try FileManager.default.contentsOfDirectory(at: encounter.url.deletingLastPathComponent(),
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".openpep-encounter-details-backup-") }
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: #require(backups.first)) == baseline)
        }
    }

    private var remoteInput: EncounterDetailsInput {
        EncounterDetailsInput(modality: .telemedicine, telemedicine: TelemedicineEncounterInput(
            consent: .notRecorded, declaredLocation: nil, participants: [], limitations: nil, contingency: nil
        ))
    }

    private var patientID: String { "pt_0198f5c2-0000-7000-8000-000000000001" }
    private var appointmentID: String { "appt_0198f6c0-0000-7000-8000-000000000001" }
    private var date: Date { Date(timeIntervalSince1970: 1_788_110_400) }
    private var identity: ClinicalDraftCreationIdentity {
        ClinicalDraftCreationIdentity(
            encounterID: "enc_0198f5d1-0000-7000-8000-000000000001",
            noteID: "note_0198f5d3-0000-7000-8000-000000000001",
            syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000001"
        )
    }

    private func withContext(_ body: (VaultSummary) throws -> Void) throws {
        try withTemporaryDirectory { root in
            let vault = try createVault(in: root)
            _ = try createPatient(in: vault)
            let opened = try VaultReader().open(vault.url)
            _ = try EncounterStartService().start(
                in: opened,
                patient: opened.patients[0],
                appointment: nil,
                identity: identity,
                input: EncounterStartInput(modality: .inPerson, template: .blank, telemedicine: nil),
                startedAt: date
            )
            try body(vault)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-encounter-details-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func createVault(in root: URL) throws -> VaultSummary {
        try VaultCreator().create(
            in: root,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: date
        )
    }

    private func createPatient(in vault: VaultSummary) throws -> PatientSummary {
        try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético dos Detalhes",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date
        )
    }
}

private struct DetailsSyntheticFailure: Error {}
