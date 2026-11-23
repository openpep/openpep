// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum AppointmentModality: String, Equatable, Sendable, CaseIterable {
    case inPerson = "in_person"
    case telemedicine
}

enum AppointmentStatus: String, Equatable, Sendable, CaseIterable {
    case scheduled
    case arrived
    case inProgress = "in_progress"
    case completed
    case cancelled
    case noShow = "no_show"
}

struct AppointmentRecord: Equatable, Sendable {
    let schema: String
    let appointmentID: String
    let patientID: String
    let startsAt: String
    let endsAt: String
    let timeZone: String
    let modality: AppointmentModality
    let status: AppointmentStatus
    let location: String?
    let remoteAccessURL: String?
    let administrativeNote: String?
    let encounterID: String?
    let createdAt: String
    let updatedAt: String
    let extensions: [String: YAMLValue]

    var startDate: Date { appointmentDate(startsAt) ?? .distantPast }
    var endDate: Date { appointmentDate(endsAt) ?? .distantPast }

    var telemedicineConsentConfirmed: Bool {
        modality == .telemedicine && extensions["x_openpep_telemedicine_consent"] == .string("confirmed")
    }
}

struct AppointmentSummary: Equatable, Sendable, Identifiable {
    let record: AppointmentRecord
    let url: URL

    var id: String { record.appointmentID }
}

struct UnavailableAppointmentSummary: Equatable, Sendable, Identifiable {
    let appointmentID: String?
    let relativePath: String
    let rule: String

    var id: String { relativePath }
}

struct AppointmentInput: Equatable, Sendable {
    let patientID: String
    let startsAt: Date
    let endsAt: Date
    let timeZone: String
    let modality: AppointmentModality
    let status: AppointmentStatus
    let location: String?
    let remoteAccessURL: String?
    let administrativeNote: String?
    var telemedicineConsentConfirmed: Bool = false

    func normalized() -> AppointmentInput {
        AppointmentInput(
            patientID: patientID,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZone: timeZone,
            modality: modality,
            status: status,
            location: modality == .inPerson ? normalizedOptional(location) : nil,
            remoteAccessURL: modality == .telemedicine ? normalizedOptional(remoteAccessURL) : nil,
            administrativeNote: normalizedOptional(administrativeNote),
            telemedicineConsentConfirmed: modality == .telemedicine && telemedicineConsentConfirmed
        )
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

struct AppointmentCreationIdentity: Equatable, Sendable {
    let appointmentID: String

    static func generate(at date: Date = Date()) throws -> AppointmentCreationIdentity {
        AppointmentCreationIdentity(appointmentID: "appt_\(try UUIDv7.generate(at: date))")
    }
}

enum AppointmentWriteStep: Equatable, Sendable {
    case temporaryWritten
    case destinationPublished
}

struct AppointmentWriter {
    typealias FaultInjector = (AppointmentWriteStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func create(
        in vaultURL: URL,
        patient: PatientSummary,
        identity: AppointmentCreationIdentity,
        input: AppointmentInput,
        createdAt: Date = Date()
    ) throws -> AppointmentSummary {
        guard OpenPEPIdentifier.isAppointment(identity.appointmentID) else {
            throw appointmentIssue("appointment.invalid_id", identity.appointmentID, "O appointment_id não é seguro.")
        }
        guard patient.record?.status == .active, patient.patientID == input.patientID else {
            throw appointmentIssue("appointment.patient_unavailable", input.patientID, "O paciente deve estar cadastrado e ativo.")
        }
        let normalized = input.normalized()
        let timestamp = appointmentTimestamp(createdAt)
        let record = AppointmentRecord(
            schema: "openpep/appointment@1",
            appointmentID: identity.appointmentID,
            patientID: normalized.patientID,
            startsAt: appointmentTimestamp(normalized.startsAt),
            endsAt: appointmentTimestamp(normalized.endsAt),
            timeZone: normalized.timeZone,
            modality: normalized.modality,
            status: normalized.status,
            location: normalized.location,
            remoteAccessURL: normalized.remoteAccessURL,
            administrativeNote: normalized.administrativeNote,
            encounterID: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            extensions: normalized.telemedicineConsentConfirmed
                ? ["x_openpep_telemedicine_consent": .string("confirmed")] : [:]
        )
        return try coordinatedWrite(record, vaultURL: vaultURL, replacing: nil)
    }

    func update(
        _ appointment: AppointmentSummary,
        in vaultURL: URL,
        patients: [PatientSummary],
        input: AppointmentInput,
        updatedAt: Date = Date()
    ) throws -> AppointmentSummary {
        let normalized = input.normalized()
        guard patients.contains(where: {
            $0.patientID == normalized.patientID && $0.record?.status == .active
        }) else {
            throw appointmentIssue("appointment.patient_unavailable", normalized.patientID, "O paciente deve estar cadastrado e ativo.")
        }
        let current = appointment.record
        if current.encounterID != nil,
           (normalized.patientID != current.patientID || normalized.modality != current.modality) {
            throw appointmentIssue(
                "appointment.linked_identity",
                current.appointmentID,
                "Paciente e modalidade não podem mudar depois do início da consulta."
            )
        }
        if current.encounterID != nil, let existing = current.remoteAccessURL,
           normalized.remoteAccessURL != existing {
            throw appointmentIssue("appointment.linked_remote_url", current.appointmentID,
                "O link já está vinculado à consulta e não pode ser substituído.")
        }
        var extensions = current.extensions
        if current.encounterID == nil {
            extensions["x_openpep_telemedicine_consent"] = .string(
                normalized.telemedicineConsentConfirmed ? "confirmed" : "not_recorded"
            )
        }
        let record = AppointmentRecord(
            schema: current.schema,
            appointmentID: current.appointmentID,
            patientID: normalized.patientID,
            startsAt: appointmentTimestamp(normalized.startsAt),
            endsAt: appointmentTimestamp(normalized.endsAt),
            timeZone: normalized.timeZone,
            modality: normalized.modality,
            status: normalized.status,
            location: normalized.location,
            remoteAccessURL: normalized.remoteAccessURL,
            administrativeNote: normalized.administrativeNote,
            encounterID: current.encounterID,
            createdAt: current.createdAt,
            updatedAt: appointmentTimestamp(updatedAt),
            extensions: extensions
        )
        return try coordinatedWrite(
            record,
            vaultURL: vaultURL,
            replacing: appointment.url,
            expectedRecord: current
        )
    }

    func cancel(
        _ appointment: AppointmentSummary,
        in vaultURL: URL,
        patients: [PatientSummary],
        updatedAt: Date = Date()
    ) throws -> AppointmentSummary {
        let record = appointment.record
        guard record.encounterID == nil,
              !patients.flatMap(\.encounters).contains(where: {
                  $0.metadata.appointmentID == appointment.id
              }) else {
            throw appointmentIssue(
                "appointment.encounter_started",
                record.appointmentID,
                "O agendamento não pode ser cancelado depois do início da consulta."
            )
        }
        return try update(
            appointment,
            in: vaultURL,
            patients: patients,
            input: AppointmentInput(
                patientID: record.patientID,
                startsAt: record.startDate,
                endsAt: record.endDate,
                timeZone: record.timeZone,
                modality: record.modality,
                status: .cancelled,
                location: record.location,
                remoteAccessURL: record.remoteAccessURL,
                administrativeNote: record.administrativeNote,
                telemedicineConsentConfirmed: record.telemedicineConsentConfirmed
            ),
            updatedAt: updatedAt
        )
    }

    func restoreCancelled(
        _ appointment: AppointmentSummary,
        expectedCurrentRecord: AppointmentRecord,
        previousStatus: AppointmentStatus,
        in vaultURL: URL,
        patients: [PatientSummary],
        restoredAt: Date = Date()
    ) throws -> AppointmentSummary {
        guard appointment.record == expectedCurrentRecord,
              expectedCurrentRecord.appointmentID == appointment.id,
              expectedCurrentRecord.status == .cancelled,
              previousStatus != .cancelled,
              expectedCurrentRecord.encounterID == nil,
              patients.contains(where: {
                  $0.patientID == expectedCurrentRecord.patientID && $0.record?.status == .active
              }),
              !patients.flatMap({ $0.encounters + $0.trashedEncounters }).contains(where: {
                  $0.metadata.appointmentID == appointment.id
              }) else {
            throw appointmentIssue(
                "appointment.restore_cancelled",
                appointment.id,
                "Somente o cancelamento atual de um agendamento sem consulta vinculada pode ser desfeito."
            )
        }
        let restored = AppointmentRecord(
            schema: expectedCurrentRecord.schema,
            appointmentID: expectedCurrentRecord.appointmentID,
            patientID: expectedCurrentRecord.patientID,
            startsAt: expectedCurrentRecord.startsAt,
            endsAt: expectedCurrentRecord.endsAt,
            timeZone: expectedCurrentRecord.timeZone,
            modality: expectedCurrentRecord.modality,
            status: previousStatus,
            location: expectedCurrentRecord.location,
            remoteAccessURL: expectedCurrentRecord.remoteAccessURL,
            administrativeNote: expectedCurrentRecord.administrativeNote,
            encounterID: nil,
            createdAt: expectedCurrentRecord.createdAt,
            updatedAt: appointmentTimestamp(restoredAt),
            extensions: expectedCurrentRecord.extensions
        )

        var outcome: Result<AppointmentSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vaultURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                let currentVault = try VaultReader(fileManager: fileManager)
                    .readWithinCoordinatedAccess(coordinatedVault)
                guard currentVault.writingAllowed,
                      let liveAppointment = currentVault.appointments.first(where: { $0.id == appointment.id }),
                      liveAppointment.record == expectedCurrentRecord,
                      liveAppointment.url.standardizedFileURL == appointment.url.standardizedFileURL,
                      currentVault.patients.contains(where: {
                          $0.patientID == expectedCurrentRecord.patientID && $0.record?.status == .active
                      }),
                      !currentVault.patients.flatMap({ $0.encounters + $0.trashedEncounters }).contains(where: {
                          $0.metadata.appointmentID == appointment.id
                      }) else {
                    throw appointmentIssue(
                        "appointment.revision_conflict",
                        appointment.url.path,
                        "O agendamento ou seus vínculos mudaram. Reabra antes de desfazer."
                    )
                }
                outcome = .success(try writeUncoordinated(
                    restored,
                    vaultURL: coordinatedVault,
                    replacing: liveAppointment.url,
                    expectedRecord: expectedCurrentRecord
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw appointmentIssue("filesystem.coordination", vaultURL.path, "A restauração coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    func recordRemoteHandoff(
        _ appointment: AppointmentSummary,
        method: TelemedicineHandoffMethod,
        in vaultURL: URL,
        requestedAt: Date = Date()
    ) throws -> AppointmentSummary {
        let current = appointment.record
        guard current.modality == .telemedicine else {
            throw appointmentIssue(
                "telemedicine.in_person_appointment",
                current.appointmentID,
                "O handoff remoto exige um agendamento de teleconsulta."
            )
        }
        if method == .savedLink, current.remoteAccessURL == nil {
            throw appointmentIssue(
                "telemedicine.missing_link",
                current.appointmentID,
                "O agendamento não possui link remoto salvo."
            )
        }
        var extensions = current.extensions
        extensions["x_last_remote_handoff_requested_at"] = .string(appointmentTimestamp(requestedAt))
        extensions["x_last_remote_handoff_method"] = .string(method.rawValue)
        let record = AppointmentRecord(
            schema: current.schema,
            appointmentID: current.appointmentID,
            patientID: current.patientID,
            startsAt: current.startsAt,
            endsAt: current.endsAt,
            timeZone: current.timeZone,
            modality: current.modality,
            status: current.status,
            location: current.location,
            remoteAccessURL: current.remoteAccessURL,
            administrativeNote: current.administrativeNote,
            encounterID: current.encounterID,
            createdAt: current.createdAt,
            updatedAt: appointmentTimestamp(requestedAt),
            extensions: extensions
        )
        return try coordinatedWrite(
            record,
            vaultURL: vaultURL,
            replacing: appointment.url,
            expectedRecord: current
        )
    }

    func linkEncounter(
        _ appointment: AppointmentSummary,
        encounterID: String,
        in vaultURL: URL,
        updatedAt: Date = Date()
    ) throws -> AppointmentSummary {
        try coordinatedWriteEncounterLink(
            appointment,
            encounterID: encounterID,
            in: vaultURL,
            updatedAt: updatedAt
        )
    }

    func linkEncounterWithinCoordinatedAccess(
        _ appointment: AppointmentSummary,
        encounterID: String,
        in vaultURL: URL,
        updatedAt: Date
    ) throws -> AppointmentSummary {
        let current = appointment.record
        guard OpenPEPIdentifier.isEncounter(encounterID) else {
            throw appointmentIssue("appointment.invalid_encounter_id", encounterID, "O encounter_id não é seguro.")
        }
        if let existing = current.encounterID, existing != encounterID {
            throw appointmentIssue(
                "appointment.encounter_conflict",
                current.appointmentID,
                "O agendamento já está ligado a outra consulta."
            )
        }
        guard ![.cancelled, .noShow, .completed].contains(current.status) else {
            throw appointmentIssue(
                "appointment.not_startable",
                current.appointmentID,
                "Este estado do agendamento não permite iniciar uma consulta."
            )
        }
        let record = AppointmentRecord(
            schema: current.schema,
            appointmentID: current.appointmentID,
            patientID: current.patientID,
            startsAt: current.startsAt,
            endsAt: current.endsAt,
            timeZone: current.timeZone,
            modality: current.modality,
            status: .inProgress,
            location: current.location,
            remoteAccessURL: current.remoteAccessURL,
            administrativeNote: current.administrativeNote,
            encounterID: encounterID,
            createdAt: current.createdAt,
            updatedAt: appointmentTimestamp(updatedAt),
            extensions: current.extensions
        )
        return try writeUncoordinated(
            record,
            vaultURL: vaultURL,
            replacing: appointment.url,
            expectedRecord: current
        )
    }

    func unlinkEncounterWithinCoordinatedAccess(
        _ appointment: AppointmentSummary,
        encounterID: String,
        in vaultURL: URL,
        updatedAt: Date
    ) throws -> AppointmentSummary {
        let current = appointment.record
        guard current.encounterID == encounterID else {
            throw appointmentIssue(
                "appointment.encounter_conflict",
                current.appointmentID,
                "O agendamento não está ligado exatamente a esta consulta."
            )
        }
        let record = AppointmentRecord(
            schema: current.schema,
            appointmentID: current.appointmentID,
            patientID: current.patientID,
            startsAt: current.startsAt,
            endsAt: current.endsAt,
            timeZone: current.timeZone,
            modality: current.modality,
            status: current.status,
            location: current.location,
            remoteAccessURL: current.remoteAccessURL,
            administrativeNote: current.administrativeNote,
            encounterID: nil,
            createdAt: current.createdAt,
            updatedAt: appointmentTimestamp(updatedAt),
            extensions: current.extensions
        )
        return try writeUncoordinated(
            record,
            vaultURL: vaultURL,
            replacing: appointment.url,
            expectedRecord: current
        )
    }

    private func coordinatedWriteEncounterLink(
        _ appointment: AppointmentSummary,
        encounterID: String,
        in vaultURL: URL,
        updatedAt: Date
    ) throws -> AppointmentSummary {
        var outcome: Result<AppointmentSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vaultURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                outcome = .success(try linkEncounterWithinCoordinatedAccess(
                    appointment,
                    encounterID: encounterID,
                    in: coordinatedVault,
                    updatedAt: updatedAt
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw appointmentIssue("filesystem.coordination", vaultURL.path, "A vinculação coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func coordinatedWrite(
        _ record: AppointmentRecord,
        vaultURL: URL,
        replacing oldURL: URL?,
        expectedRecord: AppointmentRecord? = nil
    ) throws -> AppointmentSummary {
        var outcome: Result<AppointmentSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vaultURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                outcome = .success(try writeUncoordinated(
                    record,
                    vaultURL: coordinatedVault,
                    replacing: oldURL,
                    expectedRecord: expectedRecord
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw appointmentIssue("filesystem.coordination", vaultURL.path, "A escrita coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func writeUncoordinated(
        _ record: AppointmentRecord,
        vaultURL: URL,
        replacing oldURL: URL?,
        expectedRecord: AppointmentRecord?
    ) throws -> AppointmentSummary {
        if let oldURL, let expectedRecord {
            try requireExpectedRecord(expectedRecord, at: oldURL)
        }
        let destinationDirectory = try AppointmentLayout.monthDirectory(for: record, in: vaultURL)
        try ensureDirectory(destinationDirectory, under: vaultURL)
        let destination = destinationDirectory.appending(path: "\(record.appointmentID).yaml")
        if oldURL == nil, fileManager.fileExists(atPath: destination.path) {
            throw appointmentIssue("appointment.destination_exists", destination.path, "O agendamento já existe.")
        }
        let data = try AppointmentRecordCodec.encode(record)
        let validated = try VaultManifestValidator.validateAppointment(data: data)
        let temporary = destinationDirectory.appending(path: ".openpep-appointment-\(UUID().uuidString.lowercased()).yaml")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        try faultInjector?(.temporaryWritten)

        if let oldURL, let expectedRecord {
            try requireExpectedRecord(expectedRecord, at: oldURL)
        }

        if let oldURL, oldURL.standardizedFileURL == destination.standardizedFileURL {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw appointmentIssue("appointment.destination_exists", destination.path, "O destino da remarcação já existe.")
            }
            try fileManager.moveItem(at: temporary, to: destination)
            try faultInjector?(.destinationPublished)
            if let oldURL {
                try fileManager.removeItem(at: oldURL)
            }
        }
        let reopened = try VaultManifestValidator.validateAppointment(
            data: Data(contentsOf: destination),
            source: destination.path
        )
        guard reopened == validated else {
            throw appointmentIssue("appointment.reopen_mismatch", destination.path, "O agendamento reaberto diverge da escrita validada.")
        }
        return AppointmentSummary(record: reopened, url: destination)
    }

    private func requireExpectedRecord(_ expected: AppointmentRecord, at url: URL) throws {
        let live = try VaultManifestValidator.validateAppointment(
            data: Data(contentsOf: url),
            source: url.path
        )
        guard live == expected else {
            throw appointmentIssue(
                "appointment.revision_conflict",
                url.path,
                "O agendamento mudou desde a última leitura. Reabra antes de salvar."
            )
        }
    }

    private func ensureDirectory(_ directory: URL, under vaultURL: URL) throws {
        let root = vaultURL.appending(path: "appointments", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw appointmentIssue("filesystem.directory", "appointments", "appointments deve ser diretório sem link simbólico.")
        }
        let year = directory.deletingLastPathComponent()
        for component in [year, directory] {
            if !fileManager.fileExists(atPath: component.path) {
                try fileManager.createDirectory(at: component, withIntermediateDirectories: false)
            }
            let values = try component.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw appointmentIssue("filesystem.directory", component.path, "O diretório da agenda deve ser seguro.")
            }
        }
    }
}

enum AppointmentConflictDetector {
    static func conflicts(
        for input: AppointmentInput,
        among appointments: [AppointmentSummary],
        excluding appointmentID: String? = nil
    ) -> [AppointmentSummary] {
        appointments.filter { appointment in
            let record = appointment.record
            guard record.appointmentID != appointmentID,
                  record.status != .cancelled,
                  input.endsAt > record.startDate,
                  input.startsAt < record.endDate else { return false }
            return true
        }.sorted { $0.record.startDate < $1.record.startDate }
    }
}

struct AppointmentInspector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspect(vaultURL: URL, patients: [PatientSummary]) -> (
        appointments: [AppointmentSummary],
        unavailable: [UnavailableAppointmentSummary],
        writingAllowed: Bool
    ) {
        let root = vaultURL.appending(path: "appointments", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return ([], [], true) }
        var appointments: [AppointmentSummary] = []
        var unavailable: [UnavailableAppointmentSummary] = []
        var seen = Set<String>()
        let patientIDs = Set(patients.map(\.patientID))
        do {
            guard try isSafeDirectory(root) else {
                return ([], [.init(
                    appointmentID: nil,
                    relativePath: "appointments",
                    rule: "filesystem.directory"
                )], false)
            }
            for year in try children(root) {
                guard year.lastPathComponent.range(of: "^\\d{4}$", options: .regularExpression) != nil,
                      try isSafeDirectory(year) else {
                    unavailable.append(.init(appointmentID: nil, relativePath: relative(year, root: vaultURL), rule: "appointment.invalid_year_directory"))
                    continue
                }
                for month in try children(year) {
                    guard month.lastPathComponent.range(of: "^(?:0[1-9]|1[0-2])$", options: .regularExpression) != nil,
                          try isSafeDirectory(month) else {
                        unavailable.append(.init(appointmentID: nil, relativePath: relative(month, root: vaultURL), rule: "appointment.invalid_month_directory"))
                        continue
                    }
                    for file in try children(month) {
                        let candidate = file.deletingPathExtension().lastPathComponent
                        do {
                            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard values.isRegularFile == true, values.isSymbolicLink != true,
                                  file.pathExtension == "yaml", OpenPEPIdentifier.isAppointment(candidate) else {
                                throw appointmentIssue("appointment.invalid_file", file.path, "A entrada de agenda não é segura.")
                            }
                            let record = try VaultManifestValidator.validateAppointment(data: Data(contentsOf: file), source: file.path)
                            guard record.appointmentID == candidate else {
                                throw appointmentIssue("appointment.appointment_id_mismatch", "/appointment_id", "O ID diverge do arquivo.")
                            }
                            guard patientIDs.contains(record.patientID) else {
                                throw appointmentIssue("appointment.patient_unavailable", "/patient_id", "O paciente vinculado não está disponível.")
                            }
                            let components = try AppointmentLayout.monthComponents(for: record)
                            guard components.0 == year.lastPathComponent,
                                  components.1 == month.lastPathComponent else {
                                throw appointmentIssue("appointment.path_month_mismatch", "/starts_at", "O caminho diverge do mês local.")
                            }
                            guard seen.insert(record.appointmentID).inserted else {
                                throw appointmentIssue("appointment.duplicate_id", "/appointment_id", "O ID aparece em mais de um caminho.")
                            }
                            appointments.append(AppointmentSummary(record: record, url: file))
                        } catch let issue as VaultValidationIssue {
                            unavailable.append(.init(
                                appointmentID: OpenPEPIdentifier.isAppointment(candidate) ? candidate : nil,
                                relativePath: relative(file, root: vaultURL),
                                rule: issue.rule
                            ))
                        } catch {
                            unavailable.append(.init(appointmentID: nil, relativePath: relative(file, root: vaultURL), rule: "filesystem.unreadable"))
                        }
                    }
                }
            }
        } catch {
            unavailable.append(.init(appointmentID: nil, relativePath: "appointments", rule: "filesystem.unreadable"))
        }
        appointments.sort { $0.record.startDate < $1.record.startDate }
        unavailable.sort { $0.relativePath < $1.relativePath }
        return (appointments, unavailable, !unavailable.contains { $0.relativePath == "appointments" })
    }

    private func children(_ url: URL) throws -> [URL] {
        try managedDirectoryEntries(in: url, fileManager: fileManager)
    }

    private func isSafeDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func relative(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }
}

enum AppointmentLayout {
    static func monthDirectory(for record: AppointmentRecord, in vaultURL: URL) throws -> URL {
        let components = try monthComponents(for: record)
        return vaultURL
            .appending(path: "appointments", directoryHint: .isDirectory)
            .appending(path: components.0, directoryHint: .isDirectory)
            .appending(path: components.1, directoryHint: .isDirectory)
    }

    static func monthComponents(for record: AppointmentRecord) throws -> (String, String) {
        guard let date = appointmentDate(record.startsAt),
              let timeZone = TimeZone(identifier: record.timeZone) else {
            throw appointmentIssue("appointment.invalid_time_zone", "/time_zone", "O fuso não está disponível.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            throw appointmentIssue("appointment.invalid_date", "/starts_at", "A data não pôde ser localizada.")
        }
        return (String(format: "%04d", year), String(format: "%02d", month))
    }
}

enum AppointmentRecordCodec {
    static func encode(_ record: AppointmentRecord) throws -> Data {
        var lines = [
            "schema: openpep/appointment@1",
            "appointment_id: \(record.appointmentID)",
            "patient_id: \(record.patientID)",
            "starts_at: \(try scalar(record.startsAt))",
            "ends_at: \(try scalar(record.endsAt))",
            "time_zone: \(try scalar(record.timeZone))",
            "modality: \(record.modality.rawValue)",
            "status: \(record.status.rawValue)",
            "location: \(try optionalScalar(record.location))",
            "remote_access_url: \(try optionalScalar(record.remoteAccessURL))",
            "administrative_note: \(try optionalScalar(record.administrativeNote))",
            "encounter_id: \(try optionalIdentifier(record.encounterID))",
            "created_at: \(try scalar(record.createdAt))",
            "updated_at: \(try scalar(record.updatedAt))",
        ]
        for key in record.extensions.keys.sorted() {
            guard let value = record.extensions[key] else { continue }
            lines.append("\(key): \(try yamlScalar(value))")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func optionalScalar(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try scalar(value)
    }

    private static func optionalIdentifier(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try scalar(value)
    }

    private static func scalar(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw appointmentIssue("appointment.encoding", "/", "O texto não pôde ser codificado.")
        }
        return encoded
    }

    private static func yamlScalar(_ value: YAMLValue) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: foundationValue(value),
            options: [.fragmentsAllowed, .sortedKeys]
        )
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw appointmentIssue("appointment.encoding", "/", "A extensão não pôde ser codificada.")
        }
        return encoded
    }

    private static func foundationValue(_ value: YAMLValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .boolean(value): value
        case let .integer(value): value
        case let .string(value): value
        case let .sequence(value): value.map(foundationValue)
        case let .mapping(value): value.mapValues(foundationValue)
        }
    }
}

func appointmentTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func appointmentDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func appointmentIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
