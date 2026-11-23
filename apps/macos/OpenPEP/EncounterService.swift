// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct ClinicalDraftSummary: Equatable, Sendable {
    let metadata: ClinicalDraftMetadata
    let url: URL
    let body: String
    let persistedData: Data
}

struct EncounterSummary: Equatable, Sendable {
    let metadata: EncounterMetadata
    let url: URL
    let draft: ClinicalDraftSummary
    let finalizationStatus: EncounterFinalizationStatus
}

struct ClinicalTemplateChoice: Equatable, Sendable {
    let templateID: String
    let version: String
    let body: String

    static var blank: ClinicalTemplateChoice {
        choice(id: "openpep/blank", body: "")
    }

    static var standard: ClinicalTemplateChoice {
        choice(id: "openpep/progress", body: OptionalClinicalDraftTemplate.text + "\n")
    }

    static func imported(data: Data, fileName: String) throws -> ClinicalTemplateChoice {
        guard data.count <= 512 * 1_024,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw issue(
                "clinical_template.invalid_file",
                fileName,
                "O template deve ser Markdown UTF-8 com no máximo 512 KB."
            )
        }
        let normalized = normalizeClinicalText(text)
        let safeName = fileName.precomposedStringWithCanonicalMapping
        guard !safeName.isEmpty, safeName.count <= 200 else {
            throw issue("clinical_template.invalid_name", fileName, "O nome do template não é válido.")
        }
        return choice(id: "file/\(safeName)", body: normalized)
    }

    private static func choice(id: String, body: String) -> ClinicalTemplateChoice {
        let normalized = normalizeClinicalText(body)
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return ClinicalTemplateChoice(
            templateID: id,
            version: "sha256:\(digest)",
            body: normalized
        )
    }
}

struct TelemedicineEncounterInput: Equatable, Sendable {
    let consent: TelemedicineConsent
    let declaredLocation: String?
    let participants: [String]
    let limitations: String?
    let contingency: String?

    func normalized() -> TelemedicineEncounterInput {
        TelemedicineEncounterInput(
            consent: consent,
            declaredLocation: normalizedClinicalFact(declaredLocation),
            participants: Array(Set(participants.compactMap {
                normalizedClinicalFact($0)
            })).sorted(),
            limitations: normalizedClinicalFact(limitations),
            contingency: normalizedClinicalFact(contingency)
        )
    }
}

struct EncounterStartInput: Equatable, Sendable {
    let modality: AppointmentModality
    let template: ClinicalTemplateChoice
    let telemedicine: TelemedicineEncounterInput?

    static func scheduled(_ record: AppointmentRecord) -> Self {
        Self(modality: record.modality, template: .blank,
             telemedicine: record.modality == .telemedicine ? TelemedicineEncounterInput(
                consent: record.telemedicineConsentConfirmed ? .confirmed : .notRecorded,
                declaredLocation: nil, participants: [], limitations: nil, contingency: nil
             ) : nil)
    }
}

struct EncounterStartResult: Equatable, Sendable {
    let encounter: EncounterSummary
    let appointment: AppointmentSummary?
    let recoveredPendingLink: Bool
}

struct ClinicalDraftCreationIdentity: Equatable, Sendable {
    let encounterID: String
    let noteID: String
    let syntheticActorID: String

    static func generate(at date: Date = Date()) throws -> ClinicalDraftCreationIdentity {
        ClinicalDraftCreationIdentity(
            encounterID: "enc_\(try UUIDv7.generate(at: date))",
            noteID: "note_\(try UUIDv7.generate(at: date))",
            syntheticActorID: "usr_\(try UUIDv7.generate(at: date))"
        )
    }
}

enum ClinicalDraftCreationStep: Equatable, Sendable {
    case temporaryFilesWritten
    case encounterPublished
}

struct ClinicalDraftCreator {
    typealias FaultInjector = (ClinicalDraftCreationStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func create(
        in patient: PatientSummary,
        identity: ClinicalDraftCreationIdentity,
        startedAt: Date
    ) throws -> EncounterSummary {
        guard OpenPEPIdentifier.isPatient(patient.patientID),
              OpenPEPIdentifier.isEncounter(identity.encounterID),
              OpenPEPIdentifier.isNote(identity.noteID),
              OpenPEPIdentifier.isUser(identity.syntheticActorID) else {
            throw issue("clinical_document.invalid_id", patient.patientID, "Um ID do atendimento não é seguro.")
        }

        let contentURL = patient.url.appending(path: "content", directoryHint: .isDirectory)
        var outcome: Result<EncounterSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: contentURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedContent in
            do {
                outcome = .success(try createUncoordinated(
                    in: coordinatedContent,
                    patientID: patient.patientID,
                    identity: identity,
                    startedAt: startedAt,
                    appointmentID: nil,
                    input: nil
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", contentURL.path, "A criação coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    func create(
        in patient: PatientSummary,
        identity: ClinicalDraftCreationIdentity,
        appointmentID: String?,
        input: EncounterStartInput,
        startedAt: Date
    ) throws -> EncounterSummary {
        if let appointmentID, !OpenPEPIdentifier.isAppointment(appointmentID) {
            throw issue("clinical_document.invalid_id", appointmentID, "O appointment_id não é seguro.")
        }
        if input.modality == .telemedicine, input.telemedicine == nil {
            throw issue(
                "clinical_document.telemedicine_required",
                "/telemedicine",
                "A teleconsulta exige o registro explícito dos fatos declarados."
            )
        }
        if input.modality == .inPerson, input.telemedicine != nil {
            throw issue(
                "clinical_document.telemedicine_forbidden",
                "/telemedicine",
                "Uma consulta presencial não aceita metadados de teleconsulta."
            )
        }
        guard OpenPEPIdentifier.isPatient(patient.patientID),
              OpenPEPIdentifier.isEncounter(identity.encounterID),
              OpenPEPIdentifier.isNote(identity.noteID),
              OpenPEPIdentifier.isUser(identity.syntheticActorID) else {
            throw issue("clinical_document.invalid_id", patient.patientID, "Um ID do atendimento não é seguro.")
        }

        let contentURL = patient.url.appending(path: "content", directoryHint: .isDirectory)
        var outcome: Result<EncounterSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: contentURL, options: .forMerging, error: &coordinationError) {
            coordinatedContent in
            do {
                outcome = .success(try createUncoordinated(
                    in: coordinatedContent,
                    patientID: patient.patientID,
                    identity: identity,
                    startedAt: startedAt,
                    appointmentID: appointmentID,
                    input: input
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", contentURL.path, "A criação coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func createUncoordinated(
        in contentURL: URL,
        patientID: String,
        identity: ClinicalDraftCreationIdentity,
        startedAt: Date,
        appointmentID: String?,
        input: EncounterStartInput?
    ) throws -> EncounterSummary {
        _ = try ClinicalContentInspector(fileManager: fileManager).inspect(
            contentURL: contentURL,
            patientID: patientID
        )
        let encountersURL = contentURL.appending(path: "encounters", directoryHint: .isDirectory)
        let notesURL = contentURL.appending(path: "notes", directoryHint: .isDirectory)
        let draftsURL = notesURL.appending(path: "drafts", directoryHint: .isDirectory)
        let encounterURL = encountersURL.appending(path: "\(identity.encounterID).md")
        let draftURL = draftsURL.appending(path: "\(identity.noteID).md")
        guard !fileManager.fileExists(atPath: encounterURL.path),
              !fileManager.fileExists(atPath: draftURL.path) else {
            throw issue("clinical_document.destination_exists", identity.encounterID, "O atendimento já existe.")
        }

        var createdDirectories: [URL] = []
        for directory in [encountersURL, notesURL, draftsURL] where !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectories.append(directory)
        }

        let token = UUID().uuidString.lowercased()
        let temporaryEncounter = encountersURL.appending(path: ".openpep-encounter-\(token)")
        let temporaryDraft = draftsURL.appending(path: ".openpep-draft-\(token)")
        var completed = false
        var encounterPublished = false
        var draftPublished = false
        defer {
            if !completed, draftPublished, fileManager.fileExists(atPath: draftURL.path) {
                try? fileManager.removeItem(at: draftURL)
            }
            if !completed, encounterPublished, fileManager.fileExists(atPath: encounterURL.path) {
                try? fileManager.removeItem(at: encounterURL)
            }
            for temporary in [temporaryEncounter, temporaryDraft]
                where fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            if !completed {
                for directory in createdDirectories.reversed() {
                    if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                        try? fileManager.removeItem(at: directory)
                    }
                }
            }
        }

        let timestamp = utcTimestamp(startedAt)
        let encounterData = Data(encounterText(
            patientID: patientID,
            identity: identity,
            timestamp: timestamp,
            appointmentID: appointmentID,
            input: input
        ).utf8)
        let draftData = Data(draftText(
            patientID: patientID,
            identity: identity,
            timestamp: timestamp,
            body: input?.template.body ?? "Texto clínico sintético para desenvolvimento.\n"
        ).utf8)
        try encounterData.write(to: temporaryEncounter, options: [.withoutOverwriting])
        try draftData.write(to: temporaryDraft, options: [.withoutOverwriting])
        let encounterMetadata = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: temporaryEncounter),
            source: encounterURL.path
        )
        let draftDocument = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: temporaryDraft),
            source: draftURL.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: encounterMetadata,
            draft: draftDocument.metadata,
            expectedPatientID: patientID
        )
        try faultInjector?(.temporaryFilesWritten)

        try fileManager.moveItem(at: temporaryEncounter, to: encounterURL)
        encounterPublished = true
        try faultInjector?(.encounterPublished)
        try fileManager.moveItem(at: temporaryDraft, to: draftURL)
        draftPublished = true

        let result = try ClinicalContentInspector(fileManager: fileManager)
            .inspect(contentURL: contentURL, patientID: patientID)
            .first(where: { $0.metadata.encounterID == identity.encounterID })
            ?? { throw issue("clinical_document.reopen", identity.encounterID, "O atendimento não pôde ser relido.") }()
        completed = true
        return result
    }

    private func encounterText(
        patientID: String,
        identity: ClinicalDraftCreationIdentity,
        timestamp: String,
        appointmentID: String?,
        input: EncounterStartInput?
    ) -> String {
        var lines = [
            "schema: openpep/encounter@1",
            "encounter_id: \(identity.encounterID)",
            "patient_id: \(patientID)",
            "appointment_id: \(appointmentID.map { yamlQuoted($0) } ?? "null")",
            "status: in_progress",
            "modality: \(input?.modality.rawValue ?? AppointmentModality.inPerson.rawValue)",
            "started_at: \(yamlQuoted(timestamp))",
            "ended_at: null",
            "created_by: \(identity.syntheticActorID)",
        ]
        if let input {
            lines.append("template_id: \(yamlQuoted(input.template.templateID))")
            lines.append("template_version: \(yamlQuoted(input.template.version))")
            if let telemedicine = input.telemedicine?.normalized() {
                lines.append("telemedicine:")
                lines.append("  consent: \(telemedicine.consent.rawValue)")
                lines.append("  declared_location: \(telemedicine.declaredLocation.map(yamlQuoted) ?? "null")")
                if telemedicine.participants.isEmpty {
                    lines.append("  participants: []")
                } else {
                    lines.append("  participants:")
                    lines.append(contentsOf: telemedicine.participants.map { "    - \(yamlQuoted($0))" })
                }
                lines.append("  limitations: \(telemedicine.limitations.map(yamlQuoted) ?? "null")")
                lines.append("  contingency: \(telemedicine.contingency.map(yamlQuoted) ?? "null")")
            } else {
                lines.append("telemedicine: null")
            }
        }
        lines.append("x_actor_assurance: synthetic_unauthenticated")
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    private func draftText(
        patientID: String,
        identity: ClinicalDraftCreationIdentity,
        timestamp: String,
        body: String
    ) -> String {
        let frontmatter = """
        schema: openpep/clinical-note@1
        note_id: \(identity.noteID)
        patient_id: \(patientID)
        encounter_id: \(identity.encounterID)
        status: draft
        note_type: progress
        author_id: \(identity.syntheticActorID)
        created_at: "\(timestamp)"
        updated_at: "\(timestamp)"
        source_ids: []
        ai_assistance:
          used: false
          generation_id: null
          reviewed_by: null
        finalization: null
        x_actor_assurance: synthetic_unauthenticated
        """
        return "---\n" + frontmatter + "\n---\n\n" + body
    }
}

struct EncounterStartService {
    private let creator: ClinicalDraftCreator
    private let appointmentWriter: AppointmentWriter

    init(
        fileManager: FileManager = .default,
        encounterFaultInjector: ClinicalDraftCreator.FaultInjector? = nil,
        appointmentFaultInjector: AppointmentWriter.FaultInjector? = nil
    ) {
        creator = ClinicalDraftCreator(fileManager: fileManager, faultInjector: encounterFaultInjector)
        appointmentWriter = AppointmentWriter(fileManager: fileManager, faultInjector: appointmentFaultInjector)
    }

    func start(
        in vault: VaultSummary,
        patient: PatientSummary,
        appointment: AppointmentSummary?,
        identity: ClinicalDraftCreationIdentity,
        input: EncounterStartInput,
        startedAt: Date
    ) throws -> EncounterStartResult {
        guard vault.writingAllowed,
              patient.record?.status == .active,
              vault.patients.contains(where: { $0.patientID == patient.patientID }) else {
            throw issue(
                "clinical_document.patient_unavailable",
                patient.patientID,
                "A consulta exige um paciente cadastrado, ativo e gravável."
            )
        }

        guard let appointment else {
            let encounter = try creator.create(
                in: patient,
                identity: identity,
                appointmentID: nil,
                input: input,
                startedAt: startedAt
            )
            return EncounterStartResult(
                encounter: encounter,
                appointment: nil,
                recoveredPendingLink: false
            )
        }

        try validate(appointment: appointment, patient: patient, input: input)
        if let linkedID = appointment.record.encounterID {
            guard let encounter = patient.encounters.first(where: {
                $0.metadata.encounterID == linkedID
                    && $0.metadata.appointmentID == appointment.id
                    && $0.metadata.modality == appointment.record.modality.rawValue
            }) else {
                throw issue(
                    "clinical_document.appointment_binding",
                    appointment.id,
                    "O agendamento aponta para uma consulta ausente ou divergente."
                )
            }
            return EncounterStartResult(
                encounter: encounter,
                appointment: appointment,
                recoveredPendingLink: false
            )
        }

        if let pending = patient.encounters.first(where: {
            $0.metadata.appointmentID == appointment.id
        }) {
            guard pending.metadata.modality == appointment.record.modality.rawValue else {
                throw issue(
                    "clinical_document.appointment_modality",
                    appointment.id,
                    "A consulta pendente diverge da modalidade do agendamento."
                )
            }
            let linked = try appointmentWriter.linkEncounter(
                appointment,
                encounterID: pending.metadata.encounterID,
                in: vault.url,
                updatedAt: startedAt
            )
            return EncounterStartResult(
                encounter: pending,
                appointment: linked,
                recoveredPendingLink: true
            )
        }

        let encounter = try creator.create(
            in: patient,
            identity: identity,
            appointmentID: appointment.id,
            input: input,
            startedAt: startedAt
        )
        let linked = try appointmentWriter.linkEncounter(
            appointment,
            encounterID: encounter.metadata.encounterID,
            in: vault.url,
            updatedAt: startedAt
        )
        return EncounterStartResult(
            encounter: encounter,
            appointment: linked,
            recoveredPendingLink: false
        )
    }

    private func validate(
        appointment: AppointmentSummary,
        patient: PatientSummary,
        input: EncounterStartInput
    ) throws {
        guard appointment.record.patientID == patient.patientID else {
            throw issue(
                "clinical_document.appointment_patient",
                appointment.id,
                "O agendamento pertence a outro paciente."
            )
        }
        guard appointment.record.modality == input.modality else {
            throw issue(
                "clinical_document.appointment_modality",
                appointment.id,
                "A modalidade da consulta diverge do agendamento."
            )
        }
        guard ![.cancelled, .noShow, .completed].contains(appointment.record.status) else {
            throw issue(
                "clinical_document.appointment_state",
                appointment.id,
                "Este estado do agendamento não permite iniciar uma consulta."
            )
        }
    }
}

enum ClinicalDraftSaveStep: Equatable, Sendable {
    case temporaryFileWritten
    case published
}

struct ClinicalDraftSaver {
    typealias FaultInjector = (ClinicalDraftSaveStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func save(
        encounter: EncounterSummary,
        patientID: String,
        body: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        guard encounter.metadata.trashedAt == nil else {
            throw issue(
                "clinical_document.trashed",
                encounter.metadata.encounterID,
                "Um rascunho na lixeira deve ser restaurado antes de ser editado."
            )
        }
        var outcome: Result<ClinicalDraftSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: encounter.url,
            options: [],
            writingItemAt: encounter.draft.url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedEncounter, coordinatedDraft in
            do {
                outcome = .success(try saveUncoordinated(
                    at: coordinatedDraft,
                    encounterURL: coordinatedEncounter,
                    encounter: encounter,
                    patientID: patientID,
                    body: body,
                    updatedAt: updatedAt
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", encounter.draft.url.path, "O salvamento coordenado não foi concluído.")
        }
        return try outcome.get()
    }

    private func saveUncoordinated(
        at draftURL: URL,
        encounterURL: URL,
        encounter: EncounterSummary,
        patientID: String,
        body: String,
        updatedAt: Date
    ) throws -> ClinicalDraftSummary {
        let encountersURL = encounterURL.deletingLastPathComponent()
        let encounterContentURL = encountersURL.deletingLastPathComponent()
        let draftsURL = draftURL.deletingLastPathComponent()
        let notesURL = draftsURL.deletingLastPathComponent()
        let draftContentURL = notesURL.deletingLastPathComponent()
        guard encountersURL.lastPathComponent == "encounters",
              draftsURL.lastPathComponent == "drafts",
              notesURL.lastPathComponent == "notes",
              encounterContentURL.standardizedFileURL == draftContentURL.standardizedFileURL else {
            throw issue(
                "clinical_document.layout",
                draftURL.path,
                "Os arquivos clínicos não estão sob a estrutura esperada do paciente."
            )
        }
        for directory in [draftContentURL, encountersURL, notesURL, draftsURL] {
            try requireDirectoryWithoutSymlink(directory)
        }
        try requireRegularFileWithoutSymlink(encounterURL)
        try requireRegularFileWithoutSymlink(draftURL)
        let reopenedEncounter = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: encounterURL),
            source: encounterURL.path
        )
        guard reopenedEncounter.trashedAt == nil else {
            throw issue(
                "clinical_document.trashed",
                encounterURL.path,
                "Um rascunho na lixeira deve ser restaurado antes de ser editado."
            )
        }
        guard reopenedEncounter == encounter.metadata,
              encounterURL.deletingPathExtension().lastPathComponent == reopenedEncounter.encounterID else {
            throw issue("clinical_document.encounter_mismatch", encounterURL.path, "O encontro mudou desde a última leitura.")
        }
        let previousData = try Data(contentsOf: draftURL)
        let previous = try ClinicalDocumentValidator.validateDraft(data: previousData, source: draftURL.path)
        guard previousData == encounter.draft.persistedData else {
            throw issue(
                "clinical_document.revision_conflict",
                draftURL.path,
                "O rascunho mudou desde a última leitura. Reabra antes de salvar."
            )
        }
        try ClinicalDocumentValidator.bind(
            encounter: reopenedEncounter,
            draft: previous.metadata,
            expectedPatientID: patientID
        )
        guard draftURL.deletingPathExtension().lastPathComponent == previous.metadata.noteID else {
            throw issue("clinical_document.filename_mismatch", draftURL.path, "O nome do rascunho diverge do note_id.")
        }

        let timestamp = utcTimestamp(updatedAt)
        guard let createdAt = parseUTCTimestamp(previous.metadata.createdAt),
              let previousUpdatedAt = parseUTCTimestamp(previous.metadata.updatedAt),
              updatedAt >= createdAt,
              updatedAt >= previousUpdatedAt else {
            throw issue("clinical_document.updated_at", "/updated_at", "updated_at não pode anteceder created_at.")
        }
        let canonicalUpdatedAt = "updated_at: \"\(previous.metadata.updatedAt)\"\n"
        guard previous.frontmatter.components(separatedBy: canonicalUpdatedAt).count == 2 else {
            throw issue(
                "clinical_document.writer_representation",
                "/updated_at",
                "O writer exige a representação canônica de updated_at."
            )
        }
        let updatedFrontmatter = previous.frontmatter.replacingOccurrences(
            of: #"(?m)^updated_at:.*$"#,
            with: "updated_at: \"\(timestamp)\"",
            options: .regularExpression
        )
        let normalizedBody = Self.normalizeBody(body)
        let updatedData = Data(("---\n" + updatedFrontmatter + "---\n\n" + normalizedBody).utf8)
        let temporary = draftURL.deletingLastPathComponent().appending(
            path: ".openpep-save-\(UUID().uuidString.lowercased())"
        )
        let backup = draftURL.deletingLastPathComponent().appending(
            path: ".openpep-backup-\(UUID().uuidString.lowercased())"
        )
        var preserveBackup = false
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
            if !preserveBackup, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.removeItem(at: backup)
            }
        }

        try updatedData.write(to: temporary, options: [.withoutOverwriting])
        let candidate = try ClinicalDocumentValidator.validateDraft(
            data: Data(contentsOf: temporary),
            source: draftURL.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: reopenedEncounter,
            draft: candidate.metadata,
            expectedPatientID: patientID
        )
        try faultInjector?(.temporaryFileWritten)

        do {
            _ = try fileManager.replaceItemAt(
                draftURL,
                withItemAt: temporary,
                backupItemName: backup.lastPathComponent,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
            )
            try faultInjector?(.published)
            let reopenedData = try Data(contentsOf: draftURL)
            let reopened = try ClinicalDocumentValidator.validateDraft(
                data: reopenedData,
                source: draftURL.path
            )
            try ClinicalDocumentValidator.bind(
                encounter: reopenedEncounter,
                draft: reopened.metadata,
                expectedPatientID: patientID
            )
            let summary = ClinicalDraftSummary(
                metadata: reopened.metadata,
                url: draftURL,
                body: reopened.body,
                persistedData: reopenedData
            )
            do {
                try fileManager.removeItem(at: backup)
            } catch {
                preserveBackup = true
                throw issue(
                    "clinical_document.cleanup_failed",
                    backup.path,
                    "O novo rascunho foi validado, mas o backup temporário não pôde ser removido."
                )
            }
            return summary
        } catch {
            guard (error as? VaultValidationIssue)?.rule != "clinical_document.cleanup_failed" else {
                throw error
            }
            do {
                if fileManager.fileExists(atPath: backup.path) {
                    if fileManager.fileExists(atPath: draftURL.path) {
                        try fileManager.removeItem(at: draftURL)
                    }
                    try fileManager.moveItem(at: backup, to: draftURL)
                } else if !fileManager.fileExists(atPath: draftURL.path) {
                    throw issue(
                        "clinical_document.rollback_failed",
                        backup.path,
                        "Nem o rascunho anterior nem o backup puderam ser encontrados."
                    )
                }
            } catch {
                preserveBackup = true
                throw issue(
                    "clinical_document.rollback_failed",
                    backup.path,
                    "A restauração falhou; o backup remanescente foi preservado para diagnóstico."
                )
            }
            throw error
        }
    }

    /// Compare the editable buffer to its existing on-disk representation without
    /// rewriting the editor, including when its last character is not a newline.
    static func matchesPersistedBody(_ editable: String, _ persisted: String) -> Bool {
        editable == persisted || normalizeBody(editable) == persisted
    }

    private static func normalizeBody(_ body: String) -> String {
        var result = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        while result.hasSuffix("\n") { result.removeLast() }
        if !result.isEmpty { result.append("\n") }
        return result
    }
}

struct ClinicalContentInspector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspect(contentURL: URL, patientID: String) throws -> [EncounterSummary] {
        try requireDirectory(contentURL)
        let rootEntries = try children(of: contentURL)
        if rootEntries.isEmpty {
            _ = try FinalizationInspector(fileManager: fileManager).statuses(
                patientURL: contentURL.deletingLastPathComponent(),
                patientID: patientID,
                encounterNoteIDs: [:]
            )
            return []
        }
        let rootEntryNames = Set(rootEntries.map(\.lastPathComponent))
        guard rootEntryNames.contains("encounters"), rootEntryNames.contains("notes"),
              rootEntryNames.isSubset(of: ["encounters", "notes", ProgressiveConsultationWorkStore.directoryName, DocumentReviewRecord.directoryName]) else {
            throw issue("clinical_document.layout", contentURL.path, "O diretório content contém dados fora deste corte.")
        }

        let encountersURL = contentURL.appending(path: "encounters", directoryHint: .isDirectory)
        let notesURL = contentURL.appending(path: "notes", directoryHint: .isDirectory)
        try requireDirectory(encountersURL)
        try requireDirectory(notesURL)
        let noteEntries = try children(of: notesURL)
        let noteEntryNames = Set(noteEntries.map(\.lastPathComponent))
        guard noteEntryNames.contains("drafts"),
              noteEntryNames.isSubset(of: ["drafts", "final", "addenda"]) else {
            throw issue("clinical_document.layout", notesURL.path, "O diretório notes contém dados fora deste corte.")
        }
        for optionalDirectory in ["final", "addenda"] where noteEntryNames.contains(optionalDirectory) {
            try requireDirectory(notesURL.appending(path: optionalDirectory, directoryHint: .isDirectory))
        }
        let draftsURL = notesURL.appending(path: "drafts", directoryHint: .isDirectory)
        try requireDirectory(draftsURL)
        let consultationWork = try ProgressiveConsultationWorkStore(fileManager: fileManager)
            .documents(in: contentURL, patientID: patientID)
        let vaultURL = contentURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vaultManifestURL = vaultURL.appending(path: "vault.yaml")
        let vaultID = if fileManager.fileExists(atPath: vaultManifestURL.path) {
            try VaultManifestValidator.validate(
                data: Data(contentsOf: vaultManifestURL, options: [.mappedIfSafe]),
                source: vaultManifestURL.path
            ).vaultID
        } else {
            Optional<String>.none
        }

        var encounters: [String: (EncounterMetadata, URL)] = [:]
        for url in try children(of: encountersURL) {
            try requireRegularFile(url)
            let metadata = try ClinicalDocumentValidator.validateEncounter(
                data: Data(contentsOf: url),
                source: url.path
            )
            guard url.pathExtension == "md",
                  url.deletingPathExtension().lastPathComponent == metadata.encounterID,
                  encounters[metadata.encounterID] == nil else {
                throw issue("clinical_document.filename_mismatch", url.path, "O arquivo de encontro não corresponde ao ID.")
            }
            encounters[metadata.encounterID] = (metadata, url)
        }

        var drafts: [String: ClinicalDraftSummary] = [:]
        for url in try children(of: draftsURL) {
            try requireRegularFile(url)
            let persistedData = try Data(contentsOf: url)
            let document = try ClinicalDocumentValidator.validateDraft(
                data: persistedData,
                source: url.path
            )
            guard url.pathExtension == "md",
                  url.deletingPathExtension().lastPathComponent == document.metadata.noteID,
                  drafts[document.metadata.encounterID] == nil else {
                throw issue("clinical_document.filename_mismatch", url.path, "O arquivo de rascunho não corresponde ao ID.")
            }
            drafts[document.metadata.encounterID] = ClinicalDraftSummary(
                metadata: document.metadata,
                url: url,
                body: document.body,
                persistedData: persistedData
            )
        }

        guard encounters.count == drafts.count else {
            throw issue("clinical_document.pair", contentURL.path, "Encontro e rascunho devem formar pares completos.")
        }
        guard Set(consultationWork.map(\.encounterID)).count == consultationWork.count,
              consultationWork.allSatisfy({
                  (vaultID == nil || $0.vaultID == vaultID) && encounters[$0.encounterID] != nil
              }) else {
            throw issue(
                "progressive_summary.encounter_binding",
                contentURL.appending(path: ProgressiveConsultationWorkStore.directoryName).path,
                "O rascunho de acompanhamento deve pertencer a um encontro deste paciente."
            )
        }
        try DocumentReviewRecord.inspect(directory: contentURL.appending(path: DocumentReviewRecord.directoryName), encounterIDs: Set(encounters.keys))
        let noteIDs = Dictionary(uniqueKeysWithValues: drafts.map { ($0.key, $0.value.metadata.noteID) })
        let finalizationStatuses = try FinalizationInspector(fileManager: fileManager).statuses(
            patientURL: contentURL.deletingLastPathComponent(),
            patientID: patientID,
            encounterNoteIDs: noteIDs
        )
        return try encounters.values.map { metadata, url in
            guard let draft = drafts[metadata.encounterID] else {
                throw issue("clinical_document.pair", metadata.encounterID, "O encontro não possui rascunho.")
            }
            try ClinicalDocumentValidator.bind(
                encounter: metadata,
                draft: draft.metadata,
                expectedPatientID: patientID
            )
            return EncounterSummary(
                metadata: metadata,
                url: url,
                draft: draft,
                finalizationStatus: finalizationStatuses[metadata.encounterID] ?? .draft
            )
        }.sorted { $0.metadata.startedAt < $1.metadata.startedAt }
    }

    private func children(of directory: URL) throws -> [URL] {
        try managedDirectoryEntries(in: directory, fileManager: fileManager)
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw issue("filesystem.file", url.path, "Era esperado um arquivo regular sem link simbólico.")
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw issue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
        }
    }
}

private func utcTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func parseUTCTimestamp(_ value: String) -> Date? {
    guard value.hasSuffix("Z") else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func issue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}

private func normalizeClinicalText(_ text: String) -> String {
    var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .precomposedStringWithCanonicalMapping
    while normalized.hasSuffix("\n") { normalized.removeLast() }
    if !normalized.isEmpty { normalized.append("\n") }
    return normalized
}

private func normalizedClinicalFact(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.precomposedStringWithCanonicalMapping
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    return normalized
}

private func yamlQuoted(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func requireRegularFileWithoutSymlink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw issue("filesystem.file", url.path, "Era esperado um arquivo regular sem link simbólico.")
    }
}

private func requireDirectoryWithoutSymlink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw issue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
    }
}
