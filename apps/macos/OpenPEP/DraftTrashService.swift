// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

enum DraftTrashStep: Equatable, Sendable {
    case appointmentUnlinked
    case appointmentLinked
    case candidatePrepared
    case candidatePublished
}

struct DraftTrashService {
    typealias FaultInjector = (DraftTrashStep) throws -> Void

    private enum SnapshotEntry: Equatable {
        case directory
        case file(Data)
    }

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    /// `expectedData` is the exact encounter file data observed by the caller.
    /// The exact draft data comes from `encounter.draft.persistedData`.
    func discard(
        in vault: VaultSummary,
        patient: PatientSummary,
        encounter: EncounterSummary,
        expectedData: Data,
        at date: Date
    ) throws -> Bool {
        guard vault.writingAllowed,
              patient.patientID == encounter.metadata.patientID,
              encounter.metadata.trashedAt == nil else {
            throw trashIssue(
                "draft_trash.unavailable",
                encounter.metadata.encounterID,
                "Somente um rascunho ativo em prontuário gravável pode ser descartado."
            )
        }
        var outcome: Result<Bool, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vault.url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                outcome = .success(try discardWithinCoordinatedAccess(
                    vaultURL: coordinatedVault,
                    patientID: patient.patientID,
                    encounter: encounter,
                    expectedData: expectedData,
                    at: date
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw trashIssue("filesystem.coordination", vault.url.path, "O descarte coordenado não foi concluído.")
        }
        return try outcome.get()
    }

    /// `expectedData` is the exact trashed encounter file data observed by the caller.
    func restore(
        in vault: VaultSummary,
        patient: PatientSummary,
        encounter: EncounterSummary,
        expectedData: Data
    ) throws {
        guard vault.writingAllowed,
              patient.patientID == encounter.metadata.patientID,
              encounter.metadata.trashedAt != nil else {
            throw trashIssue(
                "draft_trash.unavailable",
                encounter.metadata.encounterID,
                "Somente um rascunho presente na lixeira pode ser restaurado."
            )
        }
        var outcome: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: vault.url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault in
            do {
                try restoreWithinCoordinatedAccess(
                    vaultURL: coordinatedVault,
                    patientID: patient.patientID,
                    encounter: encounter,
                    expectedData: expectedData
                )
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw trashIssue("filesystem.coordination", vault.url.path, "A restauração coordenada não foi concluída.")
        }
        try outcome.get()
    }

    private func discardWithinCoordinatedAccess(
        vaultURL: URL,
        patientID: String,
        encounter: EncounterSummary,
        expectedData: Data,
        at date: Date
    ) throws -> Bool {
        let currentVault = try VaultReader(fileManager: fileManager).readWithinCoordinatedAccess(vaultURL)
        guard currentVault.writingAllowed,
              let currentPatient = currentVault.patients.first(where: { $0.patientID == patientID }),
              let currentEncounter = currentPatient.encounters.first(where: {
                  $0.metadata.encounterID == encounter.metadata.encounterID
              }) else {
            throw trashIssue("draft_trash.unavailable", patientID, "O rascunho não está mais disponível para descarte.")
        }
        try validateSnapshot(currentEncounter, expectedData: expectedData, snapshot: encounter)
        guard currentEncounter.finalizationStatus == .draft else {
            throw trashIssue(
                "draft_trash.finalized",
                currentEncounter.metadata.encounterID,
                "Notas finais não podem ser excluídas; use um adendo para corrigi-las."
            )
        }

        let hasContent = try containsMeaningfulContent(currentEncounter, patient: currentPatient)
        try unlinkAppointmentIfNeeded(
            for: currentEncounter,
            patient: currentPatient,
            vault: currentVault,
            at: date
        )

        if hasContent {
            let candidate = try encounterDataByAddingTrashMarker(
                to: expectedData,
                source: currentEncounter.url.path,
                at: date
            )
            try replaceEncounter(
                currentEncounter,
                originalData: expectedData,
                candidateData: candidate,
                patient: currentPatient,
                vaultURL: vaultURL
            )
        } else {
            try permanentlyRemoveEmptyPair(
                currentEncounter,
                expectedEncounterData: expectedData,
                patient: currentPatient,
                vaultURL: vaultURL
            )
        }

        let reopened = try VaultReader(fileManager: fileManager).readWithinCoordinatedAccess(vaultURL)
        let reopenedPatient = try requirePatient(patientID, in: reopened)
        if hasContent {
            guard reopenedPatient.encounters.allSatisfy({ $0.metadata.encounterID != encounter.metadata.encounterID }),
                  reopenedPatient.trashedEncounters.contains(where: {
                      $0.metadata.encounterID == encounter.metadata.encounterID
                  }) else {
                throw trashIssue("draft_trash.reopen_mismatch", encounter.metadata.encounterID,
                                 "O rascunho descartado não reapareceu exclusivamente na lixeira.")
            }
        } else {
            guard (reopenedPatient.encounters + reopenedPatient.trashedEncounters).allSatisfy({
                $0.metadata.encounterID != encounter.metadata.encounterID
            }) else {
                throw trashIssue("draft_trash.reopen_mismatch", encounter.metadata.encounterID,
                                 "O rascunho vazio permaneceu no prontuário após a remoção.")
            }
        }
        return hasContent
    }

    private func restoreWithinCoordinatedAccess(
        vaultURL: URL,
        patientID: String,
        encounter: EncounterSummary,
        expectedData: Data
    ) throws {
        let currentVault = try VaultReader(fileManager: fileManager).readWithinCoordinatedAccess(vaultURL)
        guard currentVault.writingAllowed,
              let currentPatient = currentVault.patients.first(where: { $0.patientID == patientID }),
              let currentEncounter = currentPatient.trashedEncounters.first(where: {
                  $0.metadata.encounterID == encounter.metadata.encounterID
              }) else {
            throw trashIssue("draft_trash.unavailable", patientID, "O rascunho não está mais disponível na lixeira.")
        }
        try validateSnapshot(currentEncounter, expectedData: expectedData, snapshot: encounter)
        guard currentEncounter.finalizationStatus == .draft else {
            throw trashIssue("draft_trash.finalized", currentEncounter.metadata.encounterID,
                             "Uma consulta com nota final não pode sair da lixeira como rascunho.")
        }

        let linkedAppointment = try linkAppointmentIfNeeded(
            for: currentEncounter,
            patient: currentPatient,
            vault: currentVault
        )
        do {
            let candidate = try encounterDataByRemovingTrashMarker(
                from: expectedData,
                encounter: currentEncounter
            )
            try replaceEncounter(
                currentEncounter,
                originalData: expectedData,
                candidateData: candidate,
                patient: currentPatient,
                vaultURL: vaultURL
            )
        } catch {
            if let linkedAppointment {
                _ = try? AppointmentWriter(fileManager: fileManager).unlinkEncounterWithinCoordinatedAccess(
                    linkedAppointment,
                    encounterID: currentEncounter.metadata.encounterID,
                    in: vaultURL,
                    updatedAt: Date()
                )
            }
            throw error
        }

        let reopened = try VaultReader(fileManager: fileManager).readWithinCoordinatedAccess(vaultURL)
        let reopenedPatient = try requirePatient(patientID, in: reopened)
        guard reopenedPatient.trashedEncounters.allSatisfy({
            $0.metadata.encounterID != encounter.metadata.encounterID
        }), reopenedPatient.encounters.contains(where: {
            $0.metadata.encounterID == encounter.metadata.encounterID
        }) else {
            throw trashIssue("draft_trash.reopen_mismatch", encounter.metadata.encounterID,
                             "O rascunho restaurado não reapareceu exclusivamente entre as consultas ativas.")
        }
    }

    private func validateSnapshot(
        _ current: EncounterSummary,
        expectedData: Data,
        snapshot: EncounterSummary
    ) throws {
        let encounterData = try Data(contentsOf: current.url)
        let draftData = try Data(contentsOf: current.draft.url)
        guard encounterData == expectedData,
              current.metadata == snapshot.metadata,
              current.draft.metadata == snapshot.draft.metadata,
              draftData == snapshot.draft.persistedData else {
            throw trashIssue(
                "draft_trash.revision_conflict",
                current.metadata.encounterID,
                "A consulta ou o rascunho mudou. Reabra antes de continuar."
            )
        }
    }

    private func containsMeaningfulContent(
        _ encounter: EncounterSummary,
        patient: PatientSummary
    ) throws -> Bool {
        do {
            let page = try LinearConsultationPage(body: encounter.draft.body)
            if !page.consultation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || page.fields.items.contains(where: { !$0.isEmpty }) {
                return true
            }
        } catch {
            // Ambiguous structural markers must be preserved as meaningful content.
            return true
        }
        if !encounter.draft.metadata.sourceIDs.isEmpty || encounter.draft.metadata.aiAssistance != .none { return true }
        let allAssets = patient.rawAssets + patient.trashedRawAssets
        if allAssets.contains(where: { $0.encounterID == encounter.metadata.encounterID }) { return true }
        let progressiveWorkURL = patient.url.appending(
            path: "content/\(ProgressiveConsultationWorkStore.directoryName)/\(encounter.metadata.encounterID).json"
        )
        if fileManager.fileExists(atPath: progressiveWorkURL.path) { return true }
        if let telemedicine = encounter.metadata.telemedicine,
           telemedicine.consent != .notRecorded
            || telemedicine.declaredLocation != nil
            || !telemedicine.participants.isEmpty
            || telemedicine.limitations != nil
            || telemedicine.contingency != nil {
            return true
        }
        if encounter.metadata.remoteAccessURL != nil { return true }

        let encounterDocument = try VaultManifestValidator.parseMarkdownDocument(
            data: Data(contentsOf: encounter.url), source: encounter.url.path
        )
        let draftDocument = try VaultManifestValidator.parseMarkdownDocument(
            data: encounter.draft.persistedData, source: encounter.draft.url.path
        )
        return containsPersonalExtension(encounterDocument.metadata, atRoot: true)
            || containsPersonalExtension(draftDocument.metadata, atRoot: true)
    }

    private func containsPersonalExtension(_ value: YAMLValue, atRoot: Bool = false) -> Bool {
        switch value {
        case let .mapping(mapping):
            for (key, child) in mapping {
                if key.hasPrefix("x_"),
                   !(atRoot && ["x_actor_assurance", "x_openpep_trashed_at"].contains(key)) {
                    return true
                }
                if containsPersonalExtension(child) { return true }
            }
            return false
        case let .sequence(values):
            return values.contains { containsPersonalExtension($0) }
        case .null, .boolean, .integer, .string:
            return false
        }
    }

    private func unlinkAppointmentIfNeeded(
        for encounter: EncounterSummary,
        patient: PatientSummary,
        vault: VaultSummary,
        at date: Date
    ) throws {
        guard let appointmentID = encounter.metadata.appointmentID else { return }
        guard let appointment = vault.appointments.first(where: { $0.id == appointmentID }),
              appointment.record.patientID == patient.patientID,
              appointment.record.modality.rawValue == encounter.metadata.modality else {
            throw trashIssue("draft_trash.appointment_binding", appointmentID,
                             "O agendamento da consulta mudou ou não está disponível.")
        }
        if appointment.record.encounterID == nil { return }
        guard appointment.record.encounterID == encounter.metadata.encounterID else {
            throw trashIssue("draft_trash.appointment_conflict", appointmentID,
                             "O agendamento está ligado a outra consulta e foi preservado.")
        }
        _ = try AppointmentWriter(fileManager: fileManager).unlinkEncounterWithinCoordinatedAccess(
            appointment,
            encounterID: encounter.metadata.encounterID,
            in: vault.url,
            updatedAt: date
        )
        try faultInjector?(.appointmentUnlinked)
    }

    private func linkAppointmentIfNeeded(
        for encounter: EncounterSummary,
        patient: PatientSummary,
        vault: VaultSummary
    ) throws -> AppointmentSummary? {
        guard let appointmentID = encounter.metadata.appointmentID else { return nil }
        guard let appointment = vault.appointments.first(where: { $0.id == appointmentID }),
              appointment.record.patientID == patient.patientID,
              appointment.record.modality.rawValue == encounter.metadata.modality else {
            throw trashIssue("draft_trash.appointment_binding", appointmentID,
                             "O agendamento não está disponível para restaurar esta consulta; o item permaneceu na lixeira.")
        }
        if appointment.record.encounterID == encounter.metadata.encounterID { return nil }
        guard appointment.record.encounterID == nil else {
            throw trashIssue("draft_trash.appointment_conflict", appointmentID,
                             "O agendamento já está ligado a outra consulta; o item permaneceu na lixeira.")
        }
        guard ![.cancelled, .noShow, .completed].contains(appointment.record.status) else {
            throw trashIssue("draft_trash.appointment_unavailable", appointmentID,
                             "O estado atual do agendamento impede restaurar a consulta; o item permaneceu na lixeira.")
        }
        let linked = try AppointmentWriter(fileManager: fileManager).linkEncounterWithinCoordinatedAccess(
            appointment,
            encounterID: encounter.metadata.encounterID,
            in: vault.url,
            updatedAt: Date()
        )
        do {
            try faultInjector?(.appointmentLinked)
        } catch {
            _ = try? AppointmentWriter(fileManager: fileManager).unlinkEncounterWithinCoordinatedAccess(
                linked,
                encounterID: encounter.metadata.encounterID,
                in: vault.url,
                updatedAt: Date()
            )
            throw error
        }
        return linked
    }

    private func encounterDataByAddingTrashMarker(to data: Data, source: String, at date: Date) throws -> Data {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: source)
        guard case let .mapping(root) = document.metadata,
              root["x_openpep_trashed_at"] == nil else {
            throw trashIssue("draft_trash.already_trashed", source, "O rascunho já está na lixeira.")
        }
        let anchor = "x_actor_assurance: synthetic_unauthenticated\n"
        guard document.frontmatter.components(separatedBy: anchor).count == 2 else {
            throw trashIssue("draft_trash.writer_representation", source,
                             "O encontro não usa a representação esperada para registrar a lixeira.")
        }
        let marker = "x_openpep_trashed_at: \"\(trashTimestamp(date))\"\n"
        let frontmatter = document.frontmatter.replacingOccurrences(of: anchor, with: marker + anchor)
        let candidate = Data(("---\n" + frontmatter + "---\n" + document.body).utf8)
        _ = try ClinicalDocumentValidator.validateEncounter(data: candidate, source: source)
        return candidate
    }

    private func encounterDataByRemovingTrashMarker(
        from data: Data,
        encounter: EncounterSummary
    ) throws -> Data {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: encounter.url.path)
        guard let trashedAt = encounter.metadata.trashedAt else {
            throw trashIssue("draft_trash.not_trashed", encounter.url.path, "O encontro não possui marcador de lixeira.")
        }
        let marker = "x_openpep_trashed_at: \"\(trashedAt)\"\n"
        guard document.frontmatter.components(separatedBy: marker).count == 2 else {
            throw trashIssue("draft_trash.writer_representation", encounter.url.path,
                             "O marcador de lixeira não usa a representação esperada.")
        }
        let frontmatter = document.frontmatter.replacingOccurrences(of: marker, with: "")
        let candidate = Data(("---\n" + frontmatter + "---\n" + document.body).utf8)
        let metadata = try ClinicalDocumentValidator.validateEncounter(data: candidate, source: encounter.url.path)
        guard metadata.trashedAt == nil else {
            throw trashIssue("draft_trash.reopen_mismatch", encounter.url.path, "O marcador de lixeira não foi removido.")
        }
        return candidate
    }

    private func replaceEncounter(
        _ encounter: EncounterSummary,
        originalData: Data,
        candidateData: Data,
        patient: PatientSummary,
        vaultURL: URL
    ) throws {
        try requireDirectory(encounter.url.deletingLastPathComponent())
        try requireRegularFile(encounter.url)
        let recovery = try recoveryDirectory(in: vaultURL)
        let token = UUID().uuidString.lowercased()
        let staged = recovery.appending(path: "encounter-\(token).md")
        var swapped = false
        var preserveRecovery = false
        defer {
            if !preserveRecovery, fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
        }

        try candidateData.write(to: staged, options: [.withoutOverwriting])
        let candidateMetadata = try ClinicalDocumentValidator.validateEncounter(
            data: Data(contentsOf: staged), source: encounter.url.path
        )
        try ClinicalDocumentValidator.bind(
            encounter: candidateMetadata,
            draft: encounter.draft.metadata,
            expectedPatientID: patient.patientID
        )
        try faultInjector?(.candidatePrepared)
        guard try Data(contentsOf: encounter.url) == originalData,
              try Data(contentsOf: encounter.draft.url) == encounter.draft.persistedData else {
            throw trashIssue("draft_trash.revision_conflict", encounter.url.path,
                             "A consulta ou o rascunho mudou imediatamente antes da publicação.")
        }
        try requireStillDraft(encounter, patient: patient)
        do {
            try atomicSwap(encounter.url, staged)
            swapped = true
            try faultInjector?(.candidatePublished)
            guard try Data(contentsOf: encounter.url) == candidateData,
                  try Data(contentsOf: staged) == originalData,
                  try Data(contentsOf: encounter.draft.url) == encounter.draft.persistedData else {
                throw trashIssue("draft_trash.reopen_mismatch", encounter.url.path,
                                 "Os arquivos reabertos divergem do descarte validado.")
            }
            try fileManager.removeItem(at: staged)
        } catch {
            if swapped {
                do {
                    guard try Data(contentsOf: encounter.url) == candidateData,
                          try Data(contentsOf: staged) == originalData else {
                        throw trashIssue("draft_trash.rollback_conflict", encounter.url.path,
                                         "O encontro recebeu outra edição durante a recuperação.")
                    }
                    try atomicSwap(encounter.url, staged)
                } catch {
                    preserveRecovery = true
                    throw trashIssue("draft_trash.rollback_failed", staged.path,
                                     "A recuperação falhou; a cópia anterior foi preservada em recovery.")
                }
            }
            throw error
        }
    }

    private func permanentlyRemoveEmptyPair(
        _ encounter: EncounterSummary,
        expectedEncounterData: Data,
        patient: PatientSummary,
        vaultURL: URL
    ) throws {
        let contentURL = patient.url.appending(path: "content", directoryHint: .isDirectory)
        try requireDirectory(contentURL)
        let recovery = try recoveryDirectory(in: vaultURL)
        let token = UUID().uuidString.lowercased()
        let staged = recovery.appending(path: "content-\(token)", directoryHint: .isDirectory)
        let originalSnapshot = try contentSnapshot(at: contentURL)
        guard originalSnapshot["encounters/\(encounter.url.lastPathComponent)"]
                == .file(expectedEncounterData),
              originalSnapshot["notes/drafts/\(encounter.draft.url.lastPathComponent)"]
                == .file(encounter.draft.persistedData) else {
            throw trashIssue("draft_trash.revision_conflict", contentURL.path,
                             "A consulta ou o rascunho mudou antes de preparar a remoção.")
        }
        var swapped = false
        var preserveRecovery = false
        defer {
            if !preserveRecovery, fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
        }

        try fileManager.copyItem(at: contentURL, to: staged)
        let stagedEncounter = staged.appending(path: "encounters/\(encounter.url.lastPathComponent)")
        let stagedDraft = staged.appending(path: "notes/drafts/\(encounter.draft.url.lastPathComponent)")
        try requireRegularFile(stagedEncounter)
        try requireRegularFile(stagedDraft)
        try fileManager.removeItem(at: stagedEncounter)
        try fileManager.removeItem(at: stagedDraft)
        _ = try ClinicalContentInspector(fileManager: fileManager).inspect(
            contentURL: staged,
            patientID: patient.patientID
        )
        let candidateSnapshot = try contentSnapshot(at: staged)
        try faultInjector?(.candidatePrepared)
        guard try contentSnapshot(at: contentURL) == originalSnapshot else {
            throw trashIssue("draft_trash.revision_conflict", contentURL.path,
                             "O conteúdo clínico mudou imediatamente antes da publicação.")
        }
        try requireStillDraft(encounter, patient: patient)

        do {
            try atomicSwap(contentURL, staged)
            swapped = true
            try faultInjector?(.candidatePublished)
            guard try contentSnapshot(at: contentURL) == candidateSnapshot,
                  try contentSnapshot(at: staged) == originalSnapshot else {
                throw trashIssue("draft_trash.reopen_mismatch", contentURL.path,
                                 "O diretório reaberto diverge da remoção validada.")
            }
            try fileManager.removeItem(at: staged)
        } catch {
            if swapped {
                do {
                    guard try contentSnapshot(at: contentURL) == candidateSnapshot,
                          try contentSnapshot(at: staged) == originalSnapshot else {
                        throw trashIssue("draft_trash.rollback_conflict", contentURL.path,
                                         "O conteúdo recebeu outra edição durante a recuperação.")
                    }
                    try atomicSwap(contentURL, staged)
                } catch {
                    preserveRecovery = true
                    throw trashIssue("draft_trash.rollback_failed", staged.path,
                                     "A recuperação falhou; a cópia anterior foi preservada em recovery.")
                }
            }
            throw error
        }
    }

    private func recoveryDirectory(in vaultURL: URL) throws -> URL {
        let recovery = vaultURL.appending(path: "recovery", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: recovery.path) {
            try fileManager.createDirectory(at: recovery, withIntermediateDirectories: false)
        }
        try requireDirectory(recovery)
        return recovery
    }

    private func requireStillDraft(_ encounter: EncounterSummary, patient: PatientSummary) throws {
        let allEncounters = patient.encounters + patient.trashedEncounters
        let statuses = try FinalizationInspector(fileManager: fileManager).statuses(
            patientURL: patient.url,
            patientID: patient.patientID,
            encounterNoteIDs: Dictionary(uniqueKeysWithValues: allEncounters.map {
                ($0.metadata.encounterID, $0.draft.metadata.noteID)
            })
        )
        guard (statuses[encounter.metadata.encounterID] ?? .draft) == .draft else {
            throw trashIssue("draft_trash.finalized", encounter.metadata.encounterID,
                             "Notas finais não podem ser excluídas; use um adendo para corrigi-las.")
        }
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func contentSnapshot(at root: URL) throws -> [String: SnapshotEntry] {
        var result: [String: SnapshotEntry] = [:]
        try appendSnapshotEntry(root, relativePath: ".", to: &result)
        return result
    }

    private func appendSnapshotEntry(
        _ url: URL,
        relativePath: String,
        to result: inout [String: SnapshotEntry]
    ) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw trashIssue("filesystem.symlink", url.path, "A remoção não aceita links simbólicos.")
        }
        if values.isDirectory == true {
            result[relativePath] = .directory
            let children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childPath = relativePath == "."
                    ? child.lastPathComponent
                    : relativePath + "/" + child.lastPathComponent
                try appendSnapshotEntry(child, relativePath: childPath, to: &result)
            }
        } else if values.isRegularFile == true {
            result[relativePath] = .file(try Data(contentsOf: url, options: [.mappedIfSafe]))
        } else {
            throw trashIssue("filesystem.regular_file", url.path, "O conteúdo possui um item não reconhecido.")
        }
    }

    private func requirePatient(_ patientID: String, in vault: VaultSummary) throws -> PatientSummary {
        guard let patient = vault.patients.first(where: { $0.patientID == patientID }) else {
            throw trashIssue("draft_trash.patient_unavailable", patientID,
                             "O paciente não pôde ser relido após a operação.")
        }
        return patient
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw trashIssue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw trashIssue("filesystem.regular_file", url.path, "Era esperado um arquivo regular sem link simbólico.")
        }
    }
}

private func trashTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func trashIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
