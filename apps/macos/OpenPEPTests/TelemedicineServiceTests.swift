// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct TelemedicineServiceTests {
    @Test("Scheduled direct start preserves modality and recorded consent without inventing facts")
    func scheduledDirectStart() {
        for confirmed in [false, true] {
            let input = EncounterStartInput.scheduled(appointment(consentConfirmed: confirmed).record)
            #expect(input.modality == .telemedicine)
            #expect(input.template == .blank)
            #expect(input.telemedicine == TelemedicineEncounterInput(
                consent: confirmed ? .confirmed : .notRecorded,
                declaredLocation: nil, participants: [], limitations: nil, contingency: nil))
        }
        let inPerson = EncounterStartInput.scheduled(appointment(modality: .inPerson).record)
        #expect(inPerson.modality == .inPerson)
        #expect(inPerson.template == .blank)
        #expect(inPerson.telemedicine == nil)
    }

    @Test("Direct WhatsApp conversation needs only a valid registered patient phone, never a meeting link")
    func directConversation() throws {
        let patient = patient(contacts: [
            .init(type: .phone, value: "+12025550100", authorizedForCare: true),
            .init(type: .phone, value: "+12025550101", authorizedForCare: false)
        ])
        let contact = try #require(WhatsAppShare.contacts(for: patient).first)
        for destination in WhatsAppDestination.allCases {
            let url = try WhatsAppShare.conversationURL(patient: patient, contactID: contact.id, destination: destination)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == (destination == .app ? "whatsapp" : "https"))
            #expect(components.queryItems == [URLQueryItem(name: "phone", value: "12025550100")])
        }
        #expect(try WhatsAppShare.conversationURL(patient: patient, contactID: "phone:+12025550101", destination: .web).absoluteString.contains("12025550101"))
    }

    private let patientID = "pt_0198f7c0-0000-7000-8000-000000000001"
    private let appointmentID = "appt_0198f7c0-0000-7000-8000-000000000002"

    @Test("email availability explains missing and malformed contacts")
    func emailAvailability() {
        #expect(ConsultationInvitation.emailUnavailableReason(for: patient(contacts: []))?.contains("tipo E-mail") == true)
        #expect(ConsultationInvitation.emailUnavailableReason(for: patient(contacts: [
            .init(type: .email, value: "paciente@example.invalid", authorizedForCare: false)
        ])) == nil)
        #expect(ConsultationInvitation.emailUnavailableReason(for: patient(contacts: [
            .init(type: .email, value: "sem-endereco", authorizedForCare: true)
        ]))?.contains("formato") == true)
        #expect(ConsultationInvitation.emailUnavailableReason(for: patient(contacts: [
            .init(type: .email, value: "paciente@example.invalid", authorizedForCare: true)
        ])) == nil)
    }

    @Test("invitation uses the saved appointment time zone and separates consultation text")
    func invitationText() throws {
        let record = appointment().record
        let formal = try ConsultationInvitation.text(for: record, consultationOpen: false)
        #expect(formal.contains("01/09/2026 às 13:00 (America/Sao_Paulo)"))
        #expect(formal.contains(try #require(record.remoteAccessURL)))
        #expect(!formal.contains("encontro"))
        let short = try ConsultationInvitation.text(for: record, consultationOpen: true)
        #expect(short == "Olá, segue o link para nossa consulta: \(record.remoteAccessURL!)")
        let patient = patient(contacts: [.init(type: .phone, value: "+12025550100", authorizedForCare: true)])
        let contact = try #require(WhatsAppShare.contacts(for: patient).first)
        let share = try WhatsAppShare(patient: patient, contactID: contact.id, link: record.remoteAccessURL,
            destination: .web, invitation: formal)
        #expect(URLComponents(url: share.url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == formal)
    }

    @Test("email recipients come only from current valid patient contacts")
    func emailInvitationRecipient() throws {
        let original = appointment()
        let patient = patient(contacts: [
            .init(type: .email, value: "paciente@example.invalid", authorizedForCare: true),
            .init(type: .email, value: "naoautorizado@example.invalid", authorizedForCare: false),
            .init(type: .email, value: "a@example.invalid,b@example.invalid", authorizedForCare: true),
            .init(type: .email, value: "a@example.invalid?bcc=outro", authorizedForCare: true)
        ])
        let contacts = ConsultationInvitation.emailContacts(for: patient)
        #expect(contacts.count == 2)
        let contact = try #require(contacts.first)
        try ConsultationInvitation.validate(expected: original, current: original, patient: patient,
            contactID: contact.id, expectedRecipient: "paciente@example.invalid")
        #expect(throws: VaultValidationIssue.self) {
            try ConsultationInvitation.validate(expected: original, current: original, patient: patient,
                contactID: contact.id, expectedRecipient: "medico@example.invalid")
        }
        #expect(throws: VaultValidationIssue.self) {
            try ConsultationInvitation.validate(expected: original, current: appointment(status: .cancelled), patient: patient,
                contactID: contact.id, expectedRecipient: contact.destination)
        }
        #expect(throws: VaultValidationIssue.self) {
            try ConsultationInvitation.validate(expected: original, current: original, patient: nil,
                contactID: contact.id, expectedRecipient: contact.destination)
        }
    }

    @Test("WhatsApp prepares minimal escaped text for app and web without sending")
    func whatsAppComposition() throws {
        let patient = patient(contacts: [
            PatientContact(type: .phone, value: "+1 (202) 555-0100", authorizedForCare: true),
            PatientContact(type: .phone, value: "+1 (202) 555-0101", authorizedForCare: false),
            PatientContact(type: .phone, value: "2025550102", authorizedForCare: true),
            PatientContact(type: .email, value: "teste@example.invalid", authorizedForCare: true)
        ])
        let contact = try #require(WhatsAppShare.contacts(for: patient).first)
        #expect(WhatsAppShare.contacts(for: patient).count == 2)
        let link = "https://example.invalid/sala?a=1+2&text=outro#fragmento"
        for destination in WhatsAppDestination.allCases {
            let proposal = try WhatsAppShare(patient: patient, contactID: contact.id, link: link, destination: destination)
            let components = try #require(URLComponents(url: proposal.url, resolvingAgainstBaseURL: false))
            #expect(components.scheme == (destination == .app ? "whatsapp" : "https"))
            #expect(components.host == (destination == .app ? "send" : "web.whatsapp.com"))
            #expect(components.queryItems?.count == 2)
            #expect(components.queryItems?.first?.value == "12025550100")
            #expect(components.queryItems?.last?.value == proposal.message)
            #expect(proposal.message == "Olá, segue o link para nossa consulta: \(link)")
            #expect(!proposal.message.contains(patient.displayName))
            #expect(components.fragment == nil)
            #expect(components.percentEncodedQuery?.contains("%2B") == true)
        }
        #expect(try WhatsAppShare(patient: patient, contactID: "phone:+12025550101", link: link, destination: .web).url.absoluteString.contains("12025550101"))
        for invalid in [nil, "http://example.invalid", "https://a:b@example.invalid", "https://example.invalid/\nroom"] as [String?] {
            #expect(throws: VaultValidationIssue.self) {
                _ = try WhatsAppShare(patient: patient, contactID: contact.id, link: invalid, destination: .app)
            }
        }
    }

    @Test("WhatsApp opens only while the reviewed proposal remains current")
    func whatsAppRejectsChangedPreview() throws {
        let originalPatient = patient(contacts: [
            PatientContact(type: .phone, value: "+1 (202) 555-0100", authorizedForCare: true)
        ])
        let contact = try #require(WhatsAppShare.contacts(for: originalPatient).first)
        let originalAppointment = appointment()
        let proposal = try WhatsAppShare(
            patient: originalPatient,
            contactID: contact.id,
            link: originalAppointment.record.remoteAccessURL,
            destination: .web
        )

        func expectChanged(
            appointment: AppointmentSummary?,
            patient: PatientSummary?
        ) {
            var openCount = 0
            do {
                _ = try WhatsAppShare.openIfUnchanged(
                    appointment: appointment,
                    patient: patient,
                    expectedPatientID: originalPatient.patientID,
                    expectedPatientName: originalPatient.displayName,
                    contactID: contact.id,
                    destination: .web,
                    proposal: proposal,
                    open: { _ in openCount += 1; return true }
                )
                Issue.record("A composição alterada deveria ser recusada.")
            } catch let issue as VaultValidationIssue {
                #expect(issue.rule == "whatsapp.changed")
            } catch {
                Issue.record("Erro inesperado: \(error)")
            }
            #expect(openCount == 0)
        }

        expectChanged(
            appointment: appointment(remoteAccessURL: "https://example.invalid/changed"),
            patient: originalPatient
        )
        expectChanged(
            appointment: originalAppointment,
            patient: patient(contacts: [])
        )
        expectChanged(
            appointment: originalAppointment,
            patient: patient(preferredName: "Nome alterado", contacts: [
                PatientContact(type: .phone, value: "+1 (202) 555-0100", authorizedForCare: true)
            ])
        )
        expectChanged(
            appointment: appointment(
                patientID: "pt_0198f7c0-0000-7000-8000-000000000003"
            ),
            patient: originalPatient
        )
        expectChanged(appointment: appointment(status: .completed), patient: originalPatient)
        expectChanged(appointment: appointment(modality: .inPerson), patient: originalPatient)

        var inProgressOpenCount = 0
        #expect(try WhatsAppShare.openIfUnchanged(
            appointment: appointment(status: .inProgress),
            patient: originalPatient,
            expectedPatientID: originalPatient.patientID,
            expectedPatientName: originalPatient.displayName,
            contactID: contact.id,
            destination: .web,
            proposal: proposal,
            open: { _ in inProgressOpenCount += 1; return true }
        ))
        #expect(inProgressOpenCount == 1)

        var openedURLs: [URL] = []
        let systemAccepted = try WhatsAppShare.openIfUnchanged(
            appointment: originalAppointment,
            patient: originalPatient,
            expectedPatientID: originalPatient.patientID,
            expectedPatientName: originalPatient.displayName,
            contactID: contact.id,
            destination: .web,
            proposal: proposal,
            open: { openedURLs.append($0); return false }
        )
        #expect(!systemAccepted)
        #expect(openedURLs == [proposal.url])
    }

    @Test("selects valid contacts without a legacy consent gate")
    func selectsValidContacts() {
        let patient = patient(contacts: [
            PatientContact(type: .phone, value: "+55 (00) 90000-0000", authorizedForCare: true),
            PatientContact(type: .email, value: "teleconsulta@example.invalid", authorizedForCare: true),
            PatientContact(type: .email, value: "privado@example.invalid", authorizedForCare: false),
            PatientContact(type: .phone, value: "12#34", authorizedForCare: true),
        ])

        let options = TelemedicineContactResolver.options(for: patient)
        #expect(options.map(\.destination) == ["+5500900000000", "teleconsulta@example.invalid", "privado@example.invalid"])
        #expect(options.map(\.typeLabel) == ["Telefone", "E-mail", "E-mail"])
    }

    @Test("builds a safe FaceTime URL and rejects malformed contacts")
    func buildsFaceTimeURL() throws {
        let phone = try #require(TelemedicineContactResolver.option(for: PatientContact(
            type: .phone,
            value: "+55 (00) 90000-0000",
            authorizedForCare: true
        )))
        let url = try TelemedicineURLBuilder.faceTimeURL(for: phone)
        #expect(url.scheme == "facetime")
        #expect(url.absoluteString.contains("5500900000000"))

        #expect(TelemedicineContactResolver.option(for: PatientContact(
            type: .email,
            value: "dois@@example.invalid",
            authorizedForCare: true
        )) == nil)
        #expect(TelemedicineContactResolver.option(for: PatientContact(
            type: .phone,
            value: "+55\n00900000000",
            authorizedForCare: true
        )) == nil)
    }

    @Test("accepts only HTTPS saved links without embedded credentials")
    func validatesSavedLink() throws {
        let accepted = try TelemedicineURLBuilder.savedLinkURL(
            "https://facetime.apple.com/join/synthetic-room?token=synthetic"
        )
        #expect(accepted.host == "facetime.apple.com")

        for value in [
            "http://example.invalid/room",
            "https://user:secret@example.invalid/room",
            "https:///room",
        ] {
            #expect(throws: VaultValidationIssue.self) {
                _ = try TelemedicineURLBuilder.savedLinkURL(value)
            }
        }
    }

    @Test("records the request before opening and preserves existing extensions")
    func recordsBeforeOpening() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            var seeded = try String(contentsOf: context.appointment.url, encoding: .utf8)
            seeded += "x_owner_note: \"preserved\"\n"
            try Data(seeded.utf8).write(to: context.appointment.url, options: [.atomic])
            let appointment = try #require(VaultReader().open(context.vault.url).appointments.first)
            let contact = try #require(TelemedicineContactResolver.options(for: context.patient).first)
            var observedURL: URL?
            var extensionWasPresentWhenOpened = false
            let coordinator = TelemedicineHandoffCoordinator(actions: TelemedicineExternalActions(
                open: { url in
                    observedURL = url
                    let reopened = try? VaultReader().open(context.vault.url).appointments.first
                    extensionWasPresentWhenOpened = reopened?.record.extensions[
                        "x_last_remote_handoff_method"
                    ] == .string("facetime_contact")
                    return true
                },
                copy: { _ in false }
            ))

            let outcome = try coordinator.openFaceTime(
                for: appointment,
                contact: contact,
                in: context.vault.url,
                requestedAt: date("2026-09-01T14:00:00Z")
            )

            #expect(outcome.systemAccepted)
            #expect(observedURL?.scheme == "facetime")
            #expect(extensionWasPresentWhenOpened)
            #expect(outcome.appointment.record.extensions["x_owner_note"] == .string("preserved"))
            #expect(outcome.appointment.record.extensions["x_last_remote_handoff_requested_at"] ==
                .string("2026-09-01T14:00:00Z"))
        }
    }

    @Test("does not open an external app when the request cannot be persisted")
    func writeFailurePreventsOpening() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            let contact = try #require(TelemedicineContactResolver.options(for: context.patient).first)
            var opened = false
            let coordinator = TelemedicineHandoffCoordinator(
                writer: AppointmentWriter(faultInjector: { step in
                    if step == .temporaryWritten { throw SyntheticTelemedicineFailure() }
                }),
                actions: TelemedicineExternalActions(
                    open: { _ in opened = true; return true },
                    copy: { _ in false }
                )
            )

            #expect(throws: SyntheticTelemedicineFailure.self) {
                _ = try coordinator.openFaceTime(
                    for: context.appointment,
                    contact: contact,
                    in: context.vault.url,
                    requestedAt: date("2026-09-01T14:00:00Z")
                )
            }
            #expect(!opened)
        }
    }

    @Test("opens and copies the saved link without inferring a connected call")
    func savedLinkActions() throws {
        try withTemporaryDirectory { parent in
            let context = try createContext(in: parent)
            var opened: URL?
            var copied: String?
            let coordinator = TelemedicineHandoffCoordinator(actions: TelemedicineExternalActions(
                open: { opened = $0; return false },
                copy: { copied = $0; return true }
            ))

            let outcome = try coordinator.openSavedLink(
                for: context.appointment,
                in: context.vault.url,
                requestedAt: date("2026-09-01T15:00:00Z")
            )
            #expect(!outcome.systemAccepted)
            #expect(opened?.scheme == "https")
            #expect(outcome.appointment.record.extensions["x_last_remote_handoff_method"] ==
                .string("saved_link"))
            #expect(try coordinator.copySavedLink(for: outcome.appointment))
            #expect(copied == "https://facetime.apple.com/join/synthetic-room")
        }
    }

    private func createContext(
        in parent: URL
    ) throws -> (vault: VaultSummary, patient: PatientSummary, appointment: AppointmentSummary) {
        let vault = try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: date("2026-09-01T12:00:00Z")
        )
        let patient = try PatientCreator().createRegistered(
            in: vault.url,
            identity: PatientCreationIdentity(patientID: patientID),
            input: PatientRecordInput(
                fullName: "Paciente Sintético Remoto",
                preferredName: "Remoto",
                birthDate: nil,
                contacts: [
                    PatientContact(
                        type: .email,
                        value: "teleconsulta@example.invalid",
                        authorizedForCare: true
                    ),
                ],
                identifiers: [],
                alerts: []
            ),
            createdAt: date("2026-09-01T12:10:00Z")
        )
        let appointment = try AppointmentWriter().create(
            in: vault.url,
            patient: patient,
            identity: AppointmentCreationIdentity(appointmentID: appointmentID),
            input: AppointmentInput(
                patientID: patientID,
                startsAt: date("2026-09-01T16:00:00Z"),
                endsAt: date("2026-09-01T16:30:00Z"),
                timeZone: "America/Sao_Paulo",
                modality: .telemedicine,
                status: .scheduled,
                location: nil,
                remoteAccessURL: "https://facetime.apple.com/join/synthetic-room",
                administrativeNote: nil
            ),
            createdAt: date("2026-09-01T12:20:00Z")
        )
        return (vault, patient, appointment)
    }

    private func appointment(
        patientID: String? = nil,
        modality: AppointmentModality = .telemedicine,
        status: AppointmentStatus = .scheduled,
        remoteAccessURL: String = "https://facetime.apple.com/join/synthetic-room",
        consentConfirmed: Bool = false
    ) -> AppointmentSummary {
        AppointmentSummary(
            record: AppointmentRecord(
                schema: "openpep/appointment@1",
                appointmentID: appointmentID,
                patientID: patientID ?? self.patientID,
                startsAt: "2026-09-01T16:00:00Z",
                endsAt: "2026-09-01T16:30:00Z",
                timeZone: "America/Sao_Paulo",
                modality: modality,
                status: status,
                location: modality == .inPerson ? "Consultório sintético" : nil,
                remoteAccessURL: modality == .telemedicine ? remoteAccessURL : nil,
                administrativeNote: nil,
                encounterID: nil,
                createdAt: "2026-09-01T12:20:00Z",
                updatedAt: "2026-09-01T12:20:00Z",
                extensions: consentConfirmed ? ["x_openpep_telemedicine_consent": .string("confirmed")] : [:]
            ),
            url: URL(fileURLWithPath: "/synthetic/\(appointmentID).yaml")
        )
    }

    private func patient(
        patientID: String? = nil,
        preferredName: String = "Remoto",
        contacts: [PatientContact]
    ) -> PatientSummary {
        let patientID = patientID ?? self.patientID
        return PatientSummary(
            patientID: patientID,
            url: URL(fileURLWithPath: "/synthetic/\(patientID)"),
            record: PatientRecord(
                schema: "openpep/patient@1",
                patientID: patientID,
                status: .active,
                fullName: "Paciente Sintético Remoto",
                preferredName: preferredName,
                birthDate: nil,
                contacts: contacts,
                identifiers: [],
                alerts: [],
                createdAt: "2026-09-01T12:00:00Z",
                updatedAt: "2026-09-01T12:00:00Z",
                archivedAt: nil,
                extensions: [:]
            ),
            rawAssets: [],
            encounters: []
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-telemedicine-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct SyntheticTelemedicineFailure: Error {}
