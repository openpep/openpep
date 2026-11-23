// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct AdministrativeUndoTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let appointmentID = "appt_0198f6c0-0000-7000-8000-000000000001"
    private let date = ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")!

    @Test("restores an archived patient while preserving fields and extensions")
    func restoresArchivedPatient() throws {
        try withContext { vault, patient in
            let manifestURL = patient.url.appending(path: "patient.yaml")
            var seededText = try String(contentsOf: manifestURL, encoding: .utf8)
            seededText += "x_owner_note: {\"kept\":[true,1]}\n"
            try Data(seededText.utf8).write(to: manifestURL, options: [.atomic])
            let seeded = try #require(VaultReader().open(vault.url).patients.first)
            let before = try #require(seeded.record)
            let archived = try PatientEditor().update(
                patient: seeded,
                input: patientInput(from: before),
                status: .archived,
                updatedAt: date.addingTimeInterval(60)
            )
            let archivedPatient = try #require(VaultReader().open(vault.url).patients.first)
            let restored = try PatientEditor().restoreStatus(
                patient: archivedPatient,
                expectedCurrentRecord: archived,
                previousStatus: before.status,
                restoredAt: date.addingTimeInterval(120)
            )

            #expect(restored.status == .active)
            #expect(restored.archivedAt == nil)
            #expect(restored.fullName == archived.fullName)
            #expect(restored.preferredName == archived.preferredName)
            #expect(restored.birthDate == archived.birthDate)
            #expect(restored.contacts == archived.contacts)
            #expect(restored.identifiers == archived.identifiers)
            #expect(restored.alerts == archived.alerts)
            #expect(restored.createdAt == archived.createdAt)
            #expect(restored.extensions == archived.extensions)
            #expect(restored.extensions["x_owner_note"] == .mapping([
                "kept": .sequence([.boolean(true), .integer(1)]),
            ]))
        }
    }

    @Test("patient update and restore refuse stale versions")
    func patientRevisionConflicts() throws {
        try withContext { vault, patient in
            let original = try #require(patient.record)
            let manifestURL = patient.url.appending(path: "patient.yaml")
            let externallyEdited = copyPatient(
                original,
                preferredName: "Edição concorrente",
                updatedAt: "2026-09-05T12:01:00Z"
            )
            try PatientRecordCodec.encode(externallyEdited).write(to: manifestURL, options: [.atomic])
            expectRule("patient.revision_conflict") {
                _ = try PatientEditor().update(
                    patient: patient,
                    input: patientInput(from: original),
                    updatedAt: date.addingTimeInterval(120)
                )
            }
            let recordAfterRejectedUpdate = try VaultManifestValidator.validatePatient(
                data: Data(contentsOf: manifestURL)
            )
            #expect(recordAfterRejectedUpdate == externallyEdited)

            let currentPatient = try #require(VaultReader().open(vault.url).patients.first)
            let archived = try PatientEditor().update(
                patient: currentPatient,
                input: patientInput(from: externallyEdited),
                status: .archived,
                updatedAt: date.addingTimeInterval(180)
            )
            let archivedPatient = try #require(VaultReader().open(vault.url).patients.first)
            let changedArchive = copyPatient(
                archived,
                preferredName: "Alterado após arquivar",
                updatedAt: "2026-09-05T12:04:00Z"
            )
            try PatientRecordCodec.encode(changedArchive).write(to: manifestURL, options: [.atomic])
            expectRule("patient.revision_conflict") {
                _ = try PatientEditor().restoreStatus(
                    patient: archivedPatient,
                    expectedCurrentRecord: archived,
                    previousStatus: .active,
                    restoredAt: date.addingTimeInterval(300)
                )
            }
            let recordAfterRejectedRestore = try VaultManifestValidator.validatePatient(
                data: Data(contentsOf: manifestURL)
            )
            #expect(recordAfterRejectedRestore == changedArchive)
        }
    }

    @Test("failed patient restore preserves the archived version for retry")
    func patientRestoreFailurePreservesCurrent() throws {
        try withContext { vault, patient in
            let record = try #require(patient.record)
            let archived = try PatientEditor().update(
                patient: patient,
                input: patientInput(from: record),
                status: .archived,
                updatedAt: date.addingTimeInterval(60)
            )
            let archivedPatient = try #require(VaultReader().open(vault.url).patients.first)
            let failing = PatientEditor(faultInjector: { step in
                if step == .temporaryManifestWritten { throw SyntheticUndoFailure() }
            })
            do {
                _ = try failing.restoreStatus(
                    patient: archivedPatient,
                    expectedCurrentRecord: archived,
                    previousStatus: .active,
                    restoredAt: date.addingTimeInterval(120)
                )
                Issue.record("a falha injetada deveria interromper a restauração")
            } catch is SyntheticUndoFailure {
                // Expected.
            }
            let recordAfterFailure = try VaultManifestValidator.validatePatient(
                data: Data(contentsOf: archivedPatient.url.appending(path: "patient.yaml"))
            )
            #expect(recordAfterFailure == archived)
        }
    }

    @Test("restores a cancelled appointment without changing fields, link or extensions")
    func restoresCancelledAppointment() throws {
        try withContext { vault, patient in
            let created = try createAppointment(vault: vault, patient: patient)
            var seededText = try String(contentsOf: created.url, encoding: .utf8)
            seededText += "x_owner_note: {\"kept\":[true,1]}\n"
            try Data(seededText.utf8).write(to: created.url, options: [.atomic])
            let seeded = try #require(VaultReader().open(vault.url).appointments.first)
            let previousStatus = seeded.record.status
            let cancelled = try AppointmentWriter().cancel(
                seeded,
                in: vault.url,
                patients: [patient],
                updatedAt: date.addingTimeInterval(60)
            )
            let current = try VaultReader().open(vault.url)
            let cancelledSnapshot = try #require(current.appointments.first)
            let restored = try AppointmentWriter().restoreCancelled(
                cancelledSnapshot,
                expectedCurrentRecord: cancelled.record,
                previousStatus: previousStatus,
                in: current.url,
                patients: current.patients,
                restoredAt: date.addingTimeInterval(120)
            )

            #expect(restored.record.status == .scheduled)
            #expect(restored.record.patientID == cancelled.record.patientID)
            #expect(restored.record.startsAt == cancelled.record.startsAt)
            #expect(restored.record.endsAt == cancelled.record.endsAt)
            #expect(restored.record.timeZone == cancelled.record.timeZone)
            #expect(restored.record.modality == cancelled.record.modality)
            #expect(restored.record.location == cancelled.record.location)
            #expect(restored.record.remoteAccessURL == cancelled.record.remoteAccessURL)
            #expect(restored.record.administrativeNote == cancelled.record.administrativeNote)
            #expect(restored.record.encounterID == nil)
            #expect(restored.record.createdAt == cancelled.record.createdAt)
            #expect(restored.record.extensions == cancelled.record.extensions)
            #expect(restored.record.extensions["x_owner_note"] == .mapping([
                "kept": .sequence([.boolean(true), .integer(1)]),
            ]))
        }
    }

    @Test("appointment restore refuses a stale cancelled record")
    func appointmentRevisionConflict() throws {
        try withContext { vault, patient in
            let created = try createAppointment(vault: vault, patient: patient)
            let cancelled = try AppointmentWriter().cancel(
                created,
                in: vault.url,
                patients: [patient],
                updatedAt: date.addingTimeInterval(60)
            )
            let changed = copyAppointment(
                cancelled.record,
                administrativeNote: "Alteração administrativa concorrente",
                updatedAt: "2026-09-05T12:02:00Z"
            )
            try AppointmentRecordCodec.encode(changed).write(to: cancelled.url, options: [.atomic])
            let current = try VaultReader().open(vault.url)
            expectRule("appointment.revision_conflict") {
                _ = try AppointmentWriter().restoreCancelled(
                    cancelled,
                    expectedCurrentRecord: cancelled.record,
                    previousStatus: .scheduled,
                    in: current.url,
                    patients: current.patients,
                    restoredAt: date.addingTimeInterval(180)
                )
            }
            let recordAfterRejectedRestore = try VaultManifestValidator.validateAppointment(
                data: Data(contentsOf: cancelled.url)
            )
            #expect(recordAfterRejectedRestore == changed)
        }
    }

    @Test("appointment restore refuses a current reverse encounter link")
    func appointmentReverseLinkConflict() throws {
        try withContext { vault, patient in
            let created = try createAppointment(vault: vault, patient: patient)
            let cancelled = try AppointmentWriter().cancel(
                created,
                in: vault.url,
                patients: [patient],
                updatedAt: date.addingTimeInterval(60)
            )
            _ = try ClinicalDraftCreator().create(
                in: patient,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: "enc_0198f6c1-0000-7000-8000-000000000001",
                    noteID: "note_0198f6c2-0000-7000-8000-000000000001",
                    syntheticActorID: "usr_0198f6c3-0000-7000-8000-000000000001"
                ),
                appointmentID: appointmentID,
                input: .scheduled(cancelled.record),
                startedAt: date.addingTimeInterval(120)
            )
            let current = try VaultReader().open(vault.url)
            let currentAppointment = try #require(current.appointments.first)
            expectRule("appointment.restore_cancelled") {
                _ = try AppointmentWriter().restoreCancelled(
                    currentAppointment,
                    expectedCurrentRecord: currentAppointment.record,
                    previousStatus: .scheduled,
                    in: current.url,
                    patients: current.patients,
                    restoredAt: date.addingTimeInterval(180)
                )
            }
            let recordAfterRejectedRestore = try VaultManifestValidator.validateAppointment(
                data: Data(contentsOf: currentAppointment.url)
            )
            #expect(recordAfterRejectedRestore.status == .cancelled)
        }
    }

    @Test("failed appointment restore leaves the cancelled record intact")
    func appointmentRestoreFailurePreservesCurrent() throws {
        try withContext { vault, patient in
            let created = try createAppointment(vault: vault, patient: patient)
            let cancelled = try AppointmentWriter().cancel(
                created,
                in: vault.url,
                patients: [patient],
                updatedAt: date.addingTimeInterval(60)
            )
            let current = try VaultReader().open(vault.url)
            let currentAppointment = try #require(current.appointments.first)
            let failing = AppointmentWriter(faultInjector: { step in
                if step == .temporaryWritten { throw SyntheticUndoFailure() }
            })
            do {
                _ = try failing.restoreCancelled(
                    currentAppointment,
                    expectedCurrentRecord: cancelled.record,
                    previousStatus: .scheduled,
                    in: current.url,
                    patients: current.patients,
                    restoredAt: date.addingTimeInterval(120)
                )
                Issue.record("a falha injetada deveria interromper a restauração")
            } catch is SyntheticUndoFailure {
                // Expected.
            }
            let recordAfterFailure = try VaultManifestValidator.validateAppointment(
                data: Data(contentsOf: currentAppointment.url)
            )
            #expect(recordAfterFailure == cancelled.record)
        }
    }

    private func withContext(_ body: (VaultSummary, PatientSummary) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-administrative-undo-\(UUID().uuidString)",
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
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Desfazer Sintético",
                preferredName: "Desfazer",
                birthDate: "2000-02-29",
                contacts: [PatientContact(type: .email, value: "undo@example.invalid", authorizedForCare: true)],
                identifiers: [PatientIdentifier(type: .other, value: "synthetic-undo")],
                alerts: [PatientAlert(
                    type: .critical,
                    description: "Alerta sintético",
                    source: "Fonte sintética",
                    recordedAt: "2026-09-05T12:00:00Z"
                )]
            ),
            createdAt: date
        )
        try body(try VaultReader().open(vault.url), patient)
    }

    private func createAppointment(vault: VaultSummary, patient: PatientSummary) throws -> AppointmentSummary {
        try AppointmentWriter().create(
            in: vault.url,
            patient: patient,
            identity: AppointmentCreationIdentity(appointmentID: appointmentID),
            input: AppointmentInput(
                patientID: patientID,
                startsAt: date.addingTimeInterval(3_600),
                endsAt: date.addingTimeInterval(5_400),
                timeZone: "America/Sao_Paulo",
                modality: .telemedicine,
                status: .scheduled,
                location: nil,
                remoteAccessURL: "https://meet.google.com/synthetic-undo",
                administrativeNote: "Nota administrativa sintética",
                telemedicineConsentConfirmed: true
            ),
            createdAt: date
        )
    }

    private func patientInput(from record: PatientRecord) -> PatientRecordInput {
        PatientRecordInput(
            fullName: record.fullName ?? "",
            preferredName: record.preferredName,
            birthDate: record.birthDate,
            contacts: record.contacts,
            identifiers: record.identifiers,
            alerts: record.alerts
        )
    }

    private func copyPatient(
        _ record: PatientRecord,
        preferredName: String?,
        updatedAt: String
    ) -> PatientRecord {
        PatientRecord(
            schema: record.schema,
            patientID: record.patientID,
            status: record.status,
            fullName: record.fullName,
            preferredName: preferredName,
            birthDate: record.birthDate,
            contacts: record.contacts,
            identifiers: record.identifiers,
            alerts: record.alerts,
            createdAt: record.createdAt,
            updatedAt: updatedAt,
            archivedAt: record.archivedAt,
            extensions: record.extensions
        )
    }

    private func copyAppointment(
        _ record: AppointmentRecord,
        administrativeNote: String?,
        updatedAt: String
    ) -> AppointmentRecord {
        AppointmentRecord(
            schema: record.schema,
            appointmentID: record.appointmentID,
            patientID: record.patientID,
            startsAt: record.startsAt,
            endsAt: record.endsAt,
            timeZone: record.timeZone,
            modality: record.modality,
            status: record.status,
            location: record.location,
            remoteAccessURL: record.remoteAccessURL,
            administrativeNote: administrativeNote,
            encounterID: record.encounterID,
            createdAt: record.createdAt,
            updatedAt: updatedAt,
            extensions: record.extensions
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
}

private struct SyntheticUndoFailure: Error {}
