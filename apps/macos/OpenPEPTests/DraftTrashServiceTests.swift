// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("ENCOUNTER-UX-006 synthetic draft trash")
struct DraftTrashServiceTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000091"
    private let encounterID = "enc_0198f5c3-0000-7000-8000-000000000091"
    private let noteID = "note_0198f5c4-0000-7000-8000-000000000091"
    private let actorID = "usr_0198f5c5-0000-7000-8000-000000000091"
    private let appointmentID = "appt_0198f5c6-0000-7000-8000-000000000091"
    private let fixedDate = Date(timeIntervalSince1970: 1_788_110_400)

    @Test("content, diagnosis and bound document round-trip through trash")
    func contentRoundTrip() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)

            var diagnosis = ConsultationFieldItem(kind: .diagnosis)
            diagnosis[.title] = "Exame clínico sintético"
            diagnosis[.code] = "Z00.0"
            let body = try ConsultationFields(items: [diagnosis]).replacing(in: "Evolução sintética.")
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: body,
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            context = try reopenContext(context.vault.url)
            let source = parent.appending(path: "documento-sintetico.txt")
            let sourceData = Data("Documento sintético vinculado ao atendimento.\n".utf8)
            try sourceData.write(to: source)
            _ = try GeneralDocumentImporter().importDocument(
                from: source,
                into: context.patient,
                encounterID: encounterID,
                deviceID: context.vault.manifest.deviceID,
                identity: RawAssetCreationIdentity(
                    assetID: "asset_0198f5c7-0000-7000-8000-000000000091"
                ),
                importedAt: fixedDate.addingTimeInterval(90)
            )
            context = try reopenContext(context.vault.url)
            let active = try #require(context.patient.encounters.first)
            let originalEncounterData = try Data(contentsOf: active.url)
            let originalDraftData = try Data(contentsOf: active.draft.url)
            let originalAssetData = try Data(contentsOf: context.patient.rawAssets[0].originalURL)

            let moved = try DraftTrashService().discard(
                in: context.vault,
                patient: context.patient,
                encounter: active,
                expectedData: originalEncounterData,
                at: fixedDate.addingTimeInterval(120)
            )
            #expect(moved)
            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.isEmpty)
            #expect(context.patient.rawAssets.isEmpty)
            let trashed = try #require(context.patient.trashedEncounters.first)
            #expect(trashed.metadata.trashedAt == "2026-08-30T17:22:00Z")
            #expect(context.patient.trashedRawAssets.count == 1)
            #expect(try Data(contentsOf: trashed.draft.url) == originalDraftData)
            #expect(try Data(contentsOf: context.patient.trashedRawAssets[0].originalURL) == originalAssetData)
            do {
                _ = try ClinicalDraftSaver().save(
                    encounter: trashed,
                    patientID: patientID,
                    body: "Edição indevida.",
                    updatedAt: fixedDate.addingTimeInterval(180)
                )
                Issue.record("um rascunho descartado não deveria aceitar edição")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "clinical_document.trashed")
            }
            do {
                _ = try ClinicalFinalizer().finalize(
                    patient: context.patient,
                    encounter: trashed,
                    identity: FinalizationIdentity(
                        eventID: "evt_0198f5c8-0000-7000-8000-000000000092"
                    ),
                    finalizedAt: fixedDate.addingTimeInterval(180)
                )
                Issue.record("um rascunho descartado não deveria aceitar finalização")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "finalization.trashed")
            }

            let trashedData = try Data(contentsOf: trashed.url)
            try DraftTrashService().restore(
                in: context.vault,
                patient: context.patient,
                encounter: trashed,
                expectedData: trashedData
            )
            context = try reopenContext(context.vault.url)
            let restored = try #require(context.patient.encounters.first)
            #expect(context.patient.trashedEncounters.isEmpty)
            #expect(context.patient.trashedRawAssets.isEmpty)
            #expect(context.patient.rawAssets.count == 1)
            #expect(try Data(contentsOf: restored.url) == originalEncounterData)
            #expect(try Data(contentsOf: restored.draft.url) == originalDraftData)
            #expect(try Data(contentsOf: context.patient.rawAssets[0].originalURL) == originalAssetData)
            #expect(try ConsultationFields.read(from: restored.draft.body).items.first?[.code] == "Z00.0")
        }
    }

    @Test("a truly empty pair is removed permanently")
    func emptyDraftIsRemoved() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            var diagnosis = ConsultationFieldItem(kind: .diagnosis)
            diagnosis[.title] = "Achado sintético removível"
            diagnosis[.code] = "Z00.0"
            let structured = try ConsultationFields(items: [diagnosis]).replacing(in: "")
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: structured,
                updatedAt: fixedDate.addingTimeInterval(30)
            )
            context = try reopenContext(context.vault.url)
            let cleared = try LinearConsultationPage(
                body: context.patient.encounters[0].draft.body
            ).replacing(.diagnosis, text: "")
            #expect(cleared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: cleared,
                updatedAt: fixedDate.addingTimeInterval(45)
            )
            context = try reopenContext(context.vault.url)
            let encounter = try #require(context.patient.encounters.first)
            let encounterURL = encounter.url
            let draftURL = encounter.draft.url

            let moved = try DraftTrashService().discard(
                in: context.vault,
                patient: context.patient,
                encounter: encounter,
                expectedData: Data(contentsOf: encounter.url),
                at: fixedDate.addingTimeInterval(60)
            )
            #expect(!moved)
            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.isEmpty)
            #expect(context.patient.trashedEncounters.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: encounterURL.path))
            #expect(!FileManager.default.fileExists(atPath: draftURL.path))
        }
    }

    @Test("progressive consultation work keeps an otherwise empty draft recoverable")
    func progressiveWorkRoundTripsThroughTrash() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            let encounter = try #require(context.patient.encounters.first)
            let binding = EncounterTranscriptionBinding(
                vaultURL: context.vault.url,
                vaultID: context.vault.manifest.vaultID,
                patientID: patientID,
                encounterID: encounterID,
                patientName: context.patient.displayName
            )
            let work = ProgressiveConsultationWork(
                binding: binding,
                source: .imported,
                summaryIntervalSeconds: 180,
                transcriptionEngine: "apple/SpeechTranscriber",
                transcriptionModel: "pt-BR",
                summaryEngine: "apple/FoundationModels.SystemLanguageModel",
                summaryModel: nil,
                now: fixedDate
            )
            _ = try ProgressiveConsultationWorkStore().save(work, binding: binding)

            let moved = try DraftTrashService().discard(
                in: context.vault,
                patient: context.patient,
                encounter: encounter,
                expectedData: Data(contentsOf: encounter.url),
                at: fixedDate.addingTimeInterval(60)
            )
            #expect(moved)
            context = try reopenContext(context.vault.url)
            let trashed = try #require(context.patient.trashedEncounters.first)
            #expect(try ProgressiveConsultationWorkStore().load(binding: binding) == work)

            try DraftTrashService().restore(
                in: context.vault,
                patient: context.patient,
                encounter: trashed,
                expectedData: Data(contentsOf: trashed.url)
            )
            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.first?.metadata.encounterID == encounterID)
            #expect(try ProgressiveConsultationWorkStore().load(binding: binding) == work)
        }
    }

    @Test("stale snapshots and finalized notes are refused")
    func staleAndFinalRefusals() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            var encounter = try #require(context.patient.encounters.first)
            let staleEncounterData = try Data(contentsOf: encounter.url)
            var external = try String(contentsOf: encounter.url, encoding: .utf8)
            external = external.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: "x_external_fact: kept\nx_actor_assurance: synthetic_unauthenticated\n"
            )
            try Data(external.utf8).write(to: encounter.url, options: [.atomic])
            do {
                _ = try DraftTrashService().discard(
                    in: context.vault,
                    patient: context.patient,
                    encounter: encounter,
                    expectedData: staleEncounterData,
                    at: fixedDate.addingTimeInterval(60)
                )
                Issue.record("o snapshot obsoleto deveria falhar")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "draft_trash.revision_conflict")
            }

            context = try reopenContext(context.vault.url)
            encounter = try #require(context.patient.encounters.first)
            _ = try ClinicalFinalizer().finalize(
                patient: context.patient,
                encounter: encounter,
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5c8-0000-7000-8000-000000000091"
                ),
                finalizedAt: fixedDate.addingTimeInterval(120)
            )
            context = try reopenContext(context.vault.url)
            encounter = try #require(context.patient.encounters.first)
            do {
                _ = try DraftTrashService().discard(
                    in: context.vault,
                    patient: context.patient,
                    encounter: encounter,
                    expectedData: Data(contentsOf: encounter.url),
                    at: fixedDate.addingTimeInterval(180)
                )
                Issue.record("a nota final deveria ser preservada")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "draft_trash.finalized")
            }
            #expect(FileManager.default.fileExists(atPath: encounter.url.path))
        }
    }

    @Test("a finalized marked encounter stays active and accepts an addendum")
    func finalizedMarkerStaysActive() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: "Nota sintética finalizada por um leitor anterior.\n",
                updatedAt: fixedDate.addingTimeInterval(30)
            )
            context = try reopenContext(context.vault.url)
            let source = parent.appending(path: "fonte-final-sintetica.txt")
            try Data("Fonte sintética da nota final.\n".utf8).write(to: source)
            _ = try GeneralDocumentImporter().importDocument(
                from: source,
                into: context.patient,
                encounterID: encounterID,
                deviceID: context.vault.manifest.deviceID,
                identity: RawAssetCreationIdentity(
                    assetID: "asset_0198f5c7-0000-7000-8000-000000000092"
                ),
                importedAt: fixedDate.addingTimeInterval(45)
            )
            context = try reopenContext(context.vault.url)
            _ = try ClinicalFinalizer().finalize(
                patient: context.patient,
                encounter: context.patient.encounters[0],
                identity: FinalizationIdentity(
                    eventID: "evt_0198f5c8-0000-7000-8000-000000000093"
                ),
                finalizedAt: fixedDate.addingTimeInterval(60)
            )
            context = try reopenContext(context.vault.url)
            let finalized = context.patient.encounters[0]
            var markedText = try String(contentsOf: finalized.url, encoding: .utf8)
            markedText = markedText.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: "x_openpep_trashed_at: \"2026-08-30T17:22:00Z\"\nx_actor_assurance: synthetic_unauthenticated\n"
            )
            try Data(markedText.utf8).write(to: finalized.url, options: [.atomic])

            context = try reopenContext(context.vault.url)
            let visible = try #require(context.patient.encounters.first)
            #expect(visible.metadata.trashedAt != nil)
            #expect(context.patient.trashedEncounters.isEmpty)
            #expect(context.patient.rawAssets.count == 1)
            #expect(context.patient.trashedRawAssets.isEmpty)
            guard case .verified = visible.finalizationStatus else {
                Issue.record("a nota final marcada deveria continuar íntegra e ativa")
                return
            }
            let updated = try ClinicalAddendumWriter().add(
                patient: context.patient,
                encounter: visible,
                identity: AddendumIdentity(
                    addendumID: "add_0198f5cb-0000-7000-8000-000000000091",
                    eventID: "evt_0198f5cc-0000-7000-8000-000000000091"
                ),
                reason: "Correção sintética",
                body: "Adendo sintético preservado.",
                createdAt: fixedDate.addingTimeInterval(120)
            )
            #expect(updated.addenda.count == 1)
        }
    }

    @Test("a late encounter edit is detected before publication")
    func lateEditBeforePublication() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: "Conteúdo sintético inicial.\n",
                updatedAt: fixedDate.addingTimeInterval(30)
            )
            context = try reopenContext(context.vault.url)
            let encounter = context.patient.encounters[0]
            let observedData = try Data(contentsOf: encounter.url)
            let service = DraftTrashService(faultInjector: { step in
                guard step == .candidatePrepared else { return }
                var late = try String(contentsOf: encounter.url, encoding: .utf8)
                late = late.replacingOccurrences(
                    of: "x_actor_assurance: synthetic_unauthenticated\n",
                    with: "x_late_external_edit: preserved\nx_actor_assurance: synthetic_unauthenticated\n"
                )
                try Data(late.utf8).write(to: encounter.url, options: [.atomic])
            })
            do {
                _ = try service.discard(
                    in: context.vault,
                    patient: context.patient,
                    encounter: encounter,
                    expectedData: observedData,
                    at: fixedDate.addingTimeInterval(60)
                )
                Issue.record("a edição tardia deveria impedir a publicação")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "draft_trash.revision_conflict")
            }
            let persisted = try String(contentsOf: encounter.url, encoding: .utf8)
            #expect(persisted.contains("x_late_external_edit: preserved"))
            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.count == 1)
            #expect(context.patient.trashedEncounters.isEmpty)
        }
    }

    @Test("leftover recovery copies do not block vault reading")
    func recoveryLeftoverIsTolerated() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let recovery = context.vault.url.appending(path: "recovery", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
            let leftover = recovery.appending(path: "encounter-interrupted.md")
            try Data("cópia sintética de recuperação\n".utf8).write(to: leftover)
            let reopened = try VaultReader().open(context.vault.url)
            #expect(reopened.writingAllowed)
            #expect(reopened.patients.count == 1)
        }
    }

    @Test("scheduled content unlinks on discard and rebinds on restore")
    func appointmentRoundTrip() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            let appointment = try createAppointment(in: context)
            context = try reopenContext(context.vault.url)
            let currentAppointment = try #require(context.vault.appointments.first)
            _ = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: currentAppointment,
                identity: identity,
                input: .scheduled(currentAppointment.record),
                startedAt: fixedDate
            )
            context = try reopenContext(context.vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: "Conteúdo sintético agendado.\n",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            context = try reopenContext(context.vault.url)
            let active = context.patient.encounters[0]
            _ = try DraftTrashService().discard(
                in: context.vault,
                patient: context.patient,
                encounter: active,
                expectedData: Data(contentsOf: active.url),
                at: fixedDate.addingTimeInterval(120)
            )
            context = try reopenContext(context.vault.url)
            #expect(context.vault.appointments.first?.id == appointment.id)
            #expect(context.vault.appointments.first?.record.encounterID == nil)
            let trashed = context.patient.trashedEncounters[0]

            try DraftTrashService().restore(
                in: context.vault,
                patient: context.patient,
                encounter: trashed,
                expectedData: Data(contentsOf: trashed.url)
            )
            context = try reopenContext(context.vault.url)
            #expect(context.vault.appointments.first?.record.encounterID == encounterID)
            #expect(context.patient.encounters.first?.metadata.encounterID == encounterID)
        }
    }

    @Test("restore refuses an appointment now linked to another encounter")
    func restoreAppointmentConflict() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try createAppointment(in: context)
            context = try reopenContext(context.vault.url)
            let appointment = try #require(context.vault.appointments.first)
            _ = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: appointment,
                identity: identity,
                input: .scheduled(appointment.record),
                startedAt: fixedDate
            )
            context = try reopenContext(context.vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: "Primeira consulta sintética.\n",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            context = try reopenContext(context.vault.url)
            let first = context.patient.encounters[0]
            _ = try DraftTrashService().discard(
                in: context.vault,
                patient: context.patient,
                encounter: first,
                expectedData: Data(contentsOf: first.url),
                at: fixedDate.addingTimeInterval(120)
            )

            context = try reopenContext(context.vault.url)
            let availableAppointment = try #require(context.vault.appointments.first)
            let secondIdentity = ClinicalDraftCreationIdentity(
                encounterID: "enc_0198f5c9-0000-7000-8000-000000000091",
                noteID: "note_0198f5ca-0000-7000-8000-000000000091",
                syntheticActorID: actorID
            )
            _ = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: availableAppointment,
                identity: secondIdentity,
                input: .scheduled(availableAppointment.record),
                startedAt: fixedDate.addingTimeInterval(180)
            )
            context = try reopenContext(context.vault.url)
            let trashed = try #require(context.patient.trashedEncounters.first)
            do {
                try DraftTrashService().restore(
                    in: context.vault,
                    patient: context.patient,
                    encounter: trashed,
                    expectedData: Data(contentsOf: trashed.url)
                )
                Issue.record("o agendamento ocupado deveria impedir a restauração")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "draft_trash.appointment_conflict")
            }
            context = try reopenContext(context.vault.url)
            #expect(context.patient.trashedEncounters.first?.metadata.encounterID == encounterID)
            #expect(context.vault.appointments.first?.record.encounterID == secondIdentity.encounterID)
        }
    }

    @Test("failed scheduled discard restores content and leaves recoverable pending link")
    func failureRollbackAndPendingLinkRecovery() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try createAppointment(in: context)
            context = try reopenContext(context.vault.url)
            let appointment = try #require(context.vault.appointments.first)
            _ = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: appointment,
                identity: identity,
                input: .scheduled(appointment.record),
                startedAt: fixedDate
            )
            context = try reopenContext(context.vault.url)
            _ = try ClinicalDraftSaver().save(
                encounter: context.patient.encounters[0],
                patientID: patientID,
                body: "Conteúdo sintético preservado na falha.\n",
                updatedAt: fixedDate.addingTimeInterval(60)
            )
            context = try reopenContext(context.vault.url)
            let active = context.patient.encounters[0]
            let encounterData = try Data(contentsOf: active.url)
            let service = DraftTrashService(faultInjector: { step in
                if step == .candidatePublished { throw DraftTrashSyntheticFailure() }
            })
            do {
                _ = try service.discard(
                    in: context.vault,
                    patient: context.patient,
                    encounter: active,
                    expectedData: encounterData,
                    at: fixedDate.addingTimeInterval(120)
                )
                Issue.record("a falha injetada deveria interromper o descarte")
            } catch is DraftTrashSyntheticFailure {
                // Expected.
            }

            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.first?.draft.body == "Conteúdo sintético preservado na falha.\n")
            #expect(context.patient.trashedEncounters.isEmpty)
            let pendingAppointment = try #require(context.vault.appointments.first)
            #expect(pendingAppointment.record.encounterID == nil)
            let recovered = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: pendingAppointment,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: "enc_0198f5c9-0000-7000-8000-000000000091",
                    noteID: "note_0198f5ca-0000-7000-8000-000000000091",
                    syntheticActorID: actorID
                ),
                input: .scheduled(pendingAppointment.record),
                startedAt: fixedDate.addingTimeInterval(180)
            )
            #expect(recovered.recoveredPendingLink)
            #expect(recovered.encounter.metadata.encounterID == encounterID)
        }
    }

    @Test("late content after appointment unlink prevents empty deletion")
    func lateDraftAfterUnlinkIsPreserved() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try createAppointment(in: context)
            context = try reopenContext(context.vault.url)
            let appointment = try #require(context.vault.appointments.first)
            _ = try EncounterStartService().start(
                in: context.vault,
                patient: context.patient,
                appointment: appointment,
                identity: identity,
                input: .scheduled(appointment.record),
                startedAt: fixedDate
            )
            context = try reopenContext(context.vault.url)
            let encounter = context.patient.encounters[0]
            let observedEncounterData = try Data(contentsOf: encounter.url)
            let service = DraftTrashService(faultInjector: { step in
                guard step == .appointmentUnlinked else { return }
                let parsed = try VaultManifestValidator.parseMarkdownDocument(
                    data: encounter.draft.persistedData,
                    source: encounter.draft.url.path
                )
                let lateData = Data(
                    ("---\n" + parsed.frontmatter + "---\n\nConteúdo sintético tardio.\n").utf8
                )
                _ = try ClinicalDocumentValidator.validateDraft(
                    data: lateData,
                    source: encounter.draft.url.path
                )
                try lateData.write(to: encounter.draft.url, options: [.atomic])
            })
            do {
                _ = try service.discard(
                    in: context.vault,
                    patient: context.patient,
                    encounter: encounter,
                    expectedData: observedEncounterData,
                    at: fixedDate.addingTimeInterval(60)
                )
                Issue.record("o conteúdo tardio deveria impedir a remoção vazia")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "draft_trash.revision_conflict")
            }
            context = try reopenContext(context.vault.url)
            #expect(context.patient.encounters.first?.draft.body == "Conteúdo sintético tardio.\n")
            #expect(context.patient.trashedEncounters.isEmpty)
            #expect(context.vault.appointments.first?.record.encounterID == nil)
        }
    }

    @Test("trash timestamp and standalone remote link extensions are validated")
    func validatesEncounterExtensions() throws {
        try withTemporaryDirectory { parent in
            var context = try createContext(in: parent)
            _ = try startBlank(in: context.vault, patient: context.patient)
            context = try reopenContext(context.vault.url)
            let encounter = context.patient.encounters[0]
            let original = try String(contentsOf: encounter.url, encoding: .utf8)
            let invalidTrash = original.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: "x_openpep_trashed_at: ontem\nx_actor_assurance: synthetic_unauthenticated\n"
            )
            do {
                _ = try ClinicalDocumentValidator.validateEncounter(
                    data: Data(invalidTrash.utf8), source: encounter.url.path
                )
                Issue.record("a data inválida deveria falhar")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "schema.format")
                #expect(issue.path == "/x_openpep_trashed_at")
            }
            let validRemote = original.replacingOccurrences(
                of: "x_actor_assurance: synthetic_unauthenticated\n",
                with: "x_openpep_remote_access_url: \"https://example.invalid/sala\"\nx_actor_assurance: synthetic_unauthenticated\n"
            )
            let metadata = try ClinicalDocumentValidator.validateEncounter(
                data: Data(validRemote.utf8), source: encounter.url.path
            )
            #expect(metadata.remoteAccessURL == "https://example.invalid/sala")
        }
    }

    private var identity: ClinicalDraftCreationIdentity {
        ClinicalDraftCreationIdentity(encounterID: encounterID, noteID: noteID, syntheticActorID: actorID)
    }

    private func startBlank(in vault: VaultSummary, patient: PatientSummary) throws -> EncounterSummary {
        try EncounterStartService().start(
            in: vault,
            patient: patient,
            appointment: nil,
            identity: identity,
            input: EncounterStartInput(modality: .inPerson, template: .blank, telemedicine: nil),
            startedAt: fixedDate
        ).encounter
    }

    private func createAppointment(
        in context: (vault: VaultSummary, patient: PatientSummary)
    ) throws -> AppointmentSummary {
        try AppointmentWriter().create(
            in: context.vault.url,
            patient: context.patient,
            identity: AppointmentCreationIdentity(appointmentID: appointmentID),
            input: AppointmentInput(
                patientID: patientID,
                startsAt: fixedDate,
                endsAt: fixedDate.addingTimeInterval(1_800),
                timeZone: "America/Sao_Paulo",
                modality: .inPerson,
                status: .scheduled,
                location: "Consultório sintético",
                remoteAccessURL: nil,
                administrativeNote: nil
            ),
            createdAt: fixedDate.addingTimeInterval(-60)
        )
    }

    private func createContext(in parent: URL) throws -> (vault: VaultSummary, patient: PatientSummary) {
        let created = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a291",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a91"
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        _ = try PatientCreator().createRegistered(
            in: created.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético da Lixeira",
                preferredName: "Lixeira",
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: fixedDate.addingTimeInterval(-120)
        )
        return try reopenContext(created.url)
    }

    private func reopenContext(_ vaultURL: URL) throws -> (vault: VaultSummary, patient: PatientSummary) {
        let vault = try VaultReader().open(vaultURL)
        return (vault, try #require(vault.patients.first { $0.patientID == patientID }))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-draft-trash-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct DraftTrashSyntheticFailure: Error {}
