// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct AppointmentServiceTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let appointmentID = "appt_0198f6c0-0000-7000-8000-000000000001"

    @Test("appointment consent is explicit, persists and resets on in-person conversion")
    func appointmentConsent() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            var remote = input(modality: .telemedicine, location: nil,
                remoteAccessURL: "https://example.invalid/sala")
            #expect(!remote.telemedicineConsentConfirmed)
            remote.telemedicineConsentConfirmed = true
            let created = try AppointmentWriter().create(in: context.vault.url, patient: context.patient,
                identity: .init(appointmentID: appointmentID), input: remote)
            let reopened = try #require(VaultReader().open(context.vault.url).appointments.first)
            #expect(reopened.record.telemedicineConsentConfirmed)
            #expect(reopened.record == created.record)
            let converted = try AppointmentWriter().update(reopened, in: context.vault.url,
                patients: [context.patient], input: input())
            #expect(converted.record.modality == .inPerson)
            #expect(!converted.record.telemedicineConsentConfirmed)
            #expect(converted.record.remoteAccessURL == nil)
            remote.telemedicineConsentConfirmed = false
            let back = try AppointmentWriter().update(converted, in: context.vault.url,
                patients: [context.patient], input: remote)
            #expect(!back.record.telemedicineConsentConfirmed)
        }
    }

    @Test("validates shared appointment fixtures")
    func validatesFixtures() throws {
        let inPerson = try VaultManifestValidator.validateAppointment(
            data: Data(contentsOf: fixtureRoot.appending(path: "valid/in-person/appointment.yaml"))
        )
        let telemedicine = try VaultManifestValidator.validateAppointment(
            data: Data(contentsOf: fixtureRoot.appending(path: "valid/telemedicine/appointment.yaml"))
        )
        #expect(inPerson.modality == .inPerson)
        #expect(telemedicine.remoteAccessURL == "https://facetime.apple.com/join/synthetic-room")
        #expect(telemedicine.extensions["x_fixture_note"] == .string("preserved"))

        for caseName in ["invalid-interval", "invalid-time-zone", "in-person-with-link", "unknown-status"] {
            let caseURL = fixtureRoot.appending(path: "invalid/\(caseName)")
            let expected = try JSONDecoder().decode(
                AppointmentFixtureExpectation.self,
                from: Data(contentsOf: caseURL.appending(path: "expectation.json"))
            )
            do {
                _ = try VaultManifestValidator.validateAppointment(
                    data: Data(contentsOf: caseURL.appending(path: "appointment.yaml"))
                )
                Issue.record("\(caseName) deveria falhar")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == expected.rule)
                #expect(issue.path == expected.path)
            }
        }
    }

    @Test("creates and reopens an appointment without an index")
    func createsAndReopens() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let created = try AppointmentWriter().create(
                in: context.vault.url,
                patient: context.patient,
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: input(),
                createdAt: date("2026-08-31T18:00:00Z")
            )
            let bytes = try Data(contentsOf: created.url)
            let reopened = try VaultReader().open(context.vault.url)
            #expect(reopened.appointments.count == 1)
            #expect(reopened.appointments[0].record == created.record)
            #expect(try Data(contentsOf: reopened.appointments[0].url) == bytes)
            #expect(created.url.path.contains("appointments/2026/09/"))
        }
    }

    @Test("opens an older vault without appointments and creates the directory on demand")
    func supportsAbsentAppointmentsDirectory() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let appointmentsRoot = context.vault.url.appending(path: "appointments")
            try FileManager.default.removeItem(at: appointmentsRoot)
            let reopened = try VaultReader().open(context.vault.url)
            #expect(reopened.appointments.isEmpty)
            #expect(reopened.writingAllowed)
            _ = try AppointmentWriter().create(
                in: reopened.url,
                patient: try #require(reopened.patients.first),
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: input()
            )
            #expect(FileManager.default.fileExists(atPath: appointmentsRoot.path))
        }
    }

    @Test("edits, reschedules, preserves extensions and cancels without deleting")
    func editsReschedulesAndCancels() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let created = try AppointmentWriter().create(
                in: context.vault.url,
                patient: context.patient,
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: input(),
                createdAt: date("2026-08-31T18:00:00Z")
            )
            var seeded = try String(contentsOf: created.url, encoding: .utf8)
            seeded += "x_owner_note: {\"kept\":[true,1]}\n"
            try Data(seeded.utf8).write(to: created.url, options: [.atomic])
            let seededSummary = try #require(VaultReader().open(context.vault.url).appointments.first)
            let oldURL = seededSummary.url
            let movedInput = input(
                startsAt: "2026-10-01T12:00:00Z",
                endsAt: "2026-10-01T12:45:00Z",
                modality: .telemedicine,
                location: nil,
                remoteAccessURL: "https://facetime.apple.com/join/synthetic-updated"
            )
            let moved = try AppointmentWriter().update(
                seededSummary,
                in: context.vault.url,
                patients: [context.patient],
                input: movedInput,
                updatedAt: date("2026-09-01T18:00:00Z")
            )
            #expect(!FileManager.default.fileExists(atPath: oldURL.path))
            #expect(moved.url.path.contains("appointments/2026/10/"))
            #expect(moved.record.extensions["x_owner_note"] == .mapping([
                "kept": .sequence([.boolean(true), .integer(1)]),
            ]))
            let cancelled = try AppointmentWriter().cancel(
                moved,
                in: context.vault.url,
                patients: [context.patient],
                updatedAt: date("2026-09-01T19:00:00Z")
            )
            #expect(cancelled.record.status == .cancelled)
            #expect(FileManager.default.fileExists(atPath: cancelled.url.path))
        }
    }

    @Test("does not publish a partial appointment and preserves a published destination")
    func protectsWritesDuringFailure() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let writer = AppointmentWriter(faultInjector: { step in
                if step == .temporaryWritten { throw SyntheticAppointmentFailure() }
            })
            do {
                _ = try writer.create(
                    in: context.vault.url,
                    patient: context.patient,
                    identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                    input: input()
                )
                Issue.record("a escrita parcial deveria falhar")
            } catch is SyntheticAppointmentFailure {
                let inspection = AppointmentInspector().inspect(
                    vaultURL: context.vault.url,
                    patients: [context.patient]
                )
                #expect(inspection.appointments.isEmpty)
            }
        }
    }

    @Test("keeps the original when a cross-month reschedule is interrupted")
    func preservesOriginalDuringInterruptedMove() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let created = try AppointmentWriter().create(
                in: context.vault.url,
                patient: context.patient,
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: input()
            )
            let failing = AppointmentWriter(faultInjector: { step in
                if step == .destinationPublished { throw SyntheticAppointmentFailure() }
            })
            do {
                _ = try failing.update(
                    created,
                    in: context.vault.url,
                    patients: [context.patient],
                    input: input(
                        startsAt: "2026-10-01T12:00:00Z",
                        endsAt: "2026-10-01T12:30:00Z"
                    )
                )
                Issue.record("a remarcação interrompida deveria falhar")
            } catch is SyntheticAppointmentFailure {
                #expect(FileManager.default.fileExists(atPath: created.url.path))
                let newURL = context.vault.url.appending(
                    path: "appointments/2026/10/\(appointmentID).yaml"
                )
                #expect(FileManager.default.fileExists(atPath: newURL.path))
                _ = try VaultManifestValidator.validateAppointment(data: Data(contentsOf: created.url))
                _ = try VaultManifestValidator.validateAppointment(data: Data(contentsOf: newURL))
            }
        }
    }

    @Test("warns about overlap without blocking and isolates an invalid item")
    func conflictsAndIsolation() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let first = try AppointmentWriter().create(
                in: context.vault.url,
                patient: context.patient,
                identity: AppointmentCreationIdentity(appointmentID: appointmentID),
                input: input()
            )
            let overlapping = input(
                startsAt: "2026-09-01T12:15:00Z",
                endsAt: "2026-09-01T12:45:00Z"
            )
            #expect(AppointmentConflictDetector.conflicts(for: overlapping, among: [first]).map(\.id) == [appointmentID])

            let invalidID = "appt_0198f6c0-0000-7000-8000-000000000002"
            let invalid = try AppointmentWriter().create(
                in: context.vault.url,
                patient: context.patient,
                identity: AppointmentCreationIdentity(appointmentID: invalidID),
                input: input(startsAt: "2026-09-01T14:00:00Z", endsAt: "2026-09-01T14:30:00Z")
            )
            let broken = try String(contentsOf: invalid.url, encoding: .utf8)
                .replacingOccurrences(of: "ends_at: \"2026-09-01T14:30:00Z\"", with: "ends_at: \"2026-09-01T14:00:00Z\"")
            try Data(broken.utf8).write(to: invalid.url, options: [.atomic])
            let reopened = try VaultReader().open(context.vault.url)
            #expect(reopened.appointments.map(\.id) == [appointmentID])
            #expect(reopened.unavailableAppointments.map(\.appointmentID) == [invalidID])
            #expect(reopened.writingAllowed)
        }
    }

    private func input(
        startsAt: String = "2026-09-01T12:00:00Z",
        endsAt: String = "2026-09-01T12:30:00Z",
        modality: AppointmentModality = .inPerson,
        location: String? = "Consultório sintético 1",
        remoteAccessURL: String? = nil
    ) -> AppointmentInput {
        AppointmentInput(
            patientID: patientID,
            startsAt: date(startsAt),
            endsAt: date(endsAt),
            timeZone: "America/Sao_Paulo",
            modality: modality,
            status: .scheduled,
            location: location,
            remoteAccessURL: remoteAccessURL,
            administrativeNote: "Nota administrativa sintética"
        )
    }

    private func createContext(in parent: URL) throws -> (vault: VaultSummary, patient: PatientSummary) {
        let vault = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: date("2026-08-31T17:00:00Z")
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético da Agenda",
                preferredName: "Agenda",
                birthDate: nil,
                contacts: [],
                identifiers: [],
                alerts: []
            ),
            createdAt: date("2026-08-31T17:30:00Z")
        )
        return (vault, patient)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureRoot: URL {
        repositoryRoot.appending(path: "fixtures/appointment-v1")
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-appointment-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct AppointmentFixtureExpectation: Decodable {
    let rule: String
    let path: String
}

private struct SyntheticAppointmentFailure: Error {}
