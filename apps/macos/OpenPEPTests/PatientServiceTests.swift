// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct PatientServiceTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"

    @Test func postalAutofillReplacesBlankButPreservesUserEdits() {
        #expect(PostalCodeLookup.mayAutofill(current: nil, original: nil, lastAutomatic: nil))
        #expect(PostalCodeLookup.mayAutofill(current: .string("  "), original: .string("  "), lastAutomatic: nil))
        #expect(PostalCodeLookup.mayAutofill(current: .string("Rua anterior"), original: .string("Rua anterior"), lastAutomatic: "Rua anterior"))
        #expect(!PostalCodeLookup.mayAutofill(current: .string("Digitado"), original: .string(""), lastAutomatic: nil))
        #expect(!PostalCodeLookup.mayAutofill(current: .string("Manual"), original: .string("Manual"), lastAutomatic: nil))
    }

    @Test("preserves address and administrative notes through create, edit and reopen")
    func registrationRoundTrip() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            var input = completeInput
            input.registration = ["postal_code": .string("00000-000"),
                "street": .string("Rua Sintética"), "number": .string("123"),
                "notes": .string("Indicação sintética\nPrefere contato à tarde")]
            let created = try PatientCreator().createRegistered(in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID), input: input)
            #expect(created.record?.extensions["x_openpep_registration"] == .mapping(input.registration!))
            let changes = ClinicalChangeRecorder(patientURL: created.url)
            var edited = input
            edited.registration?["number"] = .string("456")
            let updated = try PatientEditor().update(patient: created, input: edited)
            #expect(changes.count == 1)
            #expect(updated.alerts == created.record?.alerts)
            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients.first?.record?.extensions["x_openpep_registration"] == .mapping(edited.registration!))
            // Older callers that do not edit administrative fields preserve them.
            let patient = try #require(reopened.patients.first)
            let preserved = try PatientEditor().update(patient: patient, input: completeInput)
            #expect(preserved.extensions == updated.extensions)
        }
    }

    @Test("decodes postal address and rejects not-found and malformed replies")
    func postalCodeResponse() throws {
        let data = Data(#"{"cep":"00000-000","logradouro":"Rua Sintética","bairro":"Bairro Exemplo","localidade":"Cidade Sintética","uf":"SP"}"#.utf8)
        #expect(try PostalCodeLookup.decode(data)["street"] == "Rua Sintética")
        #expect(throws: (any Error).self) { try PostalCodeLookup.decode(Data(#"{"erro":true}"#.utf8)) }
        #expect(throws: (any Error).self) { try PostalCodeLookup.decode(Data("invalid".utf8)) }
    }

    @Test("validates the shared patient fixtures")
    func validatesFixtures() throws {
        let unnamed = try VaultManifestValidator.validatePatient(
            data: Data(contentsOf: fixtureRoot.appending(path: "valid/unnamed/patient.yaml"))
        )
        let minimal = try VaultManifestValidator.validatePatient(
            data: Data(contentsOf: fixtureRoot.appending(path: "valid/minimal/patient.yaml"))
        )
        let complete = try VaultManifestValidator.validatePatient(
            data: Data(contentsOf: fixtureRoot.appending(path: "valid/complete/patient.yaml"))
        )
        #expect(unnamed.fullName == nil)
        #expect(minimal.fullName == "Ana Fictícia")
        #expect(complete.contacts.count == 2)
        #expect(complete.extensions["x_fixture_note"] == .string("preserved"))
    }

    @Test("creates, closes and reopens the same registered patient bytes")
    func createsAndReopensRegisteredPatient() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let created = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: completeInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let manifestURL = created.url.appending(path: "patient.yaml")
            let bytes = try Data(contentsOf: manifestURL)
            let reopened = try VaultReader().open(vault.url)
            let patient = try #require(reopened.patients.first)
            #expect(patient.record?.fullName == "Ágata Sintética")
            #expect(patient.record?.preferredName == "Gata")
            #expect(patient.record?.contacts.count == 2)
            #expect(try Data(contentsOf: manifestURL) == bytes)
        }
    }

    @Test("does not publish a partial registered patient")
    func registeredCreationFailureIsAtomic() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let creator = PatientCreator(faultInjector: { step in
                if step == .manifestWritten { throw SyntheticPatientFailure() }
            })
            do {
                _ = try creator.createRegistered(
                    in: vault.url,
                    identity: PatientCreationIdentity(patientID: patientID),
                    input: minimalInput,
                    createdAt: timestamp("2026-08-31T18:00:00Z")
                )
                Issue.record("a criação parcial deveria falhar")
            } catch is SyntheticPatientFailure {
                let patientsURL = vault.url.appending(path: "patients")
                #expect(!FileManager.default.fileExists(atPath: patientsURL.appending(path: patientID).path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: patientsURL.path).isEmpty)
            }
        }
    }

    @Test("isolates an invalid registered patient and keeps another available")
    func isolatesInvalidRegisteredPatient() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            _ = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: minimalInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let invalidID = "pt_0198f5c2-0000-7000-8000-000000000002"
            let invalid = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: invalidID),
                input: minimalInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let manifestURL = invalid.url.appending(path: "patient.yaml")
            let broken = try String(contentsOf: manifestURL, encoding: .utf8)
                .replacingOccurrences(of: "full_name: \"Nome Sintético\"\n", with: "")
            try Data(broken.utf8).write(to: manifestURL, options: [.atomic])

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients.map(\.patientID) == [patientID])
            #expect(reopened.unavailablePatients.map(\.patientID) == [invalidID])
            #expect(reopened.writingAllowed)
        }
    }

    @Test("edits atomically and preserves namespaced extensions")
    func editsAndPreservesExtension() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let created = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: completeInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let manifestURL = created.url.appending(path: "patient.yaml")
            var seeded = try String(contentsOf: manifestURL, encoding: .utf8)
            seeded += "x_owner_note: {\"kept\":[true,1]}\n"
            try Data(seeded.utf8).write(to: manifestURL, options: [.atomic])
            let seededPatient = try #require(VaultReader().open(vault.url).patients.first)
            let beforeFailure = try Data(contentsOf: manifestURL)
            let failing = PatientEditor(faultInjector: { step in
                if step == .temporaryManifestWritten { throw SyntheticPatientFailure() }
            })
            do {
                _ = try failing.update(
                    patient: seededPatient,
                    input: minimalInput,
                    updatedAt: timestamp("2026-08-31T19:00:00Z")
                )
                Issue.record("a falha injetada deveria interromper a edição")
            } catch is SyntheticPatientFailure {
                #expect(try Data(contentsOf: manifestURL) == beforeFailure)
            }

            let updated = try PatientEditor().update(
                patient: seededPatient,
                input: minimalInput,
                updatedAt: timestamp("2026-08-31T19:00:00Z")
            )
            #expect(updated.fullName == "Nome Sintético")
            #expect(updated.extensions["x_owner_note"] == .mapping([
                "kept": .sequence([.boolean(true), .integer(1)]),
            ]))
            #expect(try VaultReader().open(vault.url).patients.first?.record == updated)
        }
    }

    @Test("archives and reactivates without removing patient content")
    func archivesAndReactivates() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let created = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: minimalInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let contentURL = created.url.appending(path: "content")
            let archived = try PatientEditor().update(
                patient: created,
                input: minimalInput,
                status: .archived,
                updatedAt: timestamp("2026-08-31T19:00:00Z")
            )
            #expect(archived.archivedAt == "2026-08-31T19:00:00Z")
            #expect(FileManager.default.fileExists(atPath: contentURL.path))
            let archivedSummary = try #require(VaultReader().open(vault.url).patients.first)
            let active = try PatientEditor().update(
                patient: archivedSummary,
                input: minimalInput,
                status: .active,
                updatedAt: timestamp("2026-08-31T20:00:00Z")
            )
            #expect(active.archivedAt == nil)
            #expect(FileManager.default.fileExists(atPath: contentURL.path))
        }
    }

    @Test("finds accents, preferred names, homonyms and incomplete fields")
    func searchesAndDetectsDuplicates() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: completeInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            #expect(PatientSearch.matches(patient, query: "agata"))
            #expect(PatientSearch.matches(patient, query: "GATA"))
            #expect(PatientSearch.matches(patient, query: "pt_0198"))
            #expect(PatientSearch.matches(patient, query: "529.982.247-25"))
            #expect(PatientSearch.matches(patient, query: "52998224725"))
            #expect(!PatientSearch.matches(patient, query: "outro"))
            #expect(PatientDuplicateDetector.candidates(
                for: PatientRecordInput(
                    fullName: "  agata   sintetica ",
                    preferredName: nil,
                    birthDate: "2000-02-29",
                    contacts: [],
                    identifiers: [],
                    alerts: []
                ),
                among: [patient]
            ).map(\.patientID) == [patientID])
            #expect(PatientDuplicateDetector.candidates(
                for: PatientRecordInput(
                    fullName: "Outra Pessoa Sintética",
                    preferredName: nil,
                    birthDate: nil,
                    contacts: [],
                    identifiers: [PatientIdentifier(type: .cpf, value: "529.982.247-25")],
                    alerts: []
                ),
                among: [patient]
            ).map(\.patientID) == [patientID])
        }
    }

    @Test("ignores regular Finder metadata without weakening symbolic-link checks")
    func finderMetadataIsTolerated() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: minimalInput,
                createdAt: timestamp("2026-08-31T18:00:00Z")
            )
            let metadataDirectories = [
                vault.url,
                vault.url.appending(path: "appointments"),
                patient.url,
                patient.url.appending(path: ".openpep"),
                patient.url.appending(path: "content"),
                patient.url.appending(path: "raw"),
                patient.url.appending(path: "wiki"),
            ]
            for directory in metadataDirectories {
                try Data("Finder metadata".utf8).write(to: directory.appending(path: ".DS_Store"))
            }

            let reopened = try VaultReader().open(vault.url)
            #expect(reopened.patients.map(\.patientID) == [patientID])
            #expect(reopened.unavailablePatients.isEmpty)
            #expect(reopened.unmanagedPaths.isEmpty)
            #expect(reopened.writingAllowed)

            try FileManager.default.removeItem(at: patient.url.appending(path: ".DS_Store"))
            try FileManager.default.createSymbolicLink(
                at: patient.url.appending(path: ".DS_Store"),
                withDestinationURL: patient.url.appending(path: "patient.yaml")
            )
            let withUnsafeMetadata = try VaultReader().open(vault.url)
            #expect(withUnsafeMetadata.patients.isEmpty)
            #expect(withUnsafeMetadata.unavailablePatients.map(\.patientID) == [patientID])
        }
    }

    @Test("creates and reopens a patient without entered fields")
    func createsUnnamedPatient() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let created = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: PatientRecordInput(
                    fullName: "",
                    preferredName: nil,
                    birthDate: nil,
                    contacts: [],
                    identifiers: [],
                    alerts: []
                ),
                createdAt: timestamp("2026-09-02T12:00:00Z")
            )

            #expect(created.record?.fullName == nil)
            #expect(created.displayName == "Paciente sem nome")
            let reopened = try #require(VaultReader().open(vault.url).patients.first)
            #expect(reopened.record?.fullName == nil)
            #expect(PatientSearch.matches(reopened, query: patientID))
        }
    }

    @Test("converts Brazilian display dates without changing the stored format")
    func convertsPatientDates() {
        #expect(PatientDateText.displayValue(fromStorage: "2026-09-02") == "02/09/2026")
        #expect(PatientDateText.storageValue(fromDisplay: "02/09/2026") == "2026-09-02")
        #expect(PatientDateText.storageValue(fromDisplay: "31/02/2026") == nil)
        #expect(PatientDateText.isValidDisplayValue(""))
        #expect(!PatientDateText.isValidDisplayValue("2026-09-02"))
    }

    @Test("formats assisted patient fields from typing and paste")
    func formatsAssistedPatientFields() {
        #expect(PatientInputText.date("02092026") == "02/09/2026")
        #expect(PatientInputText.date("02-09-2026") == "02/09/2026")
        #expect(PatientInputText.cpf("52998224725") == "529.982.247-25")
        #expect(PatientInputText.cpf("529.982.247-25 extra") == "529.982.247-25")
        #expect(PatientInputText.brazilianPhone("1133334444") == "(11) 3333-4444")
        #expect(PatientInputText.brazilianPhone("11999994444") == "(11) 99999-4444")
        #expect(PatientInputText.brazilianPhone("119999") == "(11) 9999")
    }

    @Test("validates CPF check digits and repeated sequences")
    func validatesCPFStructure() {
        #expect(PatientCPF.isStructurallyValid("529.982.247-25"))
        #expect(!PatientCPF.isStructurallyValid("529.982.247-24"))
        #expect(!PatientCPF.isStructurallyValid("111.111.111-11"))
        #expect(!PatientCPF.isStructurallyValid("529.982"))
    }

    @Test("derives age at the birthday boundary without persisting it")
    func derivesAge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let beforeBirthday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 3,
            hour: 12
        )))
        let birthday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 12
        )))

        #expect(PatientAge.years(
            fromStorage: "2000-09-04",
            on: beforeBirthday,
            calendar: calendar
        ) == 25)
        #expect(PatientAge.years(
            fromStorage: "2000-09-04",
            on: birthday,
            calendar: calendar
        ) == 26)
        #expect(PatientAge.years(
            fromStorage: "2030-01-01",
            on: birthday,
            calendar: calendar
        ) == nil)
    }

    @Test("separates Brazilian country code without rewriting other countries")
    func formatsPhoneCountry() {
        #expect(PatientPhoneText.brazilianNumber(fromStorage: "+55 11 99999-4444") == "(11) 99999-4444")
        #expect(PatientPhoneText.brazilianNumber(fromStorage: "(11) 3333-4444") == "(11) 3333-4444")
        #expect(PatientPhoneText.brazilianNumber(fromStorage: "+351 210 000 000") == nil)
        #expect(PatientPhoneText.storageValue(fromBrazilianNumber: "11999994444") == "+55 (11) 99999-4444")
        #expect(PatientPhoneText.storageValue(fromBrazilianNumber: "") == "")
    }

    private var minimalInput: PatientRecordInput {
        PatientRecordInput(
            fullName: "Nome Sintético",
            preferredName: nil,
            birthDate: nil,
            contacts: [],
            identifiers: [],
            alerts: []
        )
    }

    private var completeInput: PatientRecordInput {
        PatientRecordInput(
            fullName: "Ágata Sintética",
            preferredName: "Gata",
            birthDate: "2000-02-29",
            contacts: [
                PatientContact(type: .phone, value: "+55 00 90000-0000", authorizedForCare: true),
                PatientContact(type: .email, value: "agata@example.invalid", authorizedForCare: false),
            ],
            identifiers: [PatientIdentifier(type: .cpf, value: "52998224725")],
            alerts: [PatientAlert(
                type: .allergy,
                description: "Alergia sintética",
                source: "Relato sintético",
                recordedAt: "2026-08-31T18:00:00Z"
            )]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureRoot: URL {
        repositoryRoot.appending(path: "fixtures/patient-v1")
    }

    private func timestamp(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-patient-tests-\(UUID().uuidString)",
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
            createdAt: timestamp("2026-08-31T17:00:00Z")
        )
    }
}

private struct SyntheticPatientFailure: Error {}
