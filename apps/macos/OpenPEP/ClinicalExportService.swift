// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

enum ClinicalExportScope: Equatable, Sendable {
    case patient(patientID: String)
    case encounter(patientID: String, encounterID: String)
}

struct ClinicalExportResult: Equatable, Sendable {
    let directoryURL: URL
    let encounterCount: Int
    let documentCount: Int
}

enum ClinicalExportStep: Equatable, Sendable {
    case stagingCreated
    case contentWritten
    case beforeStagingCleanup
}

struct ClinicalExportService {
    typealias FaultInjector = (ClinicalExportStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func export(
        scope: ClinicalExportScope,
        from vaultURL: URL,
        to destinationURL: URL
    ) throws -> ClinicalExportResult {
        try validateDestination(destinationURL, outside: vaultURL)

        let parentURL = destinationURL.deletingLastPathComponent()
        var outcome: Result<ClinicalExportResult, Error>?
        var coordinationError: NSError?

        NSFileCoordinator().coordinate(
            readingItemAt: vaultURL,
            options: [],
            writingItemAt: parentURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault, coordinatedParent in
            do {
                let freshVault = try VaultReader(fileManager: fileManager).open(coordinatedVault)
                let plan = try makePlan(scope: scope, vault: freshVault)
                let coordinatedDestination = coordinatedParent.appending(
                    path: destinationURL.lastPathComponent,
                    directoryHint: .isDirectory
                )
                try validateDestination(coordinatedDestination, outside: coordinatedVault)
                outcome = .success(try publish(
                    plan,
                    sourceVaultURL: coordinatedVault,
                    to: coordinatedDestination
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw exportIssue(
                "clinical_export.coordination",
                destinationURL.path,
                "A exportação coordenada não foi concluída."
            )
        }
        return try outcome.get()
    }

    private func makePlan(scope: ClinicalExportScope, vault: VaultSummary) throws -> ExportPlan {
        let patientID: String
        let selectedEncounterID: String?
        switch scope {
        case let .patient(id):
            patientID = id
            selectedEncounterID = nil
        case let .encounter(id, encounterID):
            patientID = id
            selectedEncounterID = encounterID
        }

        guard OpenPEPIdentifier.isPatient(patientID) else {
            throw exportIssue(
                "clinical_export.invalid_patient_id",
                patientID,
                "O paciente selecionado não possui um identificador seguro."
            )
        }
        guard let patient = vault.patients.first(where: { $0.patientID == patientID }) else {
            throw exportIssue(
                "clinical_export.patient_not_found",
                patientID,
                "O paciente não foi encontrado após reler o prontuário."
            )
        }

        let encounters: [EncounterSummary]
        let documents: [RawAssetSummary]
        if let selectedEncounterID {
            guard OpenPEPIdentifier.isEncounter(selectedEncounterID) else {
                throw exportIssue(
                    "clinical_export.invalid_encounter_id",
                    selectedEncounterID,
                    "A consulta selecionada não possui um identificador seguro."
                )
            }
            guard let encounter = patient.encounters.first(where: {
                $0.metadata.encounterID == selectedEncounterID
            }) else {
                throw exportIssue(
                    "clinical_export.encounter_not_found",
                    selectedEncounterID,
                    "A consulta não pertence ao paciente após reler o prontuário."
                )
            }
            encounters = [encounter]
            documents = patient.rawAssets.filter { $0.encounterID == selectedEncounterID }
        } else {
            encounters = patient.encounters
            documents = patient.rawAssets
        }

        for encounter in encounters {
            if case .altered = encounter.finalizationStatus {
                throw exportIssue(
                    "clinical_export.altered_encounter",
                    encounter.metadata.encounterID,
                    "A consulta possui alteração detectada e não pode ser exportada."
                )
            }
            try ClinicalDocumentValidator.bindAISource(
                draft: encounter.draft.metadata,
                encounterID: encounter.metadata.encounterID,
                assets: patient.rawAssets
            )
        }
        let encounterIDs = Set(patient.encounters.map(\.metadata.encounterID))
        guard documents.allSatisfy({ document in
            document.encounterID.map(encounterIDs.contains) ?? true
        }) else {
            throw exportIssue(
                "clinical_export.document_binding",
                patientID,
                "Um documento possui vínculo divergente com as consultas do paciente."
            )
        }

        return ExportPlan(
            scope: scope,
            patient: patient,
            encounters: encounters.sorted { $0.metadata.startedAt < $1.metadata.startedAt },
            documents: documents.sorted { $0.importedAt < $1.importedAt }
        )
    }

    private func publish(
        _ plan: ExportPlan,
        sourceVaultURL: URL,
        to destinationURL: URL
    ) throws -> ClinicalExportResult {
        let parentURL = destinationURL.deletingLastPathComponent()
        try requireSafeDirectory(parentURL)
        guard !itemExistsIncludingSymbolicLink(destinationURL) else {
            throw exportIssue(
                "clinical_export.destination_exists",
                destinationURL.path,
                "Escolha uma pasta nova para a exportação."
            )
        }

        let stagingURL = parentURL.appending(
            path: ".openpep-export-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        guard !itemExistsIncludingSymbolicLink(stagingURL) else {
            throw exportIssue(
                "clinical_export.staging_collision",
                stagingURL.path,
                "A pasta temporária da exportação já existe."
            )
        }

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try faultInjector?(.stagingCreated)
            try writePatientManifest(plan.patient, under: stagingURL)
            for encounter in plan.encounters {
                try writeEncounter(encounter, under: stagingURL)
            }
            for document in plan.documents {
                try writeDocument(document, under: stagingURL)
            }
            try write(
                Data(htmlIndex(for: plan).utf8),
                to: stagingURL.appending(path: "index.html", directoryHint: .notDirectory)
            )
            try faultInjector?(.contentWritten)

            let refreshedVault = try VaultReader(fileManager: fileManager).open(sourceVaultURL)
            let refreshedPlan = try makePlan(scope: plan.scope, vault: refreshedVault)
            guard refreshedPlan == plan else {
                throw exportIssue(
                    "clinical_export.source_changed",
                    sourceVaultURL.path,
                    "O conteúdo clínico mudou durante a exportação. Tente novamente."
                )
            }

            guard !itemExistsIncludingSymbolicLink(destinationURL) else {
                throw exportIssue(
                    "clinical_export.destination_exists",
                    destinationURL.path,
                    "O destino passou a existir durante a exportação."
                )
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return ClinicalExportResult(
                directoryURL: destinationURL,
                encounterCount: plan.encounters.count,
                documentCount: plan.documents.count
            )
        } catch let operationError {
            guard itemExistsIncludingSymbolicLink(stagingURL) else { throw operationError }
            do {
                try faultInjector?(.beforeStagingCleanup)
                try fileManager.removeItem(at: stagingURL)
            } catch {
                throw exportIssue(
                    "clinical_export.cleanup_failed",
                    stagingURL.path,
                    "A exportação falhou e a pasta temporária não pôde ser removida. Remova-a manualmente antes de tentar novamente."
                )
            }
            throw operationError
        }
    }

    private func writePatientManifest(_ patient: PatientSummary, under root: URL) throws {
        guard patient.record != nil else { return }
        let source = patient.url.appending(path: "patient.yaml", directoryHint: .notDirectory)
        try requireSafeRegularFile(source)
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        let record = try VaultManifestValidator.validatePatient(data: data, source: source.path)
        guard record == patient.record, record.patientID == patient.patientID else {
            throw exportIssue(
                "clinical_export.patient_changed",
                patient.patientID,
                "O cadastro do paciente mudou durante a exportação."
            )
        }
        let directory = root.appending(path: "paciente", directoryHint: .isDirectory)
        try createDirectoryIfNeeded(directory)
        try write(data, to: directory.appending(path: "patient.yaml", directoryHint: .notDirectory))
    }

    private func writeEncounter(_ encounter: EncounterSummary, under root: URL) throws {
        let encounterID = encounter.metadata.encounterID
        let encounterRoot = root.appending(
            path: "consultas/\(encounterID)",
            directoryHint: .isDirectory
        )
        try createDirectoryIfNeeded(encounterRoot)

        try requireSafeRegularFile(encounter.url)
        let encounterData = try Data(contentsOf: encounter.url, options: [.mappedIfSafe])
        let refreshedMetadata = try ClinicalDocumentValidator.validateEncounter(
            data: encounterData,
            source: encounter.url.path
        )
        guard refreshedMetadata == encounter.metadata else {
            throw exportIssue(
                "clinical_export.encounter_changed",
                encounterID,
                "A consulta mudou durante a exportação."
            )
        }
        try ClinicalDocumentValidator.bind(
            encounter: refreshedMetadata,
            draft: encounter.draft.metadata,
            expectedPatientID: encounter.metadata.patientID
        )
        try write(
            encounterData,
            to: encounterRoot.appending(path: "\(encounterID).md", directoryHint: .notDirectory)
        )

        let draftDirectory = encounterRoot.appending(path: "rascunhos", directoryHint: .isDirectory)
        try createDirectoryIfNeeded(draftDirectory)
        try requireSafeRegularFile(encounter.draft.url)
        let draftData = try Data(contentsOf: encounter.draft.url, options: [.mappedIfSafe])
        let refreshedDraft = try ClinicalDocumentValidator.validateDraft(
            data: draftData,
            source: encounter.draft.url.path
        )
        guard draftData == encounter.draft.persistedData,
              refreshedDraft.metadata == encounter.draft.metadata,
              refreshedDraft.body == encounter.draft.body else {
            throw exportIssue(
                "clinical_export.draft_changed",
                encounterID,
                "O rascunho mudou durante a exportação."
            )
        }
        try write(
            draftData,
            to: draftDirectory.appending(
                path: "\(encounter.draft.metadata.noteID).md",
                directoryHint: .notDirectory
            )
        )

        guard case let .verified(finalization) = encounter.finalizationStatus else { return }
        try requireSafeRegularFile(finalization.finalNote.url)
        let finalData = try Data(contentsOf: finalization.finalNote.url, options: [.mappedIfSafe])
        guard finalData == finalization.finalNote.persistedData,
              digest(finalData) == finalization.finalNote.sha256 else {
            throw exportIssue(
                "clinical_export.final_hash_mismatch",
                encounterID,
                "A nota final mudou durante a exportação."
            )
        }
        let finalDirectory = encounterRoot.appending(path: "finais", directoryHint: .isDirectory)
        try createDirectoryIfNeeded(finalDirectory)
        try write(
            finalData,
            to: finalDirectory.appending(
                path: "\(finalization.finalNote.metadata.noteID).md",
                directoryHint: .notDirectory
            )
        )
        guard !finalization.addenda.isEmpty else { return }
        let addendaDirectory = encounterRoot.appending(path: "adendos", directoryHint: .isDirectory)
        try createDirectoryIfNeeded(addendaDirectory)
        for addendum in finalization.addenda {
            try requireSafeRegularFile(addendum.url)
            let addendumData = try Data(contentsOf: addendum.url, options: [.mappedIfSafe])
            guard addendumData == addendum.persistedData,
                  digest(addendumData) == addendum.sha256 else {
                throw exportIssue(
                    "clinical_export.addendum_hash_mismatch",
                    addendum.metadata.addendumID,
                    "Um adendo mudou durante a exportação."
                )
            }
            try write(
                addendumData,
                to: addendaDirectory.appending(
                    path: "\(addendum.metadata.addendumID).md",
                    directoryHint: .notDirectory
                )
            )
        }
    }

    private func writeDocument(_ document: RawAssetSummary, under root: URL) throws {
        try requireSafeRegularFile(document.originalURL)
        let data = try Data(contentsOf: document.originalURL, options: [.mappedIfSafe])
        guard data.count == document.sizeBytes, digest(data) == document.sha256 else {
            throw exportIssue(
                "clinical_export.document_hash_mismatch",
                document.assetID,
                "Um documento mudou durante a exportação."
            )
        }
        let directory = root.appending(path: "documentos", directoryHint: .isDirectory)
        try createDirectoryIfNeeded(directory)
        let fileName = "\(document.assetID).\(document.fileExtension)"
        let destination = directory.appending(path: fileName, directoryHint: .notDirectory)
        try write(data, to: destination)
        guard digest(try Data(contentsOf: destination, options: [.mappedIfSafe])) == document.sha256 else {
            throw exportIssue(
                "clinical_export.document_copy_hash_mismatch",
                document.assetID,
                "A cópia do documento não corresponde à origem verificada."
            )
        }
    }

    private func htmlIndex(for plan: ExportPlan) -> String {
        let patient = plan.patient
        let scopeTitle: String
        switch plan.scope {
        case .patient:
            scopeTitle = "Exportação do paciente"
        case .encounter:
            scopeTitle = "Exportação da consulta"
        }

        var sections: [String] = []
        sections.append("<h1>\(htmlEscape(scopeTitle))</h1>")
        sections.append("""
        <p><strong>Paciente:</strong> \(htmlEscape(patient.displayName))</p>
        <p><strong>Identificador:</strong> <code>\(htmlEscape(patient.patientID))</code></p>
        """)
        if let record = patient.record {
            sections.append(patientRecordHTML(record))
        }

        sections.append("<h2>Consultas</h2>")
        if plan.encounters.isEmpty {
            sections.append("<p>Nenhuma consulta reconhecida neste escopo.</p>")
        } else {
            sections.append(plan.encounters.map(encounterHTML).joined(separator: "\n"))
        }

        sections.append("<h2>Documentos</h2>")
        if plan.documents.isEmpty {
            sections.append("<p>Nenhum documento reconhecido neste escopo.</p>")
        } else {
            let items = plan.documents.map { document in
                let fileName = "\(document.assetID).\(document.fileExtension)"
                let binding = document.encounterID.map {
                    " Consulta: <code>\(htmlEscape($0))</code>."
                } ?? " Sem vínculo com consulta."
                return """
                <li><a href="documentos/\(fileName)">\(htmlEscape(document.originalName))</a> \
                (<code>\(htmlEscape(document.assetID))</code>, \(htmlEscape(document.mediaType))).\(binding)</li>
                """
            }.joined(separator: "\n")
            sections.append("<ul>\(items)</ul>")
        }

        sections.append("""
        <h2>Limites desta exportação</h2>
        <p>Esta pasta contém apenas dados clínicos reconhecidos pelo OpenPEP no momento da exportação. \
        Ela não inclui arquivos não gerenciados, o contexto do catálogo demonstrativo nem prescrições \
        ainda não reconciliadas. Esta exportação não substitui um backup restaurável e não comprova \
        autoria profissional fora do prontuário de origem.</p>
        """)

        return """
        <!doctype html>
        <html lang="pt-BR">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscape(scopeTitle))</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.5; \
              max-width: 56rem; margin: 2rem auto; padding: 0 1rem; color: #1d1d1f; }
            code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; padding: 1rem; background: #f5f5f7; }
            article { border-top: 1px solid #d2d2d7; margin-top: 2rem; padding-top: 1rem; }
          </style>
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private func patientRecordHTML(_ record: PatientRecord) -> String {
        var rows: [String] = []
        if let fullName = record.fullName {
            rows.append("<dt>Nome completo</dt><dd>\(htmlEscape(fullName))</dd>")
        }
        if let preferredName = record.preferredName {
            rows.append("<dt>Nome preferido</dt><dd>\(htmlEscape(preferredName))</dd>")
        }
        if let birthDate = record.birthDate {
            rows.append("<dt>Data de nascimento</dt><dd>\(htmlEscape(birthDate))</dd>")
        }
        let status = record.status == .active ? "Ativo" : "Arquivado"
        rows.append("<dt>Estado do cadastro</dt><dd>\(status)</dd>")
        for contact in record.contacts {
            rows.append("<dt>Contato (\(htmlEscape(contact.type.rawValue)))</dt><dd>\(htmlEscape(contact.value))</dd>")
        }
        for identifier in record.identifiers {
            rows.append("<dt>Identificador (\(htmlEscape(identifier.type.rawValue)))</dt><dd>\(htmlEscape(identifier.value))</dd>")
        }
        for alert in record.alerts {
            rows.append("<dt>Alerta (\(htmlEscape(alert.type.rawValue)))</dt><dd>\(htmlEscape(alert.description))</dd>")
        }
        return "<h2>Cadastro</h2><dl>\(rows.joined())</dl>"
    }

    private func encounterHTML(_ encounter: EncounterSummary) -> String {
        let encounterID = encounter.metadata.encounterID
        let noteBody: String
        let status: String
        let additions: String
        switch encounter.finalizationStatus {
        case .draft:
            status = "Rascunho"
            noteBody = encounter.draft.body
            additions = ""
        case let .verified(finalization):
            status = "Final verificado no prontuário de origem"
            noteBody = finalization.finalNote.body
            additions = finalization.addenda.map { addendum in
                """
                <h4>Adendo de \(htmlEscape(addendum.metadata.createdAt))</h4>
                <p><strong>Motivo:</strong> \(htmlEscape(addendum.metadata.reason))</p>
                <pre>\(htmlEscape(addendum.body))</pre>
                """
            }.joined(separator: "\n")
        case .altered:
            return ""
        }
        return """
        <article>
          <h3>Consulta de \(htmlEscape(encounter.metadata.startedAt))</h3>
          <p><strong>Identificador:</strong> <code>\(htmlEscape(encounterID))</code></p>
          <p><strong>Modalidade:</strong> \(htmlEscape(modalityLabel(encounter.metadata.modality)))</p>
          <p><strong>Estado:</strong> \(htmlEscape(status))</p>
          <p><a href="consultas/\(encounterID)/\(encounterID).md">Metadados canônicos da consulta</a></p>
          <pre>\(htmlEscape(noteBody))</pre>
          \(additions)
        </article>
        """
    }

    private func validateDestination(_ destinationURL: URL, outside vaultURL: URL) throws {
        guard !destinationURL.lastPathComponent.isEmpty else {
            throw exportIssue(
                "clinical_export.destination",
                destinationURL.path,
                "Escolha uma pasta nova para a exportação."
            )
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        try requireSafeDirectory(parentURL)
        guard !itemExistsIncludingSymbolicLink(destinationURL) else {
            throw exportIssue(
                "clinical_export.destination_exists",
                destinationURL.path,
                "Escolha uma pasta nova para a exportação."
            )
        }

        let resolvedVault = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedParent = parentURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = resolvedParent.appending(
            path: destinationURL.lastPathComponent,
            directoryHint: .isDirectory
        ).standardizedFileURL
        guard !isEqualOrDescendant(resolvedDestination, of: resolvedVault) else {
            throw exportIssue(
                "clinical_export.destination_inside_vault",
                destinationURL.path,
                "A exportação deve ficar fora do prontuário de origem."
            )
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try requireSafeDirectory(url)
    }

    private func write(_ data: Data, to url: URL) throws {
        guard !itemExistsIncludingSymbolicLink(url) else {
            throw exportIssue(
                "clinical_export.output_collision",
                url.path,
                "Dois itens da exportação tentaram usar o mesmo caminho."
            )
        }
        try data.write(to: url, options: [.withoutOverwriting])
    }

    private func requireSafeDirectory(_ url: URL) throws {
        try requireSafeAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw exportIssue(
                "clinical_export.unsafe_directory",
                url.path,
                "O caminho de exportação deve usar um diretório sem link simbólico."
            )
        }
    }

    private func requireSafeAncestors(of url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let type = try? fileManager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink,
               current.path != "/tmp",
               current.path != "/var" {
                throw exportIssue(
                    "clinical_export.unsafe_directory",
                    current.path,
                    "O caminho de exportação contém um link simbólico."
                )
            }
            current.deleteLastPathComponent()
        }
    }

    private func requireSafeRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw exportIssue(
                "clinical_export.unsafe_source",
                url.path,
                "A origem da exportação deve ser um arquivo regular sem link simbólico."
            )
        }
    }

    private func itemExistsIncludingSymbolicLink(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.type]) != nil
    }
}

private struct ExportPlan: Equatable {
    let scope: ClinicalExportScope
    let patient: PatientSummary
    let encounters: [EncounterSummary]
    let documents: [RawAssetSummary]
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isEqualOrDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
}

private func htmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func modalityLabel(_ value: String) -> String {
    switch value {
    case "in_person": "Presencial"
    case "telemedicine": "Teleconsulta"
    default: value
    }
}

private func exportIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
