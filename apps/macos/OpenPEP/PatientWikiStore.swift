// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct PatientWikiSource: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let sha256: String
}

struct PatientWikiSummaryInput: Equatable, Sendable {
    let markdown: String
    let sourceFingerprint: String
    let model: String
    let generatedAt: String
    let sources: [PatientWikiSource]
    var overview: String? = nil
    var exclusions: PatientWikiExclusions? = nil
    var proposals: [PatientWikiFact] = []
    var promptVersion: String? = nil
    var omittedFactCount: Int = 0
}

struct PatientWikiSummary: Equatable, Sendable {
    let markdown: String
    let sourceFingerprint: String
    let model: String
    let generatedAt: String
    let sources: [PatientWikiSource]
    let overview: String?
    let exclusions: PatientWikiExclusions?
    let proposals: [PatientWikiFact]
    let promptVersion: String?
    let omittedFactCount: Int
    let persistedData: Data

    init(
        markdown: String,
        sourceFingerprint: String,
        model: String,
        generatedAt: String,
        sources: [PatientWikiSource],
        overview: String?,
        exclusions: PatientWikiExclusions?,
        proposals: [PatientWikiFact],
        promptVersion: String? = nil,
        omittedFactCount: Int = 0,
        persistedData: Data
    ) {
        self.markdown = markdown
        self.sourceFingerprint = sourceFingerprint
        self.model = model
        self.generatedAt = generatedAt
        self.sources = sources
        self.overview = overview
        self.exclusions = exclusions
        self.proposals = proposals
        self.promptVersion = promptVersion
        self.omittedFactCount = omittedFactCount
        self.persistedData = persistedData
    }
}

struct PatientWikiCorrections: Equatable, Sendable {
    let markdown: String
    let persistedData: Data
}

struct PatientWikiSnapshot: Equatable, Sendable {
    let summary: PatientWikiSummary?
    let corrections: PatientWikiCorrections?
    let summaryIssue: String?
    let correctionsIssue: String?
}

enum PatientWikiWriteStep: Equatable, Sendable {
    case candidateWritten
    case published
}

struct PatientWikiStore {
    typealias FaultInjector = (PatientWikiWriteStep) throws -> Void

    private struct SummaryHeader: Codable, Equatable {
        let schema: String
        let patientID: String
        let sourceFingerprint: String
        let model: String
        let generatedAt: String
        let sources: [PatientWikiSource]
        let overview: String?
        let exclusions: PatientWikiExclusions?
        let proposals: [PatientWikiFact]?
        let promptVersion: String?
        let omittedFactCount: Int?

        enum CodingKeys: String, CodingKey {
            case schema
            case patientID = "patient_id"
            case sourceFingerprint = "source_fingerprint"
            case model
            case generatedAt = "generated_at"
            case sources
            case overview, exclusions, proposals
            case promptVersion = "prompt_version"
            case omittedFactCount = "omitted_fact_count"
        }
    }

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func load(for patient: PatientSummary) throws -> PatientWikiSnapshot {
        let wikiURL = try validatedWikiDirectory(for: patient)
        let summaryURL = wikiURL.appending(path: "summary.md", directoryHint: .notDirectory)
        let correctionsURL = wikiURL.appending(path: "corrections.md", directoryHint: .notDirectory)

        var summary: PatientWikiSummary?
        var summaryIssue: String?
        do {
            if let data = try readManagedFileIfPresent(summaryURL) {
                summary = try decodeSummary(data, patientID: patient.patientID, source: summaryURL.path)
            }
        } catch {
            summaryIssue = wikiIssueText(error)
        }

        var corrections: PatientWikiCorrections?
        var correctionsIssue: String?
        do {
            if let data = try readManagedFileIfPresent(correctionsURL) {
                corrections = PatientWikiCorrections(
                    markdown: try decodeMarkdown(
                        data,
                        maximumBytes: 256 * 1_024,
                        source: correctionsURL.path
                    ),
                    persistedData: data
                )
            }
        } catch {
            correctionsIssue = wikiIssueText(error)
        }

        return PatientWikiSnapshot(
            summary: summary,
            corrections: corrections,
            summaryIssue: summaryIssue,
            correctionsIssue: correctionsIssue
        )
    }

    func saveSummary(
        for patient: PatientSummary,
        input: PatientWikiSummaryInput,
        expectedData: Data?,
        expectedCorrectionsData: Data?,
        validateSources: () throws -> Void = {}
    ) throws -> PatientWikiSummary {
        let normalizedMarkdown = try normalizeMarkdown(input.markdown, maximumBytes: 1_048_576)
        let header = SummaryHeader(
            schema: input.proposals.contains(where: \.requiresIPSSchema) ? "openpep/patient-wiki@4" : input.promptVersion == nil
                ? (input.overview == nil ? "openpep/patient-wiki@1" : "openpep/patient-wiki@2")
                : "openpep/patient-wiki@3",
            patientID: patient.patientID,
            sourceFingerprint: input.sourceFingerprint,
            model: input.model,
            generatedAt: input.generatedAt,
            sources: input.sources,
            overview: input.overview?.precomposedStringWithCanonicalMapping,
            exclusions: input.exclusions,
            proposals: input.overview == nil ? nil : input.proposals,
            promptVersion: input.promptVersion,
            omittedFactCount: input.overview == nil ? nil : input.omittedFactCount
        )
        try validate(header, expectedPatientID: patient.patientID)
        let candidateData = try encodeSummary(header: header, markdown: normalizedMarkdown)
        let wikiURL = try validatedWikiDirectory(for: patient)
        let summaryURL = wikiURL.appending(path: "summary.md", directoryHint: .notDirectory)
        let correctionsURL = wikiURL.appending(path: "corrections.md", directoryHint: .notDirectory)

        try coordinatedWrite(wikiURL) { coordinatedWiki in
            let destination = coordinatedWiki.appending(path: summaryURL.lastPathComponent)
            let corrections = coordinatedWiki.appending(path: correctionsURL.lastPathComponent)
            try assertExpectedData(expectedCorrectionsData, at: corrections)
            try publish(candidateData, to: destination, expectedData: expectedData) {
                try validateSources()
                try assertExpectedData(expectedCorrectionsData, at: corrections)
            }
        }
        let summary = try decodeSummary(candidateData, patientID: patient.patientID, source: summaryURL.path)
        PatientClinicalChange.post(for: patient)
        return summary
    }

    func saveCorrections(
        for patient: PatientSummary,
        markdown: String,
        expectedData: Data?
    ) throws -> PatientWikiCorrections {
        let normalized = try normalizeMarkdown(markdown, maximumBytes: 256 * 1_024)
        let candidateData = Data(normalized.utf8)
        let wikiURL = try validatedWikiDirectory(for: patient)
        let correctionsURL = wikiURL.appending(path: "corrections.md", directoryHint: .notDirectory)
        try coordinatedWrite(wikiURL) { coordinatedWiki in
            try publish(
                candidateData,
                to: coordinatedWiki.appending(path: correctionsURL.lastPathComponent),
                expectedData: expectedData
            ) {}
        }
        PatientClinicalChange.post(for: patient)
        return PatientWikiCorrections(markdown: normalized, persistedData: candidateData)
    }

    /// Professional selection after a published generation; never inferred by AI.
    func removeConfirmedCorrectionLines(
        for patient: PatientSummary,
        lineIndices: Set<Int>,
        generatedSummaryData: Data,
        usedCorrectionsData: Data,
        validateSources: () throws -> Void = {}
    ) throws -> PatientWikiCorrections {
        let markdown = try decodeMarkdown(usedCorrectionsData, maximumBytes: 256 * 1_024, source: "corrections.md")
        let lines = markdown.components(separatedBy: "\n")
        guard !lineIndices.isEmpty,
              lineIndices.allSatisfy({ lines.indices.contains($0) && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw wikiIssue("wiki.correction_selection", "/", "Selecione somente as correções que conferiu no resumo atualizado.")
        }
        let remaining = lines.enumerated().filter { !lineIndices.contains($0.offset) }.map(\.element).joined(separator: "\n")
        let normalized = try normalizeMarkdown(remaining, maximumBytes: 256 * 1_024)
        let candidateData = Data(normalized.utf8)
        let wikiURL = try validatedWikiDirectory(for: patient)
        try coordinatedWrite(wikiURL) { coordinatedWiki in
            let summary = coordinatedWiki.appending(path: "summary.md")
            let corrections = coordinatedWiki.appending(path: "corrections.md")
            try assertExpectedData(generatedSummaryData, at: summary)
            try publish(candidateData, to: corrections, expectedData: usedCorrectionsData) {
                try assertExpectedData(generatedSummaryData, at: summary)
                try validateSources()
            }
        }
        // Corrections participate in the fingerprint; trigger ordinary revalidation.
        PatientClinicalChange.post(for: patient)
        return PatientWikiCorrections(markdown: normalized, persistedData: candidateData)
    }

    func coordinatedWrite(_ wikiURL: URL, operation: (URL) throws -> Void) throws {
        var outcome: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: wikiURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedWiki in
            do {
                try requireDirectory(coordinatedWiki)
                try operation(coordinatedWiki)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw wikiIssue("filesystem.coordination", wikiURL.path, "A escrita coordenada da wiki não foi concluída.")
        }
        try outcome.get()
    }

    func publish(
        _ candidateData: Data,
        to destination: URL,
        expectedData: Data?,
        validateCompanion: () throws -> Void
    ) throws {
        try assertExpectedData(expectedData, at: destination)
        let token = UUID().uuidString.lowercased()
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appending(path: ".openpep-wiki-\(token)")
        let backup = directory.appending(path: ".openpep-wiki-backup-\(token)")
        var preserveBackup = false
        defer {
            if pathExists(temporary) { try? fileManager.removeItem(at: temporary) }
            if !preserveBackup, pathExists(backup) { try? fileManager.removeItem(at: backup) }
        }

        try candidateData.write(to: temporary, options: [.withoutOverwriting])
        try requireRegularFile(temporary)
        guard try Data(contentsOf: temporary) == candidateData else {
            throw wikiIssue("wiki.reopen_mismatch", temporary.path, "O candidato da wiki diverge dos bytes preparados.")
        }
        try faultInjector?(.candidateWritten)
        try assertExpectedData(expectedData, at: destination)
        try validateCompanion()

        let destinationExisted = expectedData != nil
        do {
            if destinationExisted {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: backup.lastPathComponent,
                    options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try faultInjector?(.published)
            try validateCompanion()
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination) == candidateData else {
                throw wikiIssue("wiki.reopen_mismatch", destination.path, "A wiki reaberta diverge da escrita validada.")
            }
            if destinationExisted { try fileManager.removeItem(at: backup) }
        } catch {
            let publicationError = error
            do {
                try recoverPublication(
                    destination: destination,
                    backup: backup,
                    expectedData: expectedData,
                    candidateData: candidateData
                )
            } catch let recoveryError {
                preserveBackup = true
                throw wikiIssue("wiki.rollback_failed", backup.path,
                                "A recuperação da wiki falhou; o estado concorrente e o backup foram preservados. \(recoveryError.localizedDescription)")
            }
            throw publicationError
        }
    }

    private func recoverPublication(
        destination: URL,
        backup: URL,
        expectedData: Data?,
        candidateData: Data
    ) throws {
        let current = try dataIfRegularFile(at: destination)
        if let expectedData {
            if current == expectedData { return }
            guard current == candidateData, pathExists(backup) else {
                throw wikiIssue("wiki.rollback_conflict", destination.path,
                                "A wiki mudou durante a recuperação e não foi substituída.")
            }
            _ = try fileManager.replaceItemAt(destination, withItemAt: backup)
            guard try dataIfRegularFile(at: destination) == expectedData else {
                throw wikiIssue("wiki.rollback_mismatch", destination.path,
                                "A recuperação não restaurou os bytes anteriores da wiki.")
            }
        } else if current == candidateData {
            try fileManager.removeItem(at: destination)
        } else if pathExists(destination) {
            throw wikiIssue("wiki.rollback_conflict", destination.path,
                            "A wiki mudou durante a recuperação e não foi removida.")
        }
    }

    func validatedWikiDirectory(for patient: PatientSummary) throws -> URL {
        guard OpenPEPIdentifier.isPatient(patient.patientID),
              patient.url.lastPathComponent == patient.patientID else {
            throw wikiIssue("wiki.patient_binding", patient.patientID, "A wiki não pertence a um paciente válido.")
        }
        let wikiURL = patient.url.appending(path: "wiki", directoryHint: .isDirectory)
        try requireDirectory(wikiURL)
        return wikiURL
    }

    func readManagedFileIfPresent(_ url: URL) throws -> Data? {
        guard pathExists(url) else { return nil }
        try requireRegularFile(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_097_152 else {
            throw wikiIssue("wiki.maximum_size", url.path, "O arquivo da wiki excede 2 MiB.")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func assertExpectedData(_ expectedData: Data?, at url: URL) throws {
        let exists = pathExists(url)
        if let expectedData {
            guard exists, try dataIfRegularFile(at: url) == expectedData else {
                throw wikiIssue("wiki.revision_conflict", url.path, "A wiki mudou. Reabra antes de salvar.")
            }
        } else if exists {
            throw wikiIssue("wiki.revision_conflict", url.path, "A wiki foi criada por outra edição. Reabra antes de salvar.")
        }
    }

    private func dataIfRegularFile(at url: URL) throws -> Data? {
        guard pathExists(url) else { return nil }
        try requireRegularFile(url)
        return try Data(contentsOf: url)
    }

    private func encodeSummary(header: SummaryHeader, markdown: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = try encoder.encode(header)
        guard let metadataText = String(data: metadata, encoding: .utf8) else {
            throw wikiIssue("wiki.encoding", "/", "Os metadados da wiki não puderam ser codificados.")
        }
        let data = Data(("---\n" + metadataText + "\n---\n" + markdown).utf8)
        guard data.count <= 2 * 1_048_576 else {
            throw wikiIssue("wiki.maximum_size", "/", "A página da wiki excede 2 MiB.")
        }
        return data
    }

    private func decodeSummary(_ data: Data, patientID: String, source: String) throws -> PatientWikiSummary {
        guard data.count <= 2 * 1_048_576,
              !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0x0d }),
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.utf8),
              text.hasPrefix("---\n") else {
            throw wikiIssue("wiki.format", source, "A página deve ser Markdown UTF-8, NFC e LF com metadados JSON.")
        }
        let metadataStart = text.index(text.startIndex, offsetBy: 4)
        guard let separator = text.range(of: "\n---\n", range: metadataStart..<text.endIndex) else {
            throw wikiIssue("wiki.format", source, "O frontmatter JSON da página não foi encerrado.")
        }
        let metadataText = String(text[metadataStart..<separator.lowerBound])
        let header: SummaryHeader
        do {
            header = try JSONDecoder().decode(SummaryHeader.self, from: Data(metadataText.utf8))
        } catch {
            throw wikiIssue("wiki.metadata", source, "Os metadados JSON da página são inválidos.")
        }
        try validate(header, expectedPatientID: patientID)
        let markdown = String(text[separator.upperBound...])
        guard markdown.utf8.count <= 1_048_576 else {
            throw wikiIssue("wiki.maximum_size", source, "O resumo excede 1 MiB.")
        }
        return PatientWikiSummary(
            markdown: markdown,
            sourceFingerprint: header.sourceFingerprint,
            model: header.model,
            generatedAt: header.generatedAt,
            sources: header.sources,
            overview: header.overview,
            exclusions: header.exclusions,
            proposals: header.proposals ?? [],
            promptVersion: header.promptVersion,
            omittedFactCount: header.omittedFactCount ?? 0,
            persistedData: data
        )
    }

    private func validate(_ header: SummaryHeader, expectedPatientID: String) throws {
        guard ["openpep/patient-wiki@1", "openpep/patient-wiki@2", "openpep/patient-wiki@3", "openpep/patient-wiki@4"].contains(header.schema) else {
            throw wikiIssue("wiki.schema", "/schema", "O schema da wiki não é reconhecido.")
        }
        let structured = header.schema != "openpep/patient-wiki@1"
        let version3 = ["openpep/patient-wiki@3", "openpep/patient-wiki@4"].contains(header.schema)
        if structured {
            guard let overview = header.overview, isSafeShortText(overview, maximum: 8_000),
                  let exclusions = header.exclusions, exclusions.isValid,
                  let proposals = header.proposals, proposals.count <= 100,
                  (0...100).contains(header.omittedFactCount ?? 0) else {
                throw wikiIssue("wiki.metadata", "/", "Resumo breve ou cobertura inválidos.")
            }
            for fact in proposals {
                try fact.validate()
                guard header.schema == "openpep/patient-wiki@4" || !fact.requiresIPSSchema else { throw OpenAITextIssue.invalidResponse }
                guard fact.patientID == expectedPatientID, header.sources.contains(fact.source) else {
                    throw wikiIssue("wiki.fact_source", "/proposals", "Proposta sem fonte correspondente.")
                }
            }
            guard Set(proposals.map(\.id)).count == proposals.count else {
                throw wikiIssue("wiki.fact_duplicate", "/proposals", "Proposta duplicada.")
            }
        } else if header.overview != nil || header.exclusions != nil || header.proposals != nil
                    || header.omittedFactCount != nil {
            throw wikiIssue("wiki.metadata", "/", "Metadados da versão 2 exigem schema próprio.")
        }
        if version3 {
            guard let promptVersion = header.promptVersion,
                  AIPromptCatalog.definition(id: promptVersion)?.purpose == .patientWiki else {
                throw wikiIssue("wiki.prompt_version", "/prompt_version", "A revisão do prompt da wiki não é reconhecida.")
            }
        } else if header.promptVersion != nil {
            throw wikiIssue("wiki.prompt_version", "/prompt_version", "A revisão do prompt exige schema próprio.")
        }
        guard header.patientID == expectedPatientID, OpenPEPIdentifier.isPatient(header.patientID) else {
            throw wikiIssue("wiki.patient_binding", "/patient_id", "A página pertence a outro paciente.")
        }
        guard isSHA256(header.sourceFingerprint) else {
            throw wikiIssue("wiki.source_fingerprint", "/source_fingerprint", "O fingerprint das fontes não é SHA-256.")
        }
        guard isSafeShortText(header.model, maximum: 200) else {
            throw wikiIssue("wiki.model", "/model", "O identificador do modelo é inválido.")
        }
        guard isUTCTimestamp(header.generatedAt) else {
            throw wikiIssue("wiki.generated_at", "/generated_at", "generated_at deve ser uma data UTC válida.")
        }
        guard header.sources.count <= 1_000 else {
            throw wikiIssue("wiki.sources", "/sources", "A página excede o limite de fontes.")
        }
        var ids = Set<String>()
        var paths = Set<String>()
        for (index, source) in header.sources.enumerated() {
            let registration = structured && source.id == expectedPatientID && source.path == "patient.yaml"
            guard registration || isWikiSourceID(source.id) else {
                throw wikiIssue("wiki.source_id", "/sources/\(index)/id", "O identificador da fonte não é permitido.")
            }
            guard registration || isSafeSourcePath(source.path) else {
                throw wikiIssue("wiki.source_path", "/sources/\(index)/path", "O caminho da fonte não é seguro ou aponta para rascunho.")
            }
            guard isSHA256(source.sha256) else {
                throw wikiIssue("wiki.source_hash", "/sources/\(index)/sha256", "O hash da fonte não é SHA-256.")
            }
            guard ids.insert(source.id).inserted, paths.insert(source.path).inserted else {
                throw wikiIssue("wiki.source_duplicate", "/sources/\(index)", "Uma fonte aparece mais de uma vez.")
            }
        }
    }

    private func normalizeMarkdown(_ value: String, maximumBytes: Int) throws -> String {
        var normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        guard !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw wikiIssue("wiki.markdown", "/", "O Markdown contém um caractere inválido.")
        }
        while normalized.hasSuffix("\n") { normalized.removeLast() }
        if !normalized.isEmpty { normalized.append("\n") }
        guard normalized.utf8.count <= maximumBytes else {
            throw wikiIssue("wiki.maximum_size", "/", "O Markdown excede o limite permitido.")
        }
        return normalized
    }

    private func decodeMarkdown(_ data: Data, maximumBytes: Int, source: String) throws -> String {
        guard data.count <= maximumBytes,
              !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0x0d || $0.value == 0 }),
              text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.utf8) else {
            throw wikiIssue("wiki.markdown", source, "As correções devem usar Markdown UTF-8, NFC e LF.")
        }
        return text
    }

    private func isSafeShortText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
            && value == value.precomposedStringWithCanonicalMapping
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    func isWikiSourceID(_ value: String) -> Bool {
        OpenPEPIdentifier.isEncounter(value)
            || OpenPEPIdentifier.isAsset(value)
            || value.range(
                of: "^add_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression
            ) != nil
    }

    func isSafeSourcePath(_ value: String) -> Bool {
        guard value.count <= 1_000,
              value == value.precomposedStringWithCanonicalMapping,
              !value.hasPrefix("/"),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value != 0 && !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return value.hasPrefix("content/notes/final/")
            || value.hasPrefix("content/notes/addenda/")
            || value.hasPrefix("raw/")
    }

    private func isUTCTimestamp(_ value: String) -> Bool {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw wikiIssue("filesystem.directory", url.path, "wiki deve ser um diretório sem link simbólico.")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw wikiIssue("filesystem.regular_file", url.path, "O arquivo da wiki deve ser regular e sem link simbólico.")
        }
    }
}

private func wikiIssueText(_ error: Error) -> String {
    if let issue = error as? VaultValidationIssue { return issue.message }
    return error.localizedDescription
}

private func wikiIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
