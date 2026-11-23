// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("MAC-003 synthetic encounter and draft")
struct EncounterServiceTests {
    @Test("Swift reads the same golden encounter and draft as protocol-schema")
    func readsGoldenFixture() throws {
        let encounterURL = validFixtureRoot.appending(path: "encounter.md")
        let draftURL = validFixtureRoot.appending(path: "draft.md")
        let encounter = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: encounterURL),
            source: encounterURL.path
        )
        let draft = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: draftURL),
            source: draftURL.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: encounter,
            draft: draft.metadata,
            expectedPatientID: expectedPatientID
        )

        #expect(encounter.encounterID == expectedEncounterID)
        #expect(draft.metadata.noteID == expectedNoteID)
        #expect(draft.metadata.status == "draft")
        #expect(draft.body == "Texto clínico sintético para desenvolvimento.\n")
    }

    @Test("imports a free Markdown template with a stable content version")
    func importsMarkdownTemplate() throws {
        let first = try ClinicalTemplateChoice.imported(
            data: Data("## Evoluc\u{327}a\u{303}o\r\n\r\nTexto livre\r".utf8),
            fileName: "meu-template.md"
        )
        let second = try ClinicalTemplateChoice.imported(
            data: Data("## Evolução\n\nTexto livre\n".utf8),
            fileName: "meu-template.md"
        )
        #expect(first == second)
        #expect(first.templateID == "file/meu-template.md")
        #expect(first.version.hasPrefix("sha256:"))
        #expect(first.version.count == 71)
        #expect(first.body == "## Evolução\n\nTexto livre\n")
    }

    @Test("starts and reopens a standalone telemedicine encounter with declared facts")
    func startsStandaloneTelemedicineEncounter() throws {
        try withTemporaryDirectory { parent in
            let initialVault = try createVault(in: parent)
            _ = try createRegisteredPatient(in: initialVault)
            let vault = try VaultReader().open(initialVault.url)
            let patient = try #require(vault.patients.first)
            let input = EncounterStartInput(
                modality: .telemedicine,
                template: .standard,
                telemedicine: TelemedicineEncounterInput(
                    consent: .confirmed,
                    declaredLocation: " Manaus,   AM ",
                    participants: ["Paciente sintético", " Acompanhante sintético "],
                    limitations: "Vídeo indisponível no início",
                    contingency: "Continuidade por áudio"
                )
            )
            let result = try EncounterStartService().start(
                in: vault,
                patient: patient,
                appointment: nil,
                identity: fixedIdentity,
                input: input,
                startedAt: fixedDate
            )
            #expect(result.appointment == nil)
            #expect(result.encounter.metadata.appointmentID == nil)
            #expect(result.encounter.metadata.modality == "telemedicine")
            #expect(result.encounter.metadata.templateID == "openpep/progress")
            #expect(result.encounter.metadata.telemedicine == TelemedicineEncounterMetadata(
                consent: .confirmed,
                declaredLocation: "Manaus, AM",
                participants: ["Acompanhante sintético", "Paciente sintético"],
                limitations: "Vídeo indisponível no início",
                contingency: "Continuidade por áudio"
            ))
            #expect(result.encounter.draft.body == OptionalClinicalDraftTemplate.text + "\n")

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients[0].encounters[0] == result.encounter)
        }
    }

    @Test("rejects an oversized declared fact without truncating or publishing files")
    func rejectsOversizedTelemedicineFactAtomically() throws {
        try withTemporaryDirectory { parent in
            let initialVault = try createVault(in: parent)
            _ = try createRegisteredPatient(in: initialVault)
            let vault = try VaultReader().open(initialVault.url)
            let patient = try #require(vault.patients.first)
            let input = EncounterStartInput(
                modality: .telemedicine,
                template: .blank,
                telemedicine: TelemedicineEncounterInput(
                    consent: .notRecorded,
                    declaredLocation: String(repeating: "x", count: 201),
                    participants: [],
                    limitations: nil,
                    contingency: nil
                )
            )

            do {
                _ = try EncounterStartService().start(
                    in: vault,
                    patient: patient,
                    appointment: nil,
                    identity: fixedIdentity,
                    input: input,
                    startedAt: fixedDate
                )
                Issue.record("o fato longo não deveria ser truncado nem persistido")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "schema.length")
                #expect(issue.path == "/telemedicine/declared_location")
            }

            let reopened = try VaultReader().open(initialVault.url)
            #expect(reopened.patients[0].encounters.isEmpty)
        }
    }

    @Test("links an appointment and recovers the same encounter after an interrupted link")
    func linksAndRecoversAppointmentEncounter() throws {
        try withTemporaryDirectory { parent in
            let initialVault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: initialVault)
            _ = try AppointmentWriter().create(
                in: initialVault.url,
                patient: initialPatient,
                identity: AppointmentCreationIdentity(
                    appointmentID: "appt_0198f6c0-0000-7000-8000-000000000001"
                ),
                input: AppointmentInput(
                    patientID: expectedPatientID,
                    startsAt: fixedDate,
                    endsAt: fixedDate.addingTimeInterval(1_800),
                    timeZone: "America/Sao_Paulo",
                    modality: .inPerson,
                    status: .scheduled,
                    location: "Consultório sintético",
                    remoteAccessURL: nil,
                    administrativeNote: nil
                ),
                createdAt: fixedDate
            )
            let beforeFailure = try VaultReader().open(initialVault.url)
            let patient = try #require(beforeFailure.patients.first)
            let appointment = try #require(beforeFailure.appointments.first)
            let input = EncounterStartInput(
                modality: .inPerson,
                template: .blank,
                telemedicine: nil
            )
            let interrupted = EncounterStartService(appointmentFaultInjector: { step in
                if step == .temporaryWritten { throw DraftSyntheticFailure() }
            })
            #expect(throws: DraftSyntheticFailure.self) {
                _ = try interrupted.start(
                    in: beforeFailure,
                    patient: patient,
                    appointment: appointment,
                    identity: fixedIdentity,
                    input: input,
                    startedAt: fixedDate
                )
            }

            let pending = try VaultReader().open(initialVault.url)
            #expect(pending.patients[0].encounters.count == 1)
            #expect(pending.appointments[0].record.encounterID == nil)
            #expect(throws: VaultValidationIssue.self) {
                _ = try AppointmentWriter().cancel(
                    pending.appointments[0],
                    in: pending.url,
                    patients: pending.patients,
                    updatedAt: fixedDate.addingTimeInterval(30)
                )
            }
            #expect(try VaultReader().open(initialVault.url).appointments[0].record.status == .scheduled)
            let recovered = try EncounterStartService().start(
                in: pending,
                patient: pending.patients[0],
                appointment: pending.appointments[0],
                identity: ClinicalDraftCreationIdentity(
                    encounterID: "enc_0198f5d1-0000-7000-8000-000000000099",
                    noteID: "note_0198f5d3-0000-7000-8000-000000000099",
                    syntheticActorID: "usr_0198f4a0-0000-7000-8000-000000000099"
                ),
                input: input,
                startedAt: fixedDate.addingTimeInterval(60)
            )
            #expect(recovered.recoveredPendingLink)
            #expect(recovered.encounter.metadata.encounterID == expectedEncounterID)
            #expect(recovered.appointment?.record.encounterID == expectedEncounterID)
            #expect(recovered.appointment?.record.status == .inProgress)

            let final = try VaultReader().open(initialVault.url)
            #expect(final.patients[0].encounters.count == 1)
            #expect(final.appointments[0].record.encounterID == expectedEncounterID)
        }
    }

    @Test("Swift rejects the persisted invalid clinical document fixtures")
    func rejectsPersistedInvalidFixtures() throws {
        let invalidRoot = repositoryRoot.appending(path: "fixtures/clinical-draft-v1/invalid")
        do {
            let url = invalidRoot.appending(path: "unknown-encounter-field/encounter.md")
            _ = try ClinicalDocumentValidator.validateEncounter(
                data: Data(contentsOf: url),
                source: url.path
            )
            Issue.record("o campo desconhecido do encontro deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "schema.additionalProperties")
            #expect(issue.path == "/unexpected_field")
        }

        do {
            let url = invalidRoot.appending(path: "unknown-draft-field/draft.md")
            _ = try ClinicalDocumentValidator.validateDraft(
                data: Data(contentsOf: url),
                source: url.path
            )
            Issue.record("o campo desconhecido do rascunho deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "schema.additionalProperties")
            #expect(issue.path == "/unexpected_field")
        }

        let mismatchRoot = invalidRoot.appending(path: "mismatched-patient")
        let encounter = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: mismatchRoot.appending(path: "encounter.md")),
            source: "encounter.md"
        )
        let draft = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: mismatchRoot.appending(path: "draft.md")),
            source: "draft.md"
        )
        do {
            try ClinicalDocumentValidator.bind(
                encounter: encounter,
                draft: draft.metadata,
                expectedPatientID: expectedPatientID
            )
            Issue.record("o vínculo divergente deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.patient_mismatch")
            #expect(issue.path == "/patient_id")
        }

        do {
            try ClinicalDocumentValidator.bind(
                encounter: encounter,
                draft: draft.metadata,
                expectedPatientID: "pt_0198f5c2-0000-7000-8000-000000000002"
            )
            Issue.record("o diretório de outro paciente deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.patient_mismatch")
            #expect(issue.path == "/patient_id")
        }

        let validBindingDraft = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: validFixtureRoot.appending(path: "draft.md")),
            source: "valid-binding-draft.md"
        ).metadata
        let mismatchedEncounterDraft = ClinicalDraftMetadata(
            noteID: validBindingDraft.noteID,
            patientID: validBindingDraft.patientID,
            encounterID: "enc_0198f5d1-0000-7000-8000-000000000002",
            status: validBindingDraft.status,
            noteType: validBindingDraft.noteType,
            authorID: validBindingDraft.authorID,
            createdAt: validBindingDraft.createdAt,
            updatedAt: validBindingDraft.updatedAt
        )
        do {
            try ClinicalDocumentValidator.bind(
                encounter: encounter,
                draft: mismatchedEncounterDraft,
                expectedPatientID: encounter.patientID
            )
            Issue.record("o vínculo com outro encontro deveria ser recusado")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.encounter_mismatch")
            #expect(issue.path == "/encounter_id")
        }

        let mismatchedAuthorDraft = ClinicalDraftMetadata(
            noteID: validBindingDraft.noteID,
            patientID: validBindingDraft.patientID,
            encounterID: validBindingDraft.encounterID,
            status: validBindingDraft.status,
            noteType: validBindingDraft.noteType,
            authorID: "usr_0198f4a0-0000-7000-8000-000000000002",
            createdAt: validBindingDraft.createdAt,
            updatedAt: validBindingDraft.updatedAt
        )
        do {
            try ClinicalDocumentValidator.bind(
                encounter: encounter,
                draft: mismatchedAuthorDraft,
                expectedPatientID: encounter.patientID
            )
            Issue.record("a identidade divergente deveria ser recusada")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "clinical_document.author_mismatch")
            #expect(issue.path == "/author_id")
        }

        let validEncounterURL = validFixtureRoot.appending(path: "encounter.md")
        let validEncounter = try #require(String(
            data: Data(contentsOf: validEncounterURL),
            encoding: .utf8
        ))
        let fractional = validEncounter.replacingOccurrences(
            of: "2026-08-30T17:20:00Z",
            with: "2026-08-30T17:20:00.123Z"
        )
        #expect(try ClinicalDocumentValidator.validateEncounter(
            data: Data(fractional.utf8),
            source: "fractional.md"
        ).startedAt == "2026-08-30T17:20:00.123Z")
        for invalid in [
            validEncounter.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: ""
            ),
            validEncounter.replacingOccurrences(
                of: "synthetic_unauthenticated",
                with: "verified_professional"
            ),
        ] {
            #expect(throws: VaultValidationIssue.self) {
                _ = try ClinicalDocumentValidator.validateEncounter(
                    data: Data(invalid.utf8),
                    source: "invalid-encounter-assurance.md"
                )
            }
        }
        for timestamp in [
            "2026-8-30T17:20:00Z",
            "2026-02-29T17:20:00Z",
            "2026-08-30T17:20:60Z",
            "0000-02-29T17:20:00Z",
        ] {
            let invalid = validEncounter.replacingOccurrences(
                of: "2026-08-30T17:20:00Z",
                with: timestamp
            )
            #expect(throws: VaultValidationIssue.self) {
                _ = try ClinicalDocumentValidator.validateEncounter(
                    data: Data(invalid.utf8),
                    source: "invalid-date.md"
                )
            }
        }

        let validDraft = try #require(String(
            data: Data(contentsOf: validFixtureRoot.appending(path: "draft.md")),
            encoding: .utf8
        ))
        let draftWithSource = validDraft.replacingOccurrences(
            of: "source_ids: []",
            with: "source_ids:\n  - asset_0198f5c2-0000-7000-8000-000000000001"
        )
        do {
            _ = try ClinicalDocumentValidator.validateDraft(
                data: Data(draftWithSource.utf8),
                source: "draft-with-source.md"
            )
            Issue.record("source_ids deveria permanecer vazio neste perfil")
        } catch let issue as VaultValidationIssue {
            #expect(issue.rule == "schema.maxItems")
            #expect(issue.path == "/source_ids")
        }

        for invalid in [
            validDraft.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: ""
            ),
            validDraft.replacingOccurrences(
                of: "synthetic_unauthenticated",
                with: "verified_professional"
            ),
        ] {
            #expect(throws: VaultValidationIssue.self) {
                _ = try ClinicalDocumentValidator.validateDraft(
                    data: Data(invalid.utf8),
                    source: "invalid-assurance.md"
                )
            }
        }
    }

    @Test("creates fixture-compatible files and reopens the draft")
    func createsAndReopensDraft() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            let encounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )

            #expect(try Data(contentsOf: encounter.url) == Data(contentsOf: validFixtureRoot.appending(path: "encounter.md")))
            #expect(try Data(contentsOf: encounter.draft.url) == Data(contentsOf: validFixtureRoot.appending(path: "draft.md")))

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.count == 1)
            #expect(reopened.patients[0].encounters.count == 1)
            #expect(reopened.patients[0].encounters[0].draft.body == encounter.draft.body)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: patient.url.appending(path: ".openpep").path
            ).isEmpty)
        }
    }

    @Test("rejects unsafe IDs, overwrite and an interrupted pair")
    func rejectsUnsafeOverwriteAndPartialPair() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)

            do {
                _ = try ClinicalDraftCreator().create(
                    in: patient,
                    identity: ClinicalDraftCreationIdentity(
                        encounterID: "../unsafe",
                        noteID: expectedNoteID,
                        syntheticActorID: expectedAuthorID
                    ),
                    startedAt: fixedDate
                )
                Issue.record("o ID inseguro deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.invalid_id")
            }

            let concurrentEncounterURL = patient.url.appending(
                path: "content/encounters/\(expectedEncounterID).md"
            )
            let concurrentBytes = Data("arquivo sintético de outra operação\n".utf8)
            let concurrent = ClinicalDraftCreator(faultInjector: { step in
                if step == .temporaryFilesWritten {
                    try concurrentBytes.write(to: concurrentEncounterURL, options: [.withoutOverwriting])
                    throw DraftSyntheticFailure()
                }
            })
            do {
                _ = try concurrent.create(
                    in: patient,
                    identity: fixedIdentity,
                    startedAt: fixedDate
                )
                Issue.record("a criação concorrente deveria interromper a operação")
            } catch is DraftSyntheticFailure {
                #expect(try Data(contentsOf: concurrentEncounterURL) == concurrentBytes)
                try FileManager.default.removeItem(at: concurrentEncounterURL)
                try FileManager.default.removeItem(
                    at: concurrentEncounterURL.deletingLastPathComponent()
                )
            }

            let interrupted = ClinicalDraftCreator(faultInjector: { step in
                if step == .encounterPublished { throw DraftSyntheticFailure() }
            })
            do {
                _ = try interrupted.create(
                    in: patient,
                    identity: fixedIdentity,
                    startedAt: fixedDate
                )
                Issue.record("a falha injetada deveria interromper a criação")
            } catch is DraftSyntheticFailure {
                #expect(try FileManager.default.contentsOfDirectory(
                    atPath: patient.url.appending(path: "content").path
                ).isEmpty)
            }

            _ = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let original = try Data(contentsOf: patient.url.appending(
                path: "content/notes/drafts/\(expectedNoteID).md"
            ))
            do {
                _ = try ClinicalDraftCreator().create(
                    in: patient,
                    identity: fixedIdentity,
                    startedAt: fixedDate
                )
                Issue.record("o destino existente deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.destination_exists")
                #expect(try Data(contentsOf: patient.url.appending(
                    path: "content/notes/drafts/\(expectedNoteID).md"
                )) == original)
            }
        }
    }

    @Test("saves NFC and LF while preserving a validated x_ field")
    func savesNormalizedDraftAndPreservesExtension() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            var encounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            var text = try #require(String(data: Data(contentsOf: encounter.draft.url), encoding: .utf8))
            text = text.replacingOccurrences(
                of: "finalization: null\n",
                with: "finalization: null\nx_fixture_label: synthetic\n"
            )
            try Data(text.utf8).write(to: encounter.draft.url, options: [.atomic])
            encounter = try #require(VaultReader().open(vault.url).patients[0].encounters.first)

            let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-08-30T17:25:00Z"))
            let saved = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: expectedPatientID,
                body: "Evoluc\u{327}a\u{303}o sintética\r\nsegunda linha\r",
                updatedAt: updatedAt
            )
            let bytes = try Data(contentsOf: saved.url)
            let savedText = try #require(String(data: bytes, encoding: .utf8))
            #expect(!savedText.contains("\r"))
            #expect(savedText.precomposedStringWithCanonicalMapping == savedText)
            #expect(savedText.contains("x_fixture_label: synthetic\n"))
            #expect(saved.body == "Evolução sintética\nsegunda linha\n")
            #expect(saved.metadata.updatedAt == "2026-08-30T17:25:00Z")
        }
    }

    @Test("recognizes saved typing buffers and rejects subsequent content edits")
    func typingBufferSurvivesSaveAndContinuedEditing() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            var encounter = try ClinicalDraftCreator().create(
                in: patient, identity: fixedIdentity, startedAt: fixedDate)
            var editable = "Evoluc\u{327}a\u{303}o sintética"
            for suffix in ["", " sem quebra", "\n", "\n", "Conduta sintética"] {
                editable += suffix
                let saved = try ClinicalDraftSaver().save(
                    encounter: encounter, patientID: expectedPatientID,
                    body: editable, updatedAt: fixedDate.addingTimeInterval(60))
                #expect(ClinicalDraftSaver.matchesPersistedBody(editable, saved.body))
                #expect(!ClinicalDraftSaver.matchesPersistedBody(editable + "x", saved.body))
                encounter = try #require(VaultReader().open(vault.url).patients[0].encounters.first)
            }
        }
        #expect(ClinicalDraftSaver.matchesPersistedBody("Legado\n\n", "Legado\n\n"))
        #expect(!ClinicalDraftSaver.matchesPersistedBody("A\nB", "AB\n"))
        #expect(!ClinicalDraftSaver.matchesPersistedBody("AB ", "AB\n"))
    }

    @Test("restores the previous complete draft and leaves it unfinalized after a simulated save failure")
    func restoresDraftAfterSaveFailure() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            let encounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let previous = try Data(contentsOf: encounter.draft.url)
            let saver = ClinicalDraftSaver(faultInjector: { step in
                if step == .published { throw DraftSyntheticFailure() }
            })
            do {
                _ = try saver.save(
                    encounter: encounter,
                    patientID: expectedPatientID,
                    body: "Texto sintético ainda não confirmado",
                    updatedAt: fixedDate.addingTimeInterval(60)
                )
                Issue.record("a falha injetada deveria interromper o salvamento")
            } catch is DraftSyntheticFailure {
                #expect(try Data(contentsOf: encounter.draft.url) == previous)
                let reopened = try VaultReader().open(vault.url)
                #expect(reopened.writingAllowed)
                #expect(reopened.patients[0].encounters[0].draft.body == encounter.draft.body)
                #expect(reopened.patients[0].encounters[0].finalizationStatus == .draft)
                let finalURL = patient.url.appending(
                    path: "content/notes/final/\(expectedNoteID).md"
                )
                #expect(!FileManager.default.fileExists(atPath: finalURL.path))
            }
        }
    }

    @Test("starting another consultation preserves the saved draft and its bytes")
    func preservesPreviousDraftWhenStartingAnother() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createRegisteredPatient(in: vault)
            let first = try ClinicalDraftCreator().create(
                in: patient, identity: fixedIdentity, startedAt: fixedDate
            )
            let saved = try ClinicalDraftSaver().save(
                encounter: first, patientID: patient.patientID,
                body: "Última edição sintética antes de trocar de consulta.\n",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            let reopened = try VaultReader().open(vault.url)
            let next = try EncounterStartService().start(
                in: reopened, patient: reopened.patients[0], appointment: nil,
                identity: try ClinicalDraftCreationIdentity.generate(at: fixedDate.addingTimeInterval(120)),
                input: EncounterStartInput(modality: .inPerson, template: .blank, telemedicine: nil),
                startedAt: fixedDate.addingTimeInterval(120)
            )
            let after = try VaultReader().open(vault.url)
            let encounters = after.patients[0].encounters
            #expect(encounters.count == 2)
            let previous = try #require(encounters.first { $0.metadata.encounterID == first.metadata.encounterID })
            #expect(previous.draft.body == saved.body)
            #expect(previous.draft.persistedData == saved.persistedData)
            #expect(try Data(contentsOf: saved.url) == saved.persistedData)
            #expect(previous.finalizationStatus == .draft)
            let current = try #require(encounters.first { $0.metadata.encounterID == next.encounter.metadata.encounterID })
            #expect(current.metadata.encounterID != previous.metadata.encounterID)
            #expect(current.metadata.appointmentID == nil)
            #expect(current.metadata.modality == "in_person")
            #expect(current.draft.body.isEmpty)
            #expect(current.finalizationStatus == .draft)
        }
    }

    @Test("saves, reopens and finalizes the latest consultation text without a diagnosis")
    func savesAndFinalizesLatestTextWithoutDiagnosis() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: vault)
            let changes = ClinicalChangeRecorder(patientURL: initialPatient.url)
            let otherVault = ClinicalChangeRecorder(patientURL: parent.appending(path: "other/" + initialPatient.patientID))
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )

            var opened = try VaultReader().open(vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: opened.patients[0].encounters[0],
                patientID: expectedPatientID,
                body: "Primeira edição sintética sem CID.\n",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            opened = try VaultReader().open(vault.url)
            #expect(opened.patients[0].encounters[0].draft.body == "Primeira edição sintética sem CID.\n")
            #expect(try ConsultationFields.read(from: opened.patients[0].encounters[0].draft.body).items.isEmpty)

            _ = try ClinicalDraftSaver().save(
                encounter: opened.patients[0].encounters[0],
                patientID: expectedPatientID,
                body: "Última edição sintética salva antes de finalizar.\n",
                updatedAt: fixedDate.addingTimeInterval(120)
            )
            opened = try VaultReader().open(vault.url)
            let savedPatient = opened.patients[0]
            let savedEncounter = savedPatient.encounters[0]
            #expect(changes.count == 0)
            let finalized = try ClinicalFinalizer().finalize(
                patient: savedPatient,
                encounter: savedEncounter,
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5d4-0000-7000-8000-000000000003"
                ),
                finalizedAt: fixedDate.addingTimeInterval(180)
            )
            #expect(changes.count == 1)
            #expect(otherVault.count == 0)
            #expect(finalized.finalNote.body == "Última edição sintética salva antes de finalizar.\n")

            let afterFinalization = try VaultReader().open(vault.url)
            guard case let .verified(reopenedFinal) = afterFinalization.patients[0].encounters[0].finalizationStatus else {
                Issue.record("a consulta sem CID deveria reabrir finalizada")
                return
            }
            #expect(reopenedFinal.finalNote.body == "Última edição sintética salva antes de finalizar.\n")
        }
    }

    @Test("rejects stale saves and noncanonical updated_at without overwriting")
    func rejectsStaleAndUnsupportedWriterRepresentation() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            let originalEncounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let firstSave = try ClinicalDraftSaver().save(
                encounter: originalEncounter,
                patientID: expectedPatientID,
                body: "Primeira edição sintética",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            let firstBytes = try Data(contentsOf: firstSave.url)
            do {
                _ = try ClinicalDraftSaver().save(
                    encounter: originalEncounter,
                    patientID: expectedPatientID,
                    body: "Edição sintética obsoleta",
                    updatedAt: fixedDate.addingTimeInterval(120)
                )
                Issue.record("o snapshot obsoleto deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.revision_conflict")
                #expect(try Data(contentsOf: firstSave.url) == firstBytes)
            }

            var alternative = try #require(String(data: firstBytes, encoding: .utf8))
            alternative = alternative.replacingOccurrences(
                of: "updated_at: \"2026-08-30T17:21:00Z\"",
                with: "\"updated_at\": \"2026-08-30T17:21:00Z\""
            )
            try Data(alternative.utf8).write(to: firstSave.url, options: [.atomic])
            let alternativeEncounter = try #require(
                VaultReader().open(vault.url).patients[0].encounters.first
            )
            let alternativeBytes = try Data(contentsOf: firstSave.url)
            do {
                _ = try ClinicalDraftSaver().save(
                    encounter: alternativeEncounter,
                    patientID: expectedPatientID,
                    body: "Representação alternativa sintética",
                    updatedAt: fixedDate.addingTimeInterval(180)
                )
                Issue.record("a representação não suportada pelo writer deveria ser recusada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.writer_representation")
                #expect(try Data(contentsOf: firstSave.url) == alternativeBytes)
            }
        }
    }

    @Test("rejects symlinked patient, content and draft paths")
    func rejectsSymlinkedClinicalPaths() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let outsidePatients = parent.appending(path: "outside-patients")
            try FileManager.default.createDirectory(at: outsidePatients, withIntermediateDirectories: false)
            let patientsURL = vault.url.appending(path: "patients")
            try FileManager.default.removeItem(at: patientsURL)
            try FileManager.default.createSymbolicLink(at: patientsURL, withDestinationURL: outsidePatients)
            let reopenedVault = try VaultReader().open(vault.url)
            #expect(!reopenedVault.writingAllowed)
            do {
                _ = try PatientCreator().create(
                    in: vault.url,
                    identity: PatientCreationIdentity(patientID: expectedPatientID)
                )
                Issue.record("patients por symlink deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "filesystem.directory")
                #expect(try FileManager.default.contentsOfDirectory(atPath: outsidePatients.path).isEmpty)
            }

            try FileManager.default.removeItem(at: patientsURL)
            try FileManager.default.createDirectory(at: patientsURL, withIntermediateDirectories: false)
            let patient = try createPatient(in: vault)
            let outsideContent = parent.appending(path: "outside-content")
            try FileManager.default.createDirectory(at: outsideContent, withIntermediateDirectories: false)
            let contentURL = patient.url.appending(path: "content")
            try FileManager.default.removeItem(at: contentURL)
            try FileManager.default.createSymbolicLink(at: contentURL, withDestinationURL: outsideContent)
            do {
                _ = try ClinicalDraftCreator().create(
                    in: patient,
                    identity: fixedIdentity,
                    startedAt: fixedDate
                )
                Issue.record("content por symlink deveria ser recusado")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "filesystem.directory")
                #expect(try FileManager.default.contentsOfDirectory(atPath: outsideContent.path).isEmpty)
            }
        }


        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            let encounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let draftsURL = patient.url.appending(path: "content/notes/drafts")
            let outsideDrafts = parent.appending(path: "outside-drafts")
            try FileManager.default.moveItem(at: draftsURL, to: outsideDrafts)
            try FileManager.default.createSymbolicLink(
                at: draftsURL,
                withDestinationURL: outsideDrafts
            )
            let externalBytes = try Data(contentsOf: encounter.draft.url)
            do {
                _ = try ClinicalDraftSaver().save(
                    encounter: encounter,
                    patientID: expectedPatientID,
                    body: "Texto sintético fora do vault",
                    updatedAt: fixedDate.addingTimeInterval(60)
                )
                Issue.record("drafts por symlink deveria ser recusado no salvamento")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "filesystem.directory")
                #expect(try Data(contentsOf: encounter.draft.url) == externalBytes)
            }
        }
    }

    @Test("isolates the patient when the draft binding is altered")
    func isolatesMismatchedDraftBinding() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try createPatient(in: vault)
            let encounter = try ClinicalDraftCreator().create(
                in: patient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            var text = try #require(String(data: Data(contentsOf: encounter.draft.url), encoding: .utf8))
            text = text.replacingOccurrences(
                of: expectedPatientID,
                with: "pt_0198f5c2-0000-7000-8000-000000000002"
            )
            try Data(text.utf8).write(to: encounter.draft.url, options: [.atomic])

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.isEmpty)
            #expect(reopened.unavailablePatients.map(\.patientID) == [patient.patientID])
            #expect(reopened.statusMessage.contains("1 indisponível"))
        }
    }

    @Test("finalizes and adds without changing the draft or final bytes")
    func finalizesAndAddsImmutably() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: vault)
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let beforeFinalization = try VaultReader().open(vault.url)
            let patient = try #require(beforeFinalization.patients.first)
            let encounter = try #require(patient.encounters.first)
            let draftBytes = try Data(contentsOf: encounter.draft.url)

            let finalized = try ClinicalFinalizer().finalize(
                patient: patient,
                encounter: encounter,
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5d4-0000-7000-8000-000000000001"
                ),
                finalizedAt: fixedDate.addingTimeInterval(300)
            )
            #expect(finalized.addenda.isEmpty)
            #expect(finalized.finalNote.body == encounter.draft.body)
            #expect(try Data(contentsOf: encounter.draft.url) == draftBytes)
            let finalBytes = try Data(contentsOf: finalized.finalNote.url)

            let afterFinalization = try VaultReader().open(vault.url)
            let finalizedEncounter = try #require(afterFinalization.patients[0].encounters.first)
            guard case let .verified(reopenedFinal) = finalizedEncounter.finalizationStatus else {
                Issue.record("a nota final deveria reabrir íntegra")
                return
            }
            let changes = ClinicalChangeRecorder(patientURL: afterFinalization.patients[0].url)
            let withAddendum = try ClinicalAddendumWriter().add(
                patient: afterFinalization.patients[0],
                encounter: finalizedEncounter,
                identity: AddendumIdentity(
                    addendumID: "add_0198f5d5-0000-7000-8000-000000000001",
                    eventID: "evt_0198f5d6-0000-7000-8000-000000000001"
                ),
                reason: "Correção de informação sintética",
                body: "Texto sintético complementar.",
                createdAt: fixedDate.addingTimeInterval(600)
            )
            #expect(changes.count == 1)
            #expect(withAddendum.addenda.count == 1)
            #expect(withAddendum.addenda[0].metadata.finalSHA256 == reopenedFinal.finalNote.sha256)
            #expect(try Data(contentsOf: encounter.draft.url) == draftBytes)
            #expect(try Data(contentsOf: finalized.finalNote.url) == finalBytes)

            let auditURL = patient.url.appending(path: ".openpep/audit.ndjson")
            let auditText = try #require(String(data: Data(contentsOf: auditURL), encoding: .utf8))
            #expect(auditText.split(separator: "\n").count == 2)
            #expect(!auditText.contains("Texto sintético complementar"))
            #expect(!auditText.contains(encounter.draft.body))

            try Data("Adendo adulterado.\n".utf8).write(
                to: withAddendum.addenda[0].url,
                options: [.atomic]
            )
            let afterAddendumTamper = try VaultReader().open(vault.url)
            let alteredEncounter = try #require(afterAddendumTamper.patients[0].encounters.first)
            guard case let .altered(message) = alteredEncounter.finalizationStatus else {
                Issue.record("o hash divergente do adendo deveria ser detectado")
                return
            }
            #expect(message.contains("adendo"))
            #expect(try Data(contentsOf: finalized.finalNote.url) == finalBytes)
        }
    }

    @Test("finalization refuses an active or incomplete progressive transcript")
    func progressiveWorkBlocksFinalizationUntilReviewed() throws {
        try withTemporaryDirectory { parent in
            let initialVault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: initialVault)
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            var vault = try VaultReader().open(initialVault.url)
            var patient = try #require(vault.patients.first)
            var encounter = try #require(patient.encounters.first)
            let binding = EncounterTranscriptionBinding(
                vaultURL: vault.url,
                vaultID: vault.manifest.vaultID,
                patientID: patient.patientID,
                encounterID: encounter.metadata.encounterID,
                patientName: patient.displayName
            )
            var work = ProgressiveConsultationWork(
                binding: binding,
                source: .microphone,
                summaryIntervalSeconds: 180,
                transcriptionEngine: "openai/realtime",
                transcriptionModel: "gpt-live-transcribe",
                summaryEngine: "openai/responses",
                summaryModel: "gpt-4o",
                now: fixedDate
            )
            work.status = .recording
            work.capture.status = .recording
            let store = ProgressiveConsultationWorkStore()
            let first = try store.save(work, binding: binding)

            do {
                _ = try ClinicalFinalizer().finalize(
                    patient: patient,
                    encounter: encounter,
                    identity: FinalizationIdentity(
                        eventID: "evt_0198f5d4-0000-7000-8000-000000000041"
                    ),
                    finalizedAt: fixedDate.addingTimeInterval(300)
                )
                Issue.record("uma captura ativa deveria bloquear a finalização")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "finalization.progressive_pending")
            }

            work.status = .incomplete
            work.capture.status = .incomplete
            work.pendingRanges = [ConsultationTimeRange(
                startSeconds: 0,
                endSeconds: 30,
                isApproximate: true
            )]
            work.updatedAt = fixedDate.addingTimeInterval(60)
            _ = try store.save(work, binding: binding, expectedData: first)
            vault = try VaultReader().open(initialVault.url)
            patient = try #require(vault.patients.first)
            encounter = try #require(patient.encounters.first)
            do {
                _ = try ClinicalFinalizer().finalize(
                    patient: patient,
                    encounter: encounter,
                    identity: FinalizationIdentity(
                        eventID: "evt_0198f5d4-0000-7000-8000-000000000042"
                    ),
                    finalizedAt: fixedDate.addingTimeInterval(360)
                )
                Issue.record("uma lacuna de transcrição deveria bloquear a finalização")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "finalization.progressive_pending")
            }
        }
    }

    @Test("detects external final and related document changes without hiding the patient")
    func detectsFinalAndAssetTampering() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: vault)
            _ = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(
                    patientID: "pt_0198f5c2-0000-7000-8000-000000000002"
                ),
                input: PatientRecordInput(
                    fullName: "Paciente Sintético Preservado",
                    preferredName: nil,
                    birthDate: nil,
                    contacts: [],
                    identifiers: [],
                    alerts: []
                ),
                createdAt: fixedDate
            )
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            var opened = try VaultReader().open(vault.url)
            let source = parent.appending(path: "documento-sintetico.txt")
            try Data("Documento sintético relacionado.\n".utf8).write(to: source)
            _ = try GeneralDocumentImporter().importDocument(
                from: source,
                into: opened.patients[0],
                encounterID: expectedEncounterID,
                deviceID: opened.manifest.deviceID,
                identity: RawAssetCreationIdentity(
                    assetID: "asset_0198f5d7-0000-7000-8000-000000000001"
                ),
                importedAt: fixedDate.addingTimeInterval(60)
            )
            opened = try VaultReader().open(vault.url)
            let finalized = try ClinicalFinalizer().finalize(
                patient: opened.patients[0],
                encounter: opened.patients[0].encounters[0],
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5d4-0000-7000-8000-000000000001"
                ),
                finalizedAt: fixedDate.addingTimeInterval(300)
            )

            let assetURL = opened.patients[0].rawAssets[0].originalURL
            try Data("Documento adulterado.\n".utf8).write(to: assetURL, options: [.atomic])
            let afterAssetTamper = try VaultReader().open(vault.url)
            #expect(afterAssetTamper.patients.count == 1)
            #expect(afterAssetTamper.patients[0].patientID == "pt_0198f5c2-0000-7000-8000-000000000002")
            #expect(afterAssetTamper.unavailablePatients.map(\.patientID) == [expectedPatientID])

            try Data("Documento sintético relacionado.\n".utf8).write(to: assetURL, options: [.atomic])
            try Data("Nota final adulterada.\n".utf8).write(to: finalized.finalNote.url, options: [.atomic])
            let afterFinalTamper = try VaultReader().open(vault.url)
            #expect(afterFinalTamper.patients.count == 2)
            let affected = try #require(afterFinalTamper.patients.first { $0.patientID == expectedPatientID })
            guard case let .altered(finalMessage) = affected.encounters[0].finalizationStatus else {
                Issue.record("o hash divergente da nota final deveria ser detectado")
                return
            }
            #expect(finalMessage.contains("nota final"))
        }
    }

    @Test("rolls back before audit append and preserves a committed event after append")
    func finalizationFaultBoundaries() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let initialPatient = try createRegisteredPatient(in: vault)
            _ = try ClinicalDraftCreator().create(
                in: initialPatient,
                identity: fixedIdentity,
                startedAt: fixedDate
            )
            let opened = try VaultReader().open(vault.url)
            let patient = opened.patients[0]
            let encounter = patient.encounters[0]
            let interrupted = ClinicalFinalizer(faultInjector: { step in
                if step == .artifactPublished { throw DraftSyntheticFailure() }
            })
            #expect(throws: DraftSyntheticFailure.self) {
                _ = try interrupted.finalize(
                    patient: patient,
                    encounter: encounter,
                    identity: FinalizationIdentity(
                        eventID: "evt_0198f5d4-0000-7000-8000-000000000001"
                    ),
                    finalizedAt: fixedDate.addingTimeInterval(300)
                )
            }
            let afterRollback = try VaultReader().open(vault.url)
            #expect(afterRollback.patients[0].encounters[0].finalizationStatus == .draft)

            let orphanURL = patient.url.appending(
                path: "content/notes/final/\(expectedNoteID).md"
            )
            try Data("Artefato órfão sintético.\n".utf8).write(
                to: orphanURL,
                options: [.withoutOverwriting]
            )
            let withOrphan = try VaultReader().open(vault.url)
            #expect(withOrphan.patients.isEmpty)
            #expect(withOrphan.unavailablePatients.map(\.patientID) == [expectedPatientID])
            try FileManager.default.removeItem(at: orphanURL)

            let committed = ClinicalFinalizer(faultInjector: { step in
                if step == .auditAppended { throw DraftSyntheticFailure() }
            })
            #expect(throws: DraftSyntheticFailure.self) {
                _ = try committed.finalize(
                    patient: afterRollback.patients[0],
                    encounter: afterRollback.patients[0].encounters[0],
                    identity: FinalizationIdentity(
                        eventID: "evt_0198f5d4-0000-7000-8000-000000000002"
                    ),
                    finalizedAt: fixedDate.addingTimeInterval(360)
                )
            }
            let afterCommittedFailure = try VaultReader().open(vault.url)
            guard case .verified = afterCommittedFailure.patients[0].encounters[0].finalizationStatus else {
                Issue.record("artefato e evento já anexado deveriam permanecer consistentes")
                return
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var validFixtureRoot: URL {
        repositoryRoot.appending(path: "fixtures/clinical-draft-v1/valid/synthetic-encounter")
    }

    private var expectedPatientID: String {
        "pt_0198f5c2-0000-7000-8000-000000000001"
    }

    private var expectedEncounterID: String {
        "enc_0198f5d1-0000-7000-8000-000000000001"
    }

    private var expectedNoteID: String {
        "note_0198f5d3-0000-7000-8000-000000000001"
    }

    private var expectedAuthorID: String {
        "usr_0198f4a0-0000-7000-8000-000000000001"
    }

    private var fixedIdentity: ClinicalDraftCreationIdentity {
        ClinicalDraftCreationIdentity(
            encounterID: expectedEncounterID,
            noteID: expectedNoteID,
            syntheticActorID: expectedAuthorID
        )
    }

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_788_110_400) }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-mac003-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func createVault(in parent: URL) throws -> VaultSummary {
        try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func createPatient(in vault: VaultSummary) throws -> PatientSummary {
        try PatientCreator().create(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: expectedPatientID)
        )
    }

    private func createRegisteredPatient(in vault: VaultSummary) throws -> PatientSummary {
        try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: expectedPatientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético do Encontro",
                preferredName: "Encontro",
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: fixedDate
        )
    }
}

private struct DraftSyntheticFailure: Error {}
