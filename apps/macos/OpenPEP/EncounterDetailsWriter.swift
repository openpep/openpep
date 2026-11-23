// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct EncounterDetailsInput: Equatable, Sendable {
    let modality: AppointmentModality
    let telemedicine: TelemedicineEncounterInput?
}

enum EncounterDetailsSaveStep: Equatable, Sendable {
    case temporaryFileWritten
    case published
}

struct EncounterDetailsWriter {
    typealias FaultInjector = (EncounterDetailsSaveStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func save(
        in vault: VaultSummary,
        patient: PatientSummary,
        encounter: EncounterSummary,
        expectedData: Data,
        input: EncounterDetailsInput,
        remoteAccessURL: String? = nil
    ) throws -> EncounterSummary {
        guard vault.writingAllowed,
              patient.patientID == encounter.metadata.patientID,
              vault.patients.contains(where: { $0.patientID == patient.patientID }) else {
            throw detailsIssue(
                "encounter_details.patient_unavailable",
                patient.patientID,
                "A consulta exige um paciente disponível em um prontuário gravável."
            )
        }
        var outcome: Result<EncounterSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vault.url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                outcome = .success(try saveUncoordinated(
                    in: coordinatedVault,
                    patient: patient,
                    encounter: encounter,
                    expectedData: expectedData,
                    input: input,
                    remoteAccessURL: remoteAccessURL
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw detailsIssue(
                "filesystem.coordination",
                vault.url.path,
                "A atualização coordenada do encontro não foi concluída."
            )
        }
        return try outcome.get()
    }

    private func saveUncoordinated(
        in vaultURL: URL,
        patient: PatientSummary,
        encounter: EncounterSummary,
        expectedData: Data,
        input: EncounterDetailsInput,
        remoteAccessURL: String?
    ) throws -> EncounterSummary {
        let currentVault = try VaultReader(fileManager: fileManager).readWithinCoordinatedAccess(vaultURL)
        guard currentVault.writingAllowed,
              let currentPatient = currentVault.patients.first(where: {
                  $0.patientID == patient.patientID
              }),
              let currentEncounter = currentPatient.encounters.first(where: {
                  $0.metadata.encounterID == encounter.metadata.encounterID
              }) else {
            throw detailsIssue(
                "encounter_details.patient_unavailable",
                patient.patientID,
                "O paciente ou a consulta não está mais disponível para edição."
            )
        }
        guard currentEncounter.metadata == encounter.metadata,
              currentEncounter.draft.persistedData == encounter.draft.persistedData else {
            throw detailsIssue(
                "encounter_details.revision_conflict",
                encounter.metadata.encounterID,
                "A consulta ou o rascunho mudou. Reabra antes de salvar os detalhes."
            )
        }
        guard currentEncounter.finalizationStatus == .draft, currentEncounter.metadata.trashedAt == nil else {
            throw detailsIssue(
                "encounter_details.finalized",
                encounter.metadata.encounterID,
                "Os detalhes só podem ser alterados enquanto a consulta está em rascunho."
            )
        }
        if currentEncounter.metadata.appointmentID != nil,
           input.modality.rawValue != currentEncounter.metadata.modality {
            throw detailsIssue(
                "encounter_details.linked_modality",
                encounter.metadata.encounterID,
                "A modalidade de uma consulta agendada não pode ser alterada."
            )
        }
        if let appointmentID = currentEncounter.metadata.appointmentID {
            guard let appointment = currentVault.appointments.first(where: { $0.id == appointmentID }),
                  appointment.record.patientID == currentPatient.patientID,
                  appointment.record.encounterID == currentEncounter.metadata.encounterID,
                  appointment.record.modality.rawValue == currentEncounter.metadata.modality else {
                throw detailsIssue("encounter_details.appointment_binding", appointmentID,
                                   "O vínculo com o agendamento mudou. Reabra e retome a consulta pela agenda antes de editar os detalhes.")
            }
        }
        let normalizedTelemedicine: TelemedicineEncounterInput?
        switch (input.modality, input.telemedicine) {
        case (.inPerson, nil):
            normalizedTelemedicine = nil
        case (.inPerson, .some):
            throw detailsIssue(
                "encounter_details.telemedicine_forbidden",
                "/telemedicine",
                "Uma consulta presencial não aceita fatos de teleconsulta."
            )
        case (.telemedicine, nil):
            throw detailsIssue(
                "encounter_details.telemedicine_required",
                "/telemedicine",
                "A teleconsulta exige o registro explícito dos fatos declarados."
            )
        case let (.telemedicine, .some(value)):
            guard currentEncounter.metadata.templateID != nil,
                  currentEncounter.metadata.templateVersion != nil else {
                throw detailsIssue(
                    "encounter_details.legacy_template",
                    encounter.metadata.encounterID,
                    "Esta consulta antiga não registra a origem do modelo exigida para teleconsulta e não será convertida automaticamente."
                )
            }
            normalizedTelemedicine = value.normalized()
        }

        try requireDetailsRegularFile(currentEncounter.url)
        let originalData = try Data(contentsOf: currentEncounter.url)
        guard originalData == expectedData else {
            throw detailsIssue("encounter_details.revision_conflict", currentEncounter.url.path,
                               "O arquivo da consulta mudou. Reabra os detalhes antes de salvar.")
        }
        let document = try VaultManifestValidator.parseMarkdownDocument(
            data: originalData,
            source: currentEncounter.url.path
        )
        // Preserve custom nested facts by declining representations this editor cannot round-trip.
        if case let .mapping(root) = document.metadata,
           case let .mapping(facts)? = root["telemedicine"],
           facts.keys.contains(where: { $0.hasPrefix("x_") }) {
            throw detailsIssue("encounter_details.custom_facts", currentEncounter.url.path,
                               "Esta consulta contém fatos personalizados de teleconsulta. Os detalhes não serão alterados para preservar essas informações.")
        }
        var updatedFrontmatter = try replacingDetails(
            in: document.frontmatter,
            modality: input.modality,
            telemedicine: normalizedTelemedicine
        )
        if let remoteAccessURL {
            guard input.modality == .telemedicine else {
                throw detailsIssue("encounter_details.remote_modality", currentEncounter.url.path,
                                   "Selecione Telemedicina antes de salvar o link.")
            }
            let url = try TelemedicineURLBuilder.savedLinkURL(remoteAccessURL)
            if let existing = currentEncounter.metadata.remoteAccessURL, existing != url.absoluteString {
                throw detailsIssue("encounter_details.remote_fixed", currentEncounter.url.path,
                    "Esta consulta já tem um link vinculado. Ele não pode ser substituído.")
            }
            let key = "x_openpep_remote_access_url"
            var lines = updatedFrontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let indexes = lines.indices.filter { detailsTopLevelKey(lines[$0]) == key }
            let replacement = "\(key): \(detailsYAMLQuoted(url.absoluteString))"
            if let index = indexes.first {
                guard indexes.count == 1, lines[index].hasPrefix(key + ": ") else {
                    throw detailsIssue("encounter_details.writer_representation", "/" + key,
                                       "O link não usa uma representação editável.")
                }
                lines[index] = replacement
            } else {
                // A quoted or multiline extension key is readable but must not be duplicated.
                if case let .mapping(root) = document.metadata, root[key] != nil {
                    throw detailsIssue("encounter_details.writer_representation", "/" + key,
                                       "O link não usa uma representação editável.")
                }
                lines.insert(replacement, at: 0)
            }
            updatedFrontmatter = lines.joined(separator: "\n")
        }
        let candidateData = Data(("---\n" + updatedFrontmatter + "---\n" + document.body).utf8)
        let candidateMetadata = try ClinicalDocumentValidator.validateEncounter(
            data: candidateData,
            source: currentEncounter.url.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: candidateMetadata,
            draft: currentEncounter.draft.metadata,
            expectedPatientID: currentPatient.patientID
        )

        let directory = currentEncounter.url.deletingLastPathComponent()
        try requireDetailsDirectory(directory)
        let temporary = directory.appending(path: ".openpep-encounter-details-\(UUID().uuidString.lowercased())")
        let backup = directory.appending(path: ".openpep-encounter-details-backup-\(UUID().uuidString.lowercased())")
        var preserveBackup = false
        defer {
            if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
            if !preserveBackup, fileManager.fileExists(atPath: backup.path) { try? fileManager.removeItem(at: backup) }
        }

        try candidateData.write(to: temporary, options: [.withoutOverwriting])
        _ = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: temporary),
            source: currentEncounter.url.path
        )
        try faultInjector?(.temporaryFileWritten)
        do {
            _ = try fileManager.replaceItemAt(
                currentEncounter.url,
                withItemAt: temporary,
                backupItemName: backup.lastPathComponent,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
            )
            try faultInjector?(.published)
            let reopenedData = try Data(contentsOf: currentEncounter.url)
            let reopenedMetadata = try ClinicalDocumentValidator.validateEncounter(
                data: reopenedData, source: currentEncounter.url.path
            )
            let draftData = try Data(contentsOf: currentEncounter.draft.url)
            let statuses = try FinalizationInspector(fileManager: fileManager).statuses(
                patientURL: currentPatient.url, patientID: currentPatient.patientID,
                encounterNoteIDs: Dictionary(uniqueKeysWithValues: currentPatient.encounters.map {
                    ($0.metadata.encounterID, $0.draft.metadata.noteID)
                })
            )
            guard reopenedData == candidateData, reopenedMetadata == candidateMetadata,
                  draftData == currentEncounter.draft.persistedData,
                  (statuses[currentEncounter.metadata.encounterID] ?? .draft) == .draft else {
                throw detailsIssue(
                    "encounter_details.reopen_mismatch", currentEncounter.url.path,
                    "O encontro reaberto diverge da atualização validada."
                )
            }
            let reopened = EncounterSummary(metadata: reopenedMetadata, url: currentEncounter.url,
                                            draft: currentEncounter.draft, finalizationStatus: .draft)
            do {
                try fileManager.removeItem(at: backup)
            } catch {
                preserveBackup = true
                throw detailsIssue(
                    "encounter_details.cleanup_failed",
                    backup.path,
                    "Os detalhes foram salvos, mas o backup temporário não pôde ser removido."
                )
            }
            return reopened
        } catch {
            guard (error as? VaultValidationIssue)?.rule != "encounter_details.cleanup_failed" else {
                throw error
            }
            do {
                if fileManager.fileExists(atPath: backup.path) {
                    if fileManager.fileExists(atPath: currentEncounter.url.path) {
                        let currentData = try Data(contentsOf: currentEncounter.url)
                        if currentData == originalData {
                            try fileManager.removeItem(at: backup)
                        } else if currentData == candidateData {
                            _ = try fileManager.replaceItemAt(currentEncounter.url, withItemAt: backup)
                        } else {
                            throw detailsIssue("encounter_details.rollback_conflict", currentEncounter.url.path,
                                               "O encontro recebeu outra edição durante a recuperação.")
                        }
                    } else {
                        try fileManager.moveItem(at: backup, to: currentEncounter.url)
                    }
                } else {
                    guard fileManager.fileExists(atPath: currentEncounter.url.path),
                          try Data(contentsOf: currentEncounter.url) == originalData else {
                        throw detailsIssue("encounter_details.rollback_failed", backup.path,
                                           "O backup está ausente e o encontro anterior não pôde ser confirmado.")
                    }
                }
            } catch {
                preserveBackup = true
                throw detailsIssue(
                    "encounter_details.rollback_failed",
                    backup.path,
                    "A restauração falhou; o backup remanescente foi preservado para diagnóstico."
                )
            }
            throw error
        }
    }

    private func replacingDetails(
        in frontmatter: String,
        modality: AppointmentModality,
        telemedicine: TelemedicineEncounterInput?
    ) throws -> String {
        var lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let modalityIndexes = lines.indices.filter { detailsTopLevelKey(lines[$0]) == "modality" }
        guard modalityIndexes.count == 1 else {
            throw detailsIssue(
                "encounter_details.writer_representation",
                "/modality",
                "O encontro não usa uma representação segura para editar a modalidade."
            )
        }
        lines[modalityIndexes[0]] = "modality: \(modality.rawValue)"

        let telemedicineIndexes = lines.indices.filter { detailsTopLevelKey(lines[$0]) == "telemedicine" }
        guard telemedicineIndexes.count <= 1 else {
            throw detailsIssue(
                "encounter_details.writer_representation",
                "/telemedicine",
                "O encontro não usa uma representação segura para editar a teleconsulta."
            )
        }
        let replacement = detailsTelemedicineLines(telemedicine)
        if let start = telemedicineIndexes.first {
            let end = lines.indices.dropFirst(start + 1).first(where: {
                detailsTopLevelKey(lines[$0]) != nil
            }) ?? lines.endIndex
            lines.replaceSubrange(start..<end, with: replacement)
        } else {
            guard let insertion = lines.indices.first(where: {
                detailsTopLevelKey(lines[$0]) == "x_actor_assurance"
            }) else {
                throw detailsIssue(
                    "encounter_details.writer_representation",
                    "/telemedicine",
                    "O encontro não possui um ponto seguro para registrar os detalhes."
                )
            }
            lines.insert(contentsOf: replacement, at: insertion)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func detailsTopLevelKey(_ line: String) -> String? {
    guard let first = line.first, !first.isWhitespace,
          let colon = line.firstIndex(of: ":") else { return nil }
    return String(line[..<colon])
}

private func detailsTelemedicineLines(_ input: TelemedicineEncounterInput?) -> [String] {
    guard let input else { return ["telemedicine: null"] }
    var lines = [
        "telemedicine:",
        "  consent: \(input.consent.rawValue)",
        "  declared_location: \(input.declaredLocation.map(detailsYAMLQuoted) ?? "null")",
    ]
    if input.participants.isEmpty {
        lines.append("  participants: []")
    } else {
        lines.append("  participants:")
        lines.append(contentsOf: input.participants.map { "    - \(detailsYAMLQuoted($0))" })
    }
    lines.append("  limitations: \(input.limitations.map(detailsYAMLQuoted) ?? "null")")
    lines.append("  contingency: \(input.contingency.map(detailsYAMLQuoted) ?? "null")")
    return lines
}

private func detailsYAMLQuoted(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func requireDetailsRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw detailsIssue("filesystem.file", url.path, "Era esperado um arquivo regular sem link simbólico.")
    }
}

private func requireDetailsDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw detailsIssue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
    }
}

private func detailsIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
