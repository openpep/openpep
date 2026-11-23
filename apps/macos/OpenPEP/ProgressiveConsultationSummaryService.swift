// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import FoundationModels

enum ProgressiveSummaryProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case apple = "apple"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .apple: "Apple Intelligence neste Mac"
        }
    }
}

struct ProgressiveSummaryRequest: Equatable, Sendable {
    let baseRevision: Int
    let currentItems: [ConsultationSummaryItem]
    let newSegments: [ConsultationTranscriptSegment]
    let verificationSegments: [ConsultationTranscriptSegment]
    let historicalSegments: [ConsultationTranscriptSegment]
    let isFinalReview: Bool

    init(
        baseRevision: Int,
        currentItems: [ConsultationSummaryItem],
        newSegments: [ConsultationTranscriptSegment],
        verificationSegments: [ConsultationTranscriptSegment],
        historicalSegments: [ConsultationTranscriptSegment] = [],
        isFinalReview: Bool = false
    ) {
        self.baseRevision = baseRevision
        self.currentItems = currentItems
        self.newSegments = newSegments
        self.verificationSegments = verificationSegments
        self.historicalSegments = historicalSegments
        self.isFinalReview = isFinalReview
    }

    var availableReferences: Set<ConsultationTranscriptSegmentReference> {
        Set((verificationSegments + newSegments).map {
            .init(segmentID: $0.id, revision: $0.revision)
        })
    }

    var newReferences: [ConsultationTranscriptSegmentReference] {
        newSegments.map { .init(segmentID: $0.id, revision: $0.revision) }
    }
}

enum ProgressiveSummaryOperationKind: String, Codable, Equatable, Sendable {
    case add
    case replace
    case flag
}

struct ProgressiveSummaryOperation: Equatable, Sendable {
    let action: ProgressiveSummaryOperationKind
    let targetItemID: String?
    let text: String
    let references: [ConsultationTranscriptSegmentReference]
}

struct ProgressiveSummaryEngineOutput: Equatable, Sendable {
    let operations: [ProgressiveSummaryOperation]
    let engine: String
    let model: String?
    let responseID: String?
    let promptVersion: String?

    init(
        operations: [ProgressiveSummaryOperation],
        engine: String,
        model: String?,
        responseID: String?,
        promptVersion: String? = nil
    ) {
        self.operations = operations
        self.engine = engine
        self.model = model
        self.responseID = responseID
        self.promptVersion = promptVersion
    }
}

struct ProgressiveSummaryUpdate: Equatable, Sendable {
    let items: [ConsultationSummaryItem]
    let revision: ConsultationSummaryRevision
}

protocol ProgressiveSummaryGenerating: Sendable {
    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput
}

enum ProgressiveSummaryIssue: Error, LocalizedError, Equatable, Sendable {
    case noStableText
    case invalidResponse
    case inputCannotBeBounded
    case providerUnavailable
    case providerBusy
    case refused

    var errorDescription: String? {
        switch self {
        case .noStableText:
            "Ainda não há texto estabilizado para resumir."
        case .invalidResponse:
            "O provedor devolveu uma atualização em formato inválido. O resumo anterior foi preservado."
        case .inputCannotBeBounded:
            "O resumo e suas fontes não cabem com segurança no modelo local. Nenhum trecho foi omitido."
        case .providerUnavailable:
            "O modelo local não está disponível para gerar o resumo agora."
        case .providerBusy:
            "O modelo local está ocupado. O resumo será tentado novamente."
        case .refused:
            "O modelo local recusou este pedido. O resumo anterior foi preservado."
        }
    }
}

struct ProgressiveConsultationSummaryService: Sendable {
    static let promptVersion = AIPromptCatalog.progressiveConsultationSummary.id

    private let generator: any ProgressiveSummaryGenerating
    private let now: @Sendable () -> Date
    private let generationID: @Sendable (Date) throws -> String
    private let revisionID: @Sendable () -> String
    private let itemID: @Sendable () -> String

    init(
        generator: any ProgressiveSummaryGenerating,
        now: @escaping @Sendable () -> Date = Date.init,
        generationID: @escaping @Sendable (Date) throws -> String = {
            "gen_\(try UUIDv7.generate(at: $0))"
        },
        revisionID: @escaping @Sendable () -> String = {
            "revision_\(UUID().uuidString.lowercased())"
        },
        itemID: @escaping @Sendable () -> String = {
            "summary_item_\(UUID().uuidString.lowercased())"
        }
    ) {
        self.generator = generator
        self.now = now
        self.generationID = generationID
        self.revisionID = revisionID
        self.itemID = itemID
    }

    @MainActor
    static func configured(
        provider: ProgressiveSummaryProvider,
        model: String?
    ) -> ProgressiveConsultationSummaryService {
        switch provider {
        case .openAI:
            ProgressiveConsultationSummaryService(
                generator: OpenAIProgressiveSummaryGenerator(
                    model: model ?? AITextSettings.defaultConsultationSummaryModel
                )
            )
        case .apple:
            ProgressiveConsultationSummaryService(generator: AppleFinalSummaryGenerator())
        }
    }

    func generateUpdate(for request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryUpdate {
        guard !request.newSegments.isEmpty,
              !request.newSegments.allSatisfy({
                  $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw ProgressiveSummaryIssue.noStableText
        }
        var effectiveRequest = request
        var output: ProgressiveSummaryEngineOutput
        var verificationPasses = 0
        while true {
            output = bindReferences(
                try await generator.generate(effectiveRequest),
                to: effectiveRequest.newReferences
            )
            try Task.checkCancellation()
            let included = effectiveRequest.availableReferences
            let targetIDs = Set(output.operations.compactMap { operation in
                operation.action == .add ? nil : operation.targetItemID
            })
            let required = Set(request.currentItems.filter {
                targetIDs.contains($0.id)
            }.flatMap(\.segmentReferences))
            let missing = required.subtracting(included)
            guard !missing.isEmpty else { break }
            verificationPasses += 1
            guard verificationPasses <= min(max(1, request.currentItems.count), 16) else {
                throw ProgressiveSummaryIssue.inputCannotBeBounded
            }
            let additional = request.historicalSegments.filter {
                missing.contains(.init(segmentID: $0.id, revision: $0.revision))
            }
            guard Set(additional.map {
                ConsultationTranscriptSegmentReference(segmentID: $0.id, revision: $0.revision)
            }) == missing else {
                throw ProgressiveSummaryIssue.invalidResponse
            }
            effectiveRequest = ProgressiveSummaryRequest(
                baseRevision: request.baseRevision,
                currentItems: request.currentItems,
                newSegments: request.newSegments,
                verificationSegments: uniqueSegments(
                    effectiveRequest.verificationSegments + additional
                ),
                historicalSegments: request.historicalSegments,
                isFinalReview: request.isFinalReview
            )
        }
        // The wire schema permits 16 operations, including final corrections.
        // The per-minute target is a prompt guideline, not a reason to discard facts.
        guard output.operations.count <= 16 else {
            throw ProgressiveSummaryIssue.invalidResponse
        }

        let available = effectiveRequest.availableReferences
        let newReferences = Set(request.newReferences)
        let originalItems = request.currentItems
        var items = originalItems
        var affectedIDs: [String] = []

        for operation in output.operations {
            let text = normalizedItem(operation.text)
            guard !text.isEmpty,
                  text.utf8.count <= 20_000,
                  !text.contains("?"),
                  !operation.references.isEmpty,
                  operation.references.allSatisfy(available.contains),
                  !newReferences.isDisjoint(with: operation.references) else {
                throw ProgressiveSummaryIssue.invalidResponse
            }
            switch operation.action {
            case .add:
                guard operation.targetItemID == nil else { throw ProgressiveSummaryIssue.invalidResponse }
                guard !items.contains(where: { normalizedForComparison($0.text) == normalizedForComparison(text) }) else {
                    continue
                }
                let id = itemID()
                items.append(.init(id: id, text: text, state: .proposed,
                                   segmentReferences: unique(operation.references)))
                affectedIDs.append(id)
            case .replace:
                guard let targetID = operation.targetItemID,
                      let index = items.firstIndex(where: { $0.id == targetID }) else {
                    throw ProgressiveSummaryIssue.invalidResponse
                }
                if items[index].state == .professional {
                    let reviewText = normalizedItem("Revisar possível correção: \(text)")
                    guard !items.contains(where: {
                        $0.state == .needsReview
                            && normalizedForComparison($0.text) == normalizedForComparison(reviewText)
                    }) else { continue }
                    let id = itemID()
                    items.append(.init(
                        id: id,
                        text: reviewText,
                        state: .needsReview,
                        segmentReferences: unique(items[index].segmentReferences + operation.references)
                    ))
                    affectedIDs.append(id)
                } else {
                    items[index].text = text
                    items[index].state = .proposed
                    items[index].segmentReferences = unique(
                        items[index].segmentReferences + operation.references
                    )
                    affectedIDs.append(targetID)
                }
            case .flag:
                guard operation.targetItemID == nil || items.contains(where: {
                    $0.id == operation.targetItemID
                }) else { throw ProgressiveSummaryIssue.invalidResponse }
                let id = itemID()
                let targetReferences = items.first(where: {
                    $0.id == operation.targetItemID
                })?.segmentReferences ?? []
                let reviewText = normalizedItem("Revisar divergência: \(text)")
                guard !items.contains(where: {
                    $0.state == .needsReview
                        && normalizedForComparison($0.text) == normalizedForComparison(reviewText)
                }) else { continue }
                items.append(.init(
                    id: id,
                    text: reviewText,
                    state: .needsReview,
                    segmentReferences: unique(targetReferences + operation.references)
                ))
                affectedIDs.append(id)
            }
        }

        let before = summaryText(originalItems)
        let after = summaryText(items)
        let changed = before != after
        let generatedAt = now()
        let references = unique(
            effectiveRequest.verificationSegments.map {
                .init(segmentID: $0.id, revision: $0.revision)
            } + request.newReferences
        )
        let generation = ConsultationSummaryGeneration(
            generationID: try generationID(generatedAt),
            engine: output.engine,
            model: output.model,
            responseID: output.responseID,
            promptVersion: output.promptVersion ?? Self.promptVersion,
            generatedAt: generatedAt,
            source: Self.sourceText(for: effectiveRequest),
            segmentReferences: references
        )
        return ProgressiveSummaryUpdate(
            items: items,
            revision: ConsultationSummaryRevision(
                id: revisionID(),
                sequence: request.baseRevision + 1,
                baseRevision: request.baseRevision,
                savedAt: generatedAt,
                origin: .model,
                kind: changed ? .update : .noChange,
                affectedItemIDs: affectedIDs,
                segmentReferences: request.newReferences,
                beforeText: before,
                afterText: after,
                computedDiff: ConsultationSummaryDiff.make(before: before, after: after),
                generation: generation
            )
        )
    }

    static func sourceText(for request: ProgressiveSummaryRequest) -> String {
        var parts = [request.isFinalReview ? "<modo>revisao_final</modo>" : "<modo>atualizacao_incremental</modo>",
                     "<resumo_atual_nao_confiavel>"]
        if request.currentItems.isEmpty {
            parts.append("(vazio)")
        } else {
            parts.append(contentsOf: request.currentItems.enumerated().map { index, item in
                "[item_index=\(index + 1) estado=\(item.state.rawValue)] \(item.text)"
            })
        }
        parts.append("</resumo_atual_nao_confiavel>")
        if !request.verificationSegments.isEmpty {
            parts.append("<fontes_anteriores_para_conferencia>")
            parts.append(contentsOf: request.verificationSegments.map(segmentLine))
            parts.append("</fontes_anteriores_para_conferencia>")
        }
        parts.append("<novo_intervalo>")
        parts.append(contentsOf: request.newSegments.map(segmentLine))
        parts.append("</novo_intervalo>")
        if !request.isFinalReview {
            parts.append("<meta_de_concisao>\(maximumAdditions(for: request.newSegments)) tópicos novos; não omita fatos essenciais para cumprir a meta.</meta_de_concisao>")
        }
        return parts.joined(separator: "\n") + "\n"
    }

    static let instructions = AIPromptCatalog.progressiveConsultationSummary.instructions

    private static func maximumAdditions(
        for segments: [ConsultationTranscriptSegment]
    ) -> Int {
        guard let start = segments.map(\.range.startSeconds).min(),
              let end = segments.map(\.range.endSeconds).max() else { return 2 }
        let minutes = max(1, Int(ceil(max(0, end - start) / 60)))
        return minutes * 2
    }

    private static func segmentLine(_ segment: ConsultationTranscriptSegment) -> String {
        let start = duration(segment.range.startSeconds)
        let end = duration(segment.range.endSeconds)
        return "[\(segment.id)@\(segment.revision) \(start)-\(end)] \(segment.text)"
    }

    private static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func normalizedItem(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("- ") ? value : "- \(value)"
    }

    private func normalizedForComparison(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func summaryText(_ items: [ConsultationSummaryItem]) -> String {
        items.map(\.text).joined(separator: "\n")
    }

    private func unique(
        _ references: [ConsultationTranscriptSegmentReference]
    ) -> [ConsultationTranscriptSegmentReference] {
        var seen = Set<ConsultationTranscriptSegmentReference>()
        return references.filter { seen.insert($0).inserted }
    }

    private func uniqueSegments(
        _ segments: [ConsultationTranscriptSegment]
    ) -> [ConsultationTranscriptSegment] {
        var seen = Set<ConsultationTranscriptSegmentReference>()
        return segments.filter {
            seen.insert(.init(segmentID: $0.id, revision: $0.revision)).inserted
        }
    }

    private func bindReferences(
        _ output: ProgressiveSummaryEngineOutput,
        to references: [ConsultationTranscriptSegmentReference]
    ) -> ProgressiveSummaryEngineOutput {
        ProgressiveSummaryEngineOutput(
            operations: output.operations.map { operation in
                let target = operation.targetItemID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ProgressiveSummaryOperation(
                    action: operation.action,
                    targetItemID: operation.action == .add || target?.isEmpty == true ? nil : target,
                    text: operation.text,
                    references: references
                )
            },
            engine: output.engine,
            model: output.model,
            responseID: output.responseID,
            promptVersion: output.promptVersion
        )
    }
}

private struct ProgressiveSummaryPayload: Decodable {
    struct Operation: Decodable {
        let action: ProgressiveSummaryOperationKind
        let targetItemIndex: Int?
        let text: String
        let segmentReferences: [Reference]?

        enum CodingKeys: String, CodingKey {
            case action, text
            case targetItemIndex = "target_item_index"
            case segmentReferences = "segment_references"
        }
    }

    struct Reference: Decodable {
        let segmentID: String
        let revision: Int

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case revision
        }
    }

    let operations: [Operation]
}

func progressiveOperations(
    from text: String,
    currentItems: [ConsultationSummaryItem]
) throws -> [ProgressiveSummaryOperation] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: Substring
    if trimmed.hasPrefix("```"),
       let firstBreak = trimmed.firstIndex(of: "\n"),
       let closing = trimmed.range(of: "```", options: .backwards),
       closing.lowerBound > firstBreak {
        json = trimmed[trimmed.index(after: firstBreak)..<closing.lowerBound]
    } else {
        json = Substring(trimmed)
    }
    guard let payload = try? JSONDecoder().decode(
        ProgressiveSummaryPayload.self, from: Data(json.utf8)
    ) else { throw ProgressiveSummaryIssue.invalidResponse }
    return try payload.operations.map { operation in
        let targetItemID: String?
        if operation.action == .add {
            targetItemID = nil
        } else if let index = operation.targetItemIndex {
            guard index > 0, currentItems.indices.contains(index - 1) else {
                throw ProgressiveSummaryIssue.invalidResponse
            }
            targetItemID = currentItems[index - 1].id
        } else {
            targetItemID = nil
        }
        return ProgressiveSummaryOperation(
            action: operation.action,
            targetItemID: targetItemID,
            text: operation.text,
            references: (operation.segmentReferences ?? []).map {
                .init(segmentID: $0.segmentID, revision: $0.revision)
            }
        )
    }
}


/// The local model only synthesizes source text after capture. It does not have
/// to maintain item indices or fit an ever-growing summary in its context.
private actor AppleFinalSummaryGenerator: ProgressiveSummaryGenerating {
    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        let proposal = try await ConsultationSummaryService(engine: AppleFinalSummaryEngine()).propose(
            from: request.newSegments.map(\.text).joined(separator: "\n"),
            includeSourceMarkers: false
        )
        return .init(
            operations: [.init(action: .add, targetItemID: nil, text: proposal.text, references: [])],
            engine: ConsultationSummaryProvenance.engine, model: nil, responseID: nil,
            promptVersion: AIPromptCatalog.finalConsultationSummaryApple.id
        )
    }
}

@Generable
private struct AppleFinalSummaryPayload {
    @Guide(description: "Tópicos clínicos concisos, preservando fatos essenciais e negações", .maximumCount(12))
    var items: [String]
}

private actor AppleFinalSummaryEngine: ConsultationSummaryEngine {
    private let model = SystemLanguageModel.default
    private static let instructions = AIPromptCatalog.finalConsultationSummaryApple.instructions

    func availability(for locale: Locale) async -> ConsultationSummaryAvailability {
        await AppleConsultationSummaryEngine().availability(for: locale)
    }

    func accepts(_ source: String, sourceLabel: String, locale: Locale) async throws -> Bool {
        if #available(macOS 26.4, *) {
            let instructions = try await model.tokenCount(for: Instructions(Self.instructions))
            let input = try await model.tokenCount(for: Prompt(source))
            let schema = try await model.tokenCount(for: AppleFinalSummaryPayload.generationSchema)
            return instructions + input + schema + 1_200 <= model.contextSize
        }
        return source.utf8.count <= 2_000
    }

    func summarize(_ source: String, sourceLabel: String, locale: Locale) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(
            to: source, generating: AppleFinalSummaryPayload.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1_024)
        )
        return response.content.items.joined(separator: "\n")
    }
}

private actor OpenAIProgressiveSummaryGenerator: ProgressiveSummaryGenerating {
    let model: String

    init(model: String) { self.model = model }

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        let result = try await AITextSettings.configuredConsultationSummaryRequest(
            input: ProgressiveConsultationSummaryService.sourceText(for: request),
            instructions: ProgressiveConsultationSummaryService.instructions,
            model: model,
            responseFormat: .progressiveSummary
        )
        return ProgressiveSummaryEngineOutput(
            operations: try progressiveOperations(
                from: result.text,
                currentItems: request.currentItems
            ),
            engine: "openai/responses",
            model: result.model,
            responseID: result.responseID,
            promptVersion: AIPromptCatalog.progressiveConsultationSummary.id
        )
    }
}
