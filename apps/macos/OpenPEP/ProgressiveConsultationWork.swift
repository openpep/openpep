// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ConsultationCaptureSource: String, Codable, Equatable, Sendable {
    case imported
    case microphone
    case telecall
}

enum ConsultationWorkStatus: String, Codable, Equatable, Sendable {
    case preparing
    case recording
    case transcribing
    case draining
    case ready
    case incomplete
    case failed
}

enum ConsultationSummaryBlockKind: String, Codable, Equatable, Sendable {
    case interval
    case correction
    case consolidated
}

enum ConsultationSummaryBlockState: String, Codable, Equatable, Sendable {
    case new
    case edited
    case added
    case needsReview = "needs_review"
}

struct ConsultationTimeRange: Codable, Equatable, Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var isApproximate: Bool

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case isApproximate = "is_approximate"
    }
}

struct ConsultationTranscriptSegmentReference: Codable, Equatable, Hashable, Sendable {
    let segmentID: String
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case revision
    }
}

struct ConsultationTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var revision: Int
    var range: ConsultationTimeRange
    var text: String
    let engine: String
    let model: String
    let attemptID: String

    enum CodingKeys: String, CodingKey {
        case id, revision, range, text, engine, model
        case attemptID = "attempt_id"
    }
}

struct ConsultationSummaryGeneration: Codable, Equatable, Sendable {
    let generationID: String
    let engine: String
    let model: String?
    let responseID: String?
    let promptVersion: String
    let generatedAt: Date
    let source: String
    let segmentReferences: [ConsultationTranscriptSegmentReference]

    enum CodingKeys: String, CodingKey {
        case engine, model, source
        case generationID = "generation_id"
        case responseID = "response_id"
        case promptVersion = "prompt_version"
        case generatedAt = "generated_at"
        case segmentReferences = "segment_references"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generationID, forKey: .generationID)
        try container.encode(engine, forKey: .engine)
        try encodeNullable(model, into: &container, forKey: .model)
        try encodeNullable(responseID, into: &container, forKey: .responseID)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(segmentReferences, forKey: .segmentReferences)
    }
}

struct ConsultationSummaryAcceptance: Codable, Equatable, Sendable {
    let acceptanceID: String
    let acceptedBy: String
    let acceptedAt: Date
    let acceptedText: String
    let sourceAssetID: String

    enum CodingKeys: String, CodingKey {
        case acceptanceID = "acceptance_id"
        case acceptedBy = "accepted_by"
        case acceptedAt = "accepted_at"
        case acceptedText = "accepted_text"
        case sourceAssetID = "source_asset_id"
    }
}

struct ConsultationSummaryBlock: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: ConsultationSummaryBlockKind
    var range: ConsultationTimeRange
    var subject: String
    let generatedText: String
    var editedText: String
    var state: ConsultationSummaryBlockState
    let generation: ConsultationSummaryGeneration
    var acceptance: ConsultationSummaryAcceptance?

    enum CodingKeys: String, CodingKey {
        case id, kind, range, subject, state, generation, acceptance
        case generatedText = "generated_text"
        case editedText = "edited_text"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(range, forKey: .range)
        try container.encode(subject, forKey: .subject)
        try container.encode(generatedText, forKey: .generatedText)
        try container.encode(editedText, forKey: .editedText)
        try container.encode(state, forKey: .state)
        try container.encode(generation, forKey: .generation)
        try encodeNullable(acceptance, into: &container, forKey: .acceptance)
    }
}

enum ConsultationSummaryItemState: String, Codable, Equatable, Sendable {
    case proposed
    case professional
    case needsReview = "needs_review"
}

struct ConsultationSummaryItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var state: ConsultationSummaryItemState
    var segmentReferences: [ConsultationTranscriptSegmentReference]

    enum CodingKeys: String, CodingKey {
        case id, text, state
        case segmentReferences = "segment_references"
    }
}

enum ConsultationSummaryRevisionOrigin: String, Codable, Equatable, Sendable {
    case model
    case professional
}

enum ConsultationSummaryRevisionKind: String, Codable, Equatable, Sendable {
    case update
    case noChange = "no_change"
}

struct ConsultationSummaryRevision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sequence: Int
    let baseRevision: Int
    let savedAt: Date
    let origin: ConsultationSummaryRevisionOrigin
    let kind: ConsultationSummaryRevisionKind
    let affectedItemIDs: [String]
    let segmentReferences: [ConsultationTranscriptSegmentReference]
    let beforeText: String
    let afterText: String
    let computedDiff: String
    let generation: ConsultationSummaryGeneration?

    enum CodingKeys: String, CodingKey {
        case id, sequence, origin, kind, generation
        case baseRevision = "base_revision"
        case savedAt = "saved_at"
        case affectedItemIDs = "affected_item_ids"
        case segmentReferences = "segment_references"
        case beforeText = "before_text"
        case afterText = "after_text"
        case computedDiff = "computed_diff"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(origin, forKey: .origin)
        try container.encode(kind, forKey: .kind)
        try container.encode(affectedItemIDs, forKey: .affectedItemIDs)
        try container.encode(segmentReferences, forKey: .segmentReferences)
        try container.encode(beforeText, forKey: .beforeText)
        try container.encode(afterText, forKey: .afterText)
        try container.encode(computedDiff, forKey: .computedDiff)
        try encodeNullable(generation, into: &container, forKey: .generation)
    }
}

struct ConsultationIncrementalSummary: Codable, Equatable, Sendable {
    var revision: Int
    var coveredSegmentReferences: [ConsultationTranscriptSegmentReference]
    var items: [ConsultationSummaryItem]
    var revisions: [ConsultationSummaryRevision]
    var acceptance: ConsultationSummaryAcceptance?

    enum CodingKeys: String, CodingKey {
        case revision, items, revisions, acceptance
        case coveredSegmentReferences = "covered_segment_references"
    }

    static var empty: Self {
        .init(revision: 0, coveredSegmentReferences: [], items: [], revisions: [], acceptance: nil)
    }

    var text: String {
        items.map(\.text).joined(separator: "\n")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(coveredSegmentReferences, forKey: .coveredSegmentReferences)
        try container.encode(items, forKey: .items)
        try container.encode(revisions, forKey: .revisions)
        try encodeNullable(acceptance, into: &container, forKey: .acceptance)
    }
}

enum ConsultationSummaryDiff {
    static func make(before: String, after: String) -> String {
        guard before != after else { return "" }
        let oldLines = before.isEmpty ? []
            : before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = after.isEmpty ? []
            : after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changes: [String] = []
        for index in 0..<max(oldLines.count, newLines.count) {
            let old = oldLines.indices.contains(index) ? oldLines[index] : nil
            let new = newLines.indices.contains(index) ? newLines[index] : nil
            guard old != new else { continue }
            if let old { changes.append("-\(index + 1): \(old)") }
            if let new { changes.append("+\(index + 1): \(new)") }
        }
        return changes.joined(separator: "\n")
    }
}

struct ProgressiveConsultationCapture: Codable, Equatable, Sendable {
    var source: ConsultationCaptureSource
    var status: ConsultationWorkStatus
    var attemptID: String
    var startedAt: Date?
    var endedAt: Date?
    var capturedSeconds: Double
    var audioFilename: String?
    var audioFilenames: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case source, status
        case attemptID = "attempt_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case capturedSeconds = "captured_seconds"
        case audioFilename = "audio_filename"
        case audioFilenames = "audio_filenames"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(status, forKey: .status)
        try container.encode(attemptID, forKey: .attemptID)
        try encodeNullable(startedAt, into: &container, forKey: .startedAt)
        try encodeNullable(endedAt, into: &container, forKey: .endedAt)
        try container.encode(capturedSeconds, forKey: .capturedSeconds)
        try encodeNullable(audioFilename, into: &container, forKey: .audioFilename)
        try container.encodeIfPresent(audioFilenames, forKey: .audioFilenames)
    }
}

struct ProgressiveConsultationWork: Codable, Equatable, Sendable {
    static let legacySchema = "openpep/progressive-summary-work@1"
    static let schema = "openpep/progressive-summary-work@2"

    var schema: String
    let sessionID: String
    let vaultID: String
    let patientID: String
    let encounterID: String
    let createdAt: Date
    var updatedAt: Date
    var summaryIntervalSeconds: Int
    var capture: ProgressiveConsultationCapture
    var transcriptionEngine: String
    var transcriptionModel: String
    var summaryEngine: String
    var summaryModel: String?
    var segments: [ConsultationTranscriptSegment]
    var blocks: [ConsultationSummaryBlock]
    var summary: ConsultationIncrementalSummary?
    var pendingRanges: [ConsultationTimeRange]
    var status: ConsultationWorkStatus
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case schema, capture, segments, blocks, summary, status
        case sessionID = "session_id"
        case vaultID = "vault_id"
        case patientID = "patient_id"
        case encounterID = "encounter_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case summaryIntervalSeconds = "summary_interval_seconds"
        case transcriptionEngine = "transcription_engine"
        case transcriptionModel = "transcription_model"
        case summaryEngine = "summary_engine"
        case summaryModel = "summary_model"
        case pendingRanges = "pending_ranges"
        case lastError = "last_error"
    }

    init(
        binding: EncounterTranscriptionBinding,
        source: ConsultationCaptureSource,
        summaryIntervalSeconds: Int,
        transcriptionEngine: String,
        transcriptionModel: String,
        summaryEngine: String,
        summaryModel: String?,
        now: Date = Date()
    ) {
        schema = Self.schema
        sessionID = "session_\(UUID().uuidString.lowercased())"
        vaultID = binding.vaultID
        patientID = binding.patientID
        encounterID = binding.encounterID
        createdAt = now
        updatedAt = now
        self.summaryIntervalSeconds = summaryIntervalSeconds
        capture = ProgressiveConsultationCapture(
            source: source,
            status: .preparing,
            attemptID: "attempt_\(UUID().uuidString.lowercased())",
            startedAt: nil,
            endedAt: nil,
            capturedSeconds: 0,
            audioFilename: nil
        )
        self.transcriptionEngine = transcriptionEngine
        self.transcriptionModel = transcriptionModel
        self.summaryEngine = summaryEngine
        self.summaryModel = summaryModel
        segments = []
        blocks = []
        summary = .empty
        pendingRanges = []
        status = .preparing
        lastError = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(vaultID, forKey: .vaultID)
        try container.encode(patientID, forKey: .patientID)
        try container.encode(encounterID, forKey: .encounterID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(summaryIntervalSeconds, forKey: .summaryIntervalSeconds)
        try container.encode(capture, forKey: .capture)
        try container.encode(transcriptionEngine, forKey: .transcriptionEngine)
        try container.encode(transcriptionModel, forKey: .transcriptionModel)
        try container.encode(summaryEngine, forKey: .summaryEngine)
        try encodeNullable(summaryModel, into: &container, forKey: .summaryModel)
        try container.encode(segments, forKey: .segments)
        try container.encode(blocks, forKey: .blocks)
        if schema != Self.legacySchema {
            try container.encode(summary ?? .empty, forKey: .summary)
        }
        try container.encode(pendingRanges, forKey: .pendingRanges)
        try container.encode(status, forKey: .status)
        try encodeNullable(lastError, into: &container, forKey: .lastError)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        vaultID = try container.decode(String.self, forKey: .vaultID)
        patientID = try container.decode(String.self, forKey: .patientID)
        encounterID = try container.decode(String.self, forKey: .encounterID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        summaryIntervalSeconds = try container.decode(Int.self, forKey: .summaryIntervalSeconds)
        capture = try container.decode(ProgressiveConsultationCapture.self, forKey: .capture)
        transcriptionEngine = try container.decode(String.self, forKey: .transcriptionEngine)
        transcriptionModel = try container.decode(String.self, forKey: .transcriptionModel)
        summaryEngine = try container.decode(String.self, forKey: .summaryEngine)
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
        segments = try container.decode([ConsultationTranscriptSegment].self, forKey: .segments)
        blocks = try container.decodeIfPresent([ConsultationSummaryBlock].self, forKey: .blocks) ?? []
        summary = try container.decodeIfPresent(ConsultationIncrementalSummary.self, forKey: .summary)
        pendingRanges = try container.decode([ConsultationTimeRange].self, forKey: .pendingRanges)
        status = try container.decode(ConsultationWorkStatus.self, forKey: .status)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    mutating func migrateToCurrentSchema() {
        guard schema == Self.legacySchema else { return }
        var aggregate = ConsultationIncrementalSummary.empty
        let intervalBlocks = blocks.filter { $0.kind != .consolidated }
        let consolidated = blocks.last(where: { $0.kind == .consolidated })
        let sourceBlocks = consolidated.map { [$0] }
            ?? (intervalBlocks.isEmpty ? Array(blocks.suffix(1)) : intervalBlocks)
        for block in sourceBlocks {
            let before = aggregate.text
            let itemID = block.id.replacingOccurrences(of: "block_", with: "summary_item_")
            let text = block.acceptance?.acceptedText ?? normalizedSummaryItem(block.editedText)
            guard !text.isEmpty else { continue }
            aggregate.items.append(.init(
                id: itemID,
                text: text,
                state: block.acceptance != nil ? .professional
                    : (block.state == .needsReview ? .needsReview : .proposed),
                segmentReferences: block.generation.segmentReferences
            ))
            let after = aggregate.text
            let sequence = aggregate.revision + 1
            aggregate.revisions.append(.init(
                id: block.id.replacingOccurrences(of: "block_", with: "revision_"),
                sequence: sequence,
                baseRevision: aggregate.revision,
                savedAt: block.generation.generatedAt,
                origin: .model,
                kind: .update,
                affectedItemIDs: [itemID],
                segmentReferences: block.generation.segmentReferences,
                beforeText: before,
                afterText: after,
                computedDiff: ConsultationSummaryDiff.make(before: before, after: after),
                generation: block.generation
            ))
            aggregate.revision = sequence
        }
        aggregate.coveredSegmentReferences = Array(Set(sourceBlocks.flatMap {
            $0.generation.segmentReferences
        })).sorted { $0.segmentID < $1.segmentID }
        if sourceBlocks.count == 1 {
            aggregate.acceptance = sourceBlocks[0].acceptance
        }
        summary = aggregate
        blocks = []
        schema = Self.schema
    }
}

private func normalizedSummaryItem(_ text: String) -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }
    return value.hasPrefix("- ") ? value : "- \(value)"
}

private func encodeNullable<Key: CodingKey, Value: Encodable>(
    _ value: Value?,
    into container: inout KeyedEncodingContainer<Key>,
    forKey key: Key
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

enum ProgressiveConsultationWorkIssue: Error, LocalizedError, Equatable, Sendable {
    case invalidBinding
    case invalidDocument(String)
    case unsafeFile
    case revisionConflict

    var errorDescription: String? {
        switch self {
        case .invalidBinding:
            "O rascunho de acompanhamento pertence a outra consulta."
        case let .invalidDocument(message):
            "O rascunho de acompanhamento é inválido: \(message)"
        case .unsafeFile:
            "O arquivo de acompanhamento não é um arquivo regular seguro."
        case .revisionConflict:
            "O rascunho de acompanhamento mudou durante a gravação. Reabra a consulta antes de continuar."
        }
    }
}

struct ProgressiveConsultationWorkStore: @unchecked Sendable {
    static let directoryName = "consultation-work"
    static let maximumDocumentBytes = 16 * 1_024 * 1_024

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(binding: EncounterTranscriptionBinding) throws -> ProgressiveConsultationWork? {
        let url = workURL(binding: binding)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let document = try decode(at: url)
        try validate(document, binding: binding)
        return document
    }

    @discardableResult
    func save(
        _ document: ProgressiveConsultationWork,
        binding: EncounterTranscriptionBinding,
        expectedData: Data? = nil
    ) throws -> Data {
        try validate(document, binding: binding)
        let data = try encode(document)
        let contentURL = binding.vaultURL.appending(
            path: "patients/\(binding.patientID)/content",
            directoryHint: .isDirectory
        )
        let directoryURL = contentURL.appending(path: Self.directoryName, directoryHint: .isDirectory)
        let destinationURL = directoryURL.appending(path: "\(binding.encounterID).json")
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: contentURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            do {
                try requireDirectory(contentURL)
                try ensureDirectory(directoryURL)
                if let expectedData {
                    guard fileManager.fileExists(atPath: destinationURL.path),
                          try safeData(at: destinationURL) == expectedData else {
                        throw ProgressiveConsultationWorkIssue.revisionConflict
                    }
                }
                try data.write(to: destinationURL, options: [.atomic])
                guard try safeData(at: destinationURL) == data else {
                    throw ProgressiveConsultationWorkIssue.revisionConflict
                }
                _ = try decode(at: destinationURL)
                result = .success(data)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProgressiveConsultationWorkIssue.revisionConflict }
        return try result.get()
    }

    func data(binding: EncounterTranscriptionBinding) throws -> Data? {
        let url = workURL(binding: binding)
        return fileManager.fileExists(atPath: url.path) ? try safeData(at: url) : nil
    }

    func documents(in contentURL: URL, patientID: String) throws -> [ProgressiveConsultationWork] {
        let directoryURL = contentURL.appending(path: Self.directoryName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        try requireDirectory(directoryURL)
        return try managedDirectoryEntries(in: directoryURL, fileManager: fileManager).map { url in
            guard url.pathExtension == "json" else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("o diretório contém um arquivo inesperado")
            }
            let document = try decode(at: url)
            guard document.patientID == patientID,
                  url.deletingPathExtension().lastPathComponent == document.encounterID else {
                throw ProgressiveConsultationWorkIssue.invalidBinding
            }
            return document
        }
    }

    func workURL(binding: EncounterTranscriptionBinding) -> URL {
        binding.vaultURL.appending(
            path: "patients/\(binding.patientID)/content/\(Self.directoryName)/\(binding.encounterID).json"
        )
    }

    func encode(_ document: ProgressiveConsultationWork) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0a)
        guard data.count <= Self.maximumDocumentBytes else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("o documento excede 16 MiB")
        }
        return data
    }

    func decode(data: Data) throws -> ProgressiveConsultationWork {
        guard data.count <= Self.maximumDocumentBytes else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("o documento excede 16 MiB")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document: ProgressiveConsultationWork
        do {
            document = try decoder.decode(ProgressiveConsultationWork.self, from: data)
        } catch {
            throw ProgressiveConsultationWorkIssue.invalidDocument("o JSON não corresponde ao contrato @1")
        }
        document.migrateToCurrentSchema()
        try validate(document)
        return document
    }

    func validate(
        _ document: ProgressiveConsultationWork,
        binding: EncounterTranscriptionBinding? = nil
    ) throws {
        guard document.schema == ProgressiveConsultationWork.schema,
              validPrefixedUUID(document.sessionID, prefix: "session_"),
              validPrefixedUUID(document.vaultID, prefix: "vlt_"),
              OpenPEPIdentifier.isPatient(document.patientID),
              OpenPEPIdentifier.isEncounter(document.encounterID),
              validPrefixedUUID(document.capture.attemptID, prefix: "attempt_"),
              (60...300).contains(document.summaryIntervalSeconds),
              document.updatedAt >= document.createdAt,
              document.capture.capturedSeconds.isFinite,
              document.capture.capturedSeconds >= 0,
              safeProvider(document.transcriptionEngine),
              safeProvider(document.transcriptionModel),
              safeProvider(document.summaryEngine),
              document.summaryModel.map(safeProvider) != false,
              document.segments.count <= 50_000,
              document.blocks.isEmpty,
              document.pendingRanges.count <= 10_000 else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("campos básicos fora dos limites")
        }
        if let binding, document.vaultID != binding.vaultID || document.patientID != binding.patientID
            || document.encounterID != binding.encounterID {
            throw ProgressiveConsultationWorkIssue.invalidBinding
        }
        if let startedAt = document.capture.startedAt,
           let endedAt = document.capture.endedAt,
           endedAt < startedAt {
            throw ProgressiveConsultationWorkIssue.invalidDocument("o encerramento antecede o início")
        }
        if let audioFilename = document.capture.audioFilename,
           !safeFilename(audioFilename) {
            throw ProgressiveConsultationWorkIssue.invalidDocument("o nome do áudio não é seguro")
        }

        if let filenames = document.capture.audioFilenames {
            guard !filenames.isEmpty, filenames.count <= 1000,
                  Set(filenames).count == filenames.count,
                  filenames.allSatisfy(safeFilename),
                  filenames.last == document.capture.audioFilename else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("lista de áudios inválida")
            }
        }

        var segmentKeys = Set<ConsultationTranscriptSegmentReference>()
        var segmentIDs = Set<String>()
        var previousEnd = 0.0
        for segment in document.segments {
            guard validPrefixedUUID(segment.id, prefix: "segment_"),
                  segmentIDs.insert(segment.id).inserted,
                  segment.revision > 0,
                  validRange(segment.range),
                  segment.range.startSeconds >= previousEnd,
                  segment.attemptID == document.capture.attemptID,
                  safeText(segment.text, maximum: 200_000),
                  safeProvider(segment.engine),
                  safeProvider(segment.model),
                  validPrefixedUUID(segment.attemptID, prefix: "attempt_"),
                  segment.attemptID == document.capture.attemptID else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("segmento inválido ou fora de ordem")
            }
            previousEnd = segment.range.endSeconds
            segmentKeys.insert(.init(segmentID: segment.id, revision: segment.revision))
        }

        guard let summary = document.summary else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("resumo incremental ausente")
        }
        try validate(summary, segmentKeys: segmentKeys)
        guard document.pendingRanges.allSatisfy(validRange) else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("intervalo pendente inválido")
        }
        if let lastError = document.lastError,
           !safeText(lastError, maximum: 1_000) {
            throw ProgressiveConsultationWorkIssue.invalidDocument("erro técnico fora dos limites")
        }
    }

    private func validate(
        _ summary: ConsultationIncrementalSummary,
        segmentKeys: Set<ConsultationTranscriptSegmentReference>
    ) throws {
        guard summary.revision >= 0,
              summary.items.count <= 1_000,
              summary.revisions.count <= 10_000,
              summary.coveredSegmentReferences.allSatisfy(segmentKeys.contains),
              Set(summary.coveredSegmentReferences).count == summary.coveredSegmentReferences.count else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("resumo incremental fora dos limites")
        }
        var itemIDs = Set<String>()
        for item in summary.items {
            guard validPrefixedUUID(item.id, prefix: "summary_item_"),
                  itemIDs.insert(item.id).inserted,
                  safeText(item.text, maximum: 500_000),
                  !item.segmentReferences.isEmpty,
                  item.segmentReferences.allSatisfy(segmentKeys.contains),
                  Set(item.segmentReferences).count == item.segmentReferences.count else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("item de resumo inválido")
            }
        }
        var revisionIDs = Set<String>()
        var generationIDs = Set<String>()
        var expectedSequence = 1
        for revision in summary.revisions {
            guard validPrefixedUUID(revision.id, prefix: "revision_"),
                  revisionIDs.insert(revision.id).inserted,
                  revision.sequence == expectedSequence,
                  revision.baseRevision == expectedSequence - 1,
                  revision.savedAt >= documentEpoch,
                  revision.affectedItemIDs.allSatisfy({
                      validPrefixedUUID($0, prefix: "summary_item_")
                  }),
                  revision.segmentReferences.allSatisfy(segmentKeys.contains),
                  revision.beforeText.utf8.count <= 500_000,
                  revision.afterText.utf8.count <= 500_000,
                  revision.computedDiff.utf8.count <= 1_000_000,
                  revision.computedDiff == ConsultationSummaryDiff.make(
                    before: revision.beforeText, after: revision.afterText
                  ),
                  (revision.kind == .noChange) == (revision.beforeText == revision.afterText) else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("revisão de resumo inválida")
            }
            if revision.origin == .model {
                guard let generation = revision.generation,
                      validPrefixedUUID(generation.generationID, prefix: "gen_"),
                      generationIDs.insert(generation.generationID).inserted,
                      safeProvider(generation.engine),
                      generation.model.map(safeProvider) != false,
                      generation.responseID.map(safeProvider) != false,
                      safeProvider(generation.promptVersion),
                      safeText(generation.source, maximum: 2_000_000),
                      !generation.segmentReferences.isEmpty,
                      generation.segmentReferences.allSatisfy(segmentKeys.contains) else {
                    throw ProgressiveConsultationWorkIssue.invalidDocument("geração de resumo inválida")
                }
            } else if revision.generation != nil || revision.kind == .noChange {
                throw ProgressiveConsultationWorkIssue.invalidDocument("revisão profissional inválida")
            }
            expectedSequence += 1
        }
        guard summary.revision == summary.revisions.count,
              summary.text == (summary.revisions.last?.afterText ?? "") else {
            throw ProgressiveConsultationWorkIssue.invalidDocument("revisão e texto do resumo divergem")
        }
        if let acceptance = summary.acceptance {
            guard validPrefixedUUID(acceptance.acceptanceID, prefix: "acceptance_"),
                  OpenPEPIdentifier.isUser(acceptance.acceptedBy),
                  safeText(acceptance.acceptedText, maximum: 500_000),
                  acceptance.acceptedText == summary.text,
                  OpenPEPIdentifier.isAsset(acceptance.sourceAssetID) else {
                throw ProgressiveConsultationWorkIssue.invalidDocument("aceitação do resumo inválida")
            }
        }
    }

    private var documentEpoch: Date { Date(timeIntervalSince1970: 0) }

    private func decode(at url: URL) throws -> ProgressiveConsultationWork {
        try decode(data: safeData(at: url))
    }

    private func safeData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? Self.maximumDocumentBytes + 1) <= Self.maximumDocumentBytes else {
            throw ProgressiveConsultationWorkIssue.unsafeFile
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try requireDirectory(url)
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProgressiveConsultationWorkIssue.unsafeFile
        }
    }

    private func validRange(_ range: ConsultationTimeRange) -> Bool {
        range.startSeconds.isFinite && range.endSeconds.isFinite
            && range.startSeconds >= 0 && range.endSeconds >= range.startSeconds
            && range.endSeconds <= 24 * 60 * 60
    }

    private func safeProvider(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func safeText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
            && value == value.precomposedStringWithCanonicalMapping
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func validPrefixedUUID(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString.lowercased() == suffix
    }
}
