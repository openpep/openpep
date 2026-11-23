// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct PatientWikiExclusions: Codable, Equatable, Sendable {
    var drafts = 0
    var aiProvenance = 0
    var unavailable = 0

    var description: String {
        "Fora desta geração: \(drafts) rascunhos ou documentos provisórios; "
        + "\(aiProvenance) fontes de propostas de IA; \(unavailable) registros sem texto utilizável."
    }

    var isValid: Bool { [drafts, aiProvenance, unavailable].allSatisfy { (0...100_000).contains($0) } }
}

/// Wiki-specific context: does not broaden the source contract of transient AI answers.
struct PatientWikiContext: Sendable {
    let patient: PatientSummary
    let writingAllowed: Bool
    let entries: [PatientHistoryEntry]
    let exclusions: PatientWikiExclusions
    let fingerprint: String
    let input: String

    static func load(context: PatientHistoryContext, corrections: String) throws -> Self {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(context.vaultURL)
        guard let patient = vault.patients.first(where: { $0.patientID == context.patientID }) else {
            throw PatientAIIssue.patientUnavailable
        }
        let history = try PatientHistoryReader().load(patientID: context.patientID,
            vaultURL: context.vaultURL, authorizationURL: context.authorizationURL)
        return try make(patient: patient, entries: history.entries, corrections: corrections,
                        writingAllowed: vault.writingAllowed)
    }

    static func make(patient: PatientSummary, entries all: [PatientHistoryEntry],
                     corrections: String, writingAllowed: Bool = true) throws -> Self {
        let clinical = try PatientAIContext.make(patient: patient, entries: all,
            corrections: corrections, writingAllowed: writingAllowed)
        var entries = clinical.entries
        if let record = patient.record {
            guard record.patientID == patient.patientID else { throw PatientAIIssue.patientUnavailable }
            var lines: [String] = []
            if let name = record.fullName { lines.append("Nome cadastrado: \(name)") }
            if let name = record.preferredName { lines.append("Nome de preferência: \(name)") }
            if let birth = record.birthDate { lines.append("Data de nascimento: \(birth)") }
            for alert in record.alerts {
                lines.append("Alerta cadastrado (\(alert.type.rawValue)), registrado em \(alert.recordedAt): "
                             + "\(alert.description). Origem informada: \(alert.source)")
            }
            if !lines.isEmpty {
                entries.append(PatientHistoryEntry(id: patient.patientID, title: "Cadastro selecionado",
                    timestamp: record.updatedAt, status: "Cadastro; não é confirmação clínica atual",
                    text: lines.joined(separator: "\n"), source: "patient.yaml", assetID: nil, issue: nil))
            }
        }
        let selected = Set(clinical.entries.map(\.id))
        let provenance = Set(patient.encounters.flatMap { $0.draft.metadata.sourceIDs })
        let drafts = Set(patient.encounters.filter { $0.finalizationStatus == .draft }.map { $0.metadata.encounterID })
        let provisional = Set(patient.rawAssets.filter { $0.encounterID.map(drafts.contains) == true }.map(\.assetID))
        var exclusions = PatientWikiExclusions()
        for entry in all where !selected.contains(entry.id) {
            if entry.assetID.map(provenance.contains) == true { exclusions.aiProvenance += 1 }
            else if entry.source.hasPrefix("content/notes/drafts/") || entry.assetID.map(provisional.contains) == true {
                exclusions.drafts += 1
            } else { exclusions.unavailable += 1 }
        }
        let pieces = entries.enumerated().map { index, entry in
            "[F\(index + 1)] \(entry.title) · \(entry.timestamp) · \(entry.status)\n\(UnifiedPrescription.clinicalText(entry.text))"
        }
        var input = pieces.joined(separator: "\n\n")
        if let last = entries.enumerated().filter({ $0.element.source.hasPrefix("content/notes/final/") })
            .max(by: { $0.element.timestamp < $1.element.timestamp }) {
            input += "\n\nÚltimo atendimento finalizado elegível: \(last.element.timestamp) [F\(last.offset + 1)]."
        }
        input += "\n\nCobertura calculada pelo aplicativo: \(exclusions.description)"
        input += "\n\nCorreções humanas (orientações separadas; não criam diagnóstico confirmado):\n" + corrections
        guard input.count <= PatientAIContext.maximumCharacters else { throw PatientAIIssue.tooLong }
        let fingerprint = PatientAIContext.digest(Data(("wiki-003-v1\n" + PatientWikiGeneration.prompt.id + "\n"
            + PatientWikiGeneration.instructions + "\n" + clinical.fingerprint + "\n" + input).utf8))
        return Self(patient: patient, writingAllowed: writingAllowed, entries: entries,
                    exclusions: exclusions, fingerprint: fingerprint, input: input)
    }
}

enum PatientWikiTopic: String, Codable, CaseIterable, Sendable {
    case person, problems, medications, allergies, symptoms, results, examination, lifestyle, plan, conflicts

    var title: String {
        switch self {
        case .person: "Pessoa e contexto de vida"
        case .problems: "Problemas e diagnósticos documentados"
        case .medications: "Medicamentos e tratamentos"
        case .allergies: "Alergias e intolerâncias"
        case .symptoms: "Sintomas e trajetória"
        case .results: "Exames e resultados"
        case .examination: "Sinais vitais e exame físico"
        case .lifestyle: "Estilo de vida"
        case .plan: "Plano e pendências documentadas"
        case .conflicts: "Divergências"
        }
    }
}

enum PatientWikiGenerationIssue: Error, LocalizedError, Equatable, Sendable {
    case overviewTooLong(wordCount: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case let .overviewTooLong(wordCount, maximum):
            "O resumo breve retornado tem \(wordCount) palavras; o limite é \(maximum). O resumo anterior foi mantido."
        }
    }
}

/// Safe local reason for rejecting a provider response. It deliberately carries
/// only schema locations and bounded counts, never returned text or raw errors.
struct PatientWikiGenerationDiagnostic: Equatable, Sendable {
    enum Code: String, Sendable {
        case responseTooLarge
        case malformedJSON
        case invalidSourceCount
        case tooManySections
        case duplicateSection
        case overviewTooLong
        case invalidParagraphCount
        case emptyParagraph
        case paragraphTooLong
        case paragraphControlCharacters
        case paragraphMarkup
        case emptySources
        case tooManySources
        case duplicateSource
        case unknownSource
    }

    let code: Code
    let sectionIndex: Int?
    let paragraphIndex: Int?
    let sourceIndex: Int?
    let count: Int?
    let maximum: Int?

    init(code: Code, sectionIndex: Int? = nil, paragraphIndex: Int? = nil,
         sourceIndex: Int? = nil, count: Int? = nil, maximum: Int? = nil) {
        self.code = code
        self.sectionIndex = sectionIndex
        self.paragraphIndex = paragraphIndex
        self.sourceIndex = sourceIndex
        self.count = count
        self.maximum = maximum
    }

    var message: String {
        switch code {
        case .responseTooLarge: "A resposta excedeu o limite local antes da validação. O resumo anterior foi mantido."
        case .malformedJSON: "A resposta chegou, mas não está no formato estruturado esperado. O resumo anterior foi mantido."
        case .invalidSourceCount: "As fontes disponíveis não puderam ser conferidas. O resumo anterior foi mantido."
        case .tooManySections: "A resposta trouxe mais tópicos do que o formato da wiki permite. O resumo anterior foi mantido."
        case .duplicateSection: "A resposta repetiu um tópico da wiki. O resumo anterior foi mantido."
        case .overviewTooLong:
            if let count, let maximum {
                "O resumo breve retornado tem \(count) palavras; o limite é \(maximum). O resumo anterior foi mantido."
            } else {
                "O resumo breve retornado ultrapassa o limite de 20 palavras. O resumo anterior foi mantido."
            }
        case .invalidParagraphCount: "Um tópico da wiki veio sem a quantidade válida de itens. O resumo anterior foi mantido."
        case .emptyParagraph: "Um item da wiki veio sem texto. O resumo anterior foi mantido."
        case .paragraphTooLong: "Um item da wiki excede o limite local. O resumo anterior foi mantido."
        case .paragraphControlCharacters: "Um item da wiki contém caracteres inválidos. O resumo anterior foi mantido."
        case .paragraphMarkup: "Um item da wiki contém marcações não aceitas. O resumo anterior foi mantido."
        case .emptySources: "Um item da wiki veio sem fonte vinculada. O resumo anterior foi mantido."
        case .tooManySources: "Um item da wiki trouxe fontes demais. O resumo anterior foi mantido."
        case .duplicateSource: "Um item da wiki repetiu uma fonte. O resumo anterior foi mantido."
        case .unknownSource: "Um item da wiki aponta para uma fonte que não está disponível. O resumo anterior foi mantido."
        }
    }
}

struct PatientWikiGeneration: Decodable, Sendable {
    struct Paragraph: Decodable, Sendable {
        let text: String
        let sources: [String]
    }
    struct Section: Decodable, Sendable {
        let topic: PatientWikiTopic
        let paragraphs: [Paragraph]
    }
    let overview: Paragraph
    let sections: [Section]
    let facts: [PatientWikiFactDraft]

    static let prompt = AIPromptCatalog.patientWiki
    static let instructions = prompt.instructions
    static let maximumOverviewWords = 20

    static func decode(_ text: String, sourceCount: Int,
                       diagnostic: ((PatientWikiGenerationDiagnostic) -> Void)? = nil) throws -> Self {
        guard text.utf8.count <= 1_048_576 else {
            try reject(.init(code: .responseTooLarge), diagnostic: diagnostic)
        }

        let result: Self
        do {
            result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        } catch {
            try reject(.init(code: .malformedJSON), diagnostic: diagnostic)
        }
        guard (1...1_000).contains(sourceCount) else {
            try reject(.init(code: .invalidSourceCount, count: sourceCount, maximum: 1_000), diagnostic: diagnostic)
        }
        guard result.sections.count <= PatientWikiTopic.allCases.count else {
            try reject(.init(code: .tooManySections, count: result.sections.count,
                             maximum: PatientWikiTopic.allCases.count), diagnostic: diagnostic)
        }
        guard Set(result.sections.map(\.topic)).count == result.sections.count else {
            try reject(.init(code: .duplicateSection), diagnostic: diagnostic)
        }
        try validate(result.overview, sourceCount: sourceCount, maximum: 500,
                     sectionIndex: nil, paragraphIndex: nil, diagnostic: diagnostic)
        let overviewWords = result.overview.text.split(whereSeparator: { $0.isWhitespace }).count
        guard overviewWords <= maximumOverviewWords else {
            diagnostic?(.init(code: .overviewTooLong, count: overviewWords, maximum: maximumOverviewWords))
            throw PatientWikiGenerationIssue.overviewTooLong(
                wordCount: overviewWords, maximum: maximumOverviewWords)
        }
        for (sectionIndex, section) in result.sections.enumerated() {
            guard (1...20).contains(section.paragraphs.count) else {
                try reject(.init(code: .invalidParagraphCount, sectionIndex: sectionIndex,
                                 count: section.paragraphs.count, maximum: 20), diagnostic: diagnostic)
            }
            for (paragraphIndex, paragraph) in section.paragraphs.enumerated() {
                try validate(paragraph, sourceCount: sourceCount, maximum: 3_000,
                             sectionIndex: sectionIndex, paragraphIndex: paragraphIndex,
                             diagnostic: diagnostic)
            }
        }
        return result
    }

    private static func reject(_ diagnostic: PatientWikiGenerationDiagnostic,
                               diagnostic notify: ((PatientWikiGenerationDiagnostic) -> Void)?) throws -> Never {
        notify?(diagnostic)
        throw OpenAITextIssue.invalidResponse
    }

    private static func validate(_ paragraph: Paragraph, sourceCount: Int, maximum: Int,
                                 sectionIndex: Int?, paragraphIndex: Int?,
                                 diagnostic notify: ((PatientWikiGenerationDiagnostic) -> Void)?) throws {
        let allowed = Set((1...sourceCount).map { "F\($0)" })
        guard !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try reject(.init(code: .emptyParagraph, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex), diagnostic: notify)
        }
        guard paragraph.text.count <= maximum else {
            try reject(.init(code: .paragraphTooLong, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex, count: paragraph.text.count,
                             maximum: maximum), diagnostic: notify)
        }
        guard !paragraph.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            try reject(.init(code: .paragraphControlCharacters, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex), diagnostic: notify)
        }
        guard !paragraph.text.contains("["), !paragraph.text.contains("]") else {
            try reject(.init(code: .paragraphMarkup, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex), diagnostic: notify)
        }
        guard !paragraph.sources.isEmpty else {
            try reject(.init(code: .emptySources, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex), diagnostic: notify)
        }
        guard paragraph.sources.count <= 1_000 else {
            try reject(.init(code: .tooManySources, sectionIndex: sectionIndex,
                             paragraphIndex: paragraphIndex, count: paragraph.sources.count,
                             maximum: 1_000), diagnostic: notify)
        }
        var seen = Set<String>()
        for (sourceIndex, source) in paragraph.sources.enumerated() {
            guard seen.insert(source).inserted else {
                try reject(.init(code: .duplicateSource, sectionIndex: sectionIndex,
                                 paragraphIndex: paragraphIndex, sourceIndex: sourceIndex), diagnostic: notify)
            }
            guard allowed.contains(source) else {
                try reject(.init(code: .unknownSource, sectionIndex: sectionIndex,
                                 paragraphIndex: paragraphIndex, sourceIndex: sourceIndex), diagnostic: notify)
            }
        }
    }

    private func render(_ paragraph: Paragraph) -> String {
        paragraph.text + " " + paragraph.sources.map { "[\($0)]" }.joined(separator: " ")
    }

    var overviewText: String { overview.text }

    var markdown: String {
        var parts = ["# Resumo breve", render(overview)]
        for topic in PatientWikiTopic.allCases {
            if let section = sections.first(where: { $0.topic == topic }) {
                parts.append("## " + topic.title)
                parts.append(section.paragraphs.map(render).joined(separator: "\n\n"))
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

/// In-process invalidation after a committed clinical or wiki write. No draft notifications.
enum PatientClinicalChange {
    static let notification = Notification.Name("OpenPEP.patientClinicalChange")

    enum Kind: String { case sources, reviews }

    static func post(for patient: PatientSummary, kind: Kind = .sources) {
        NotificationCenter.default.post(name: notification, object: patient.url.standardizedFileURL,
            userInfo: ["kind": kind.rawValue])
    }

    static func isReview(_ notification: Notification) -> Bool {
        notification.userInfo?["kind"] as? String == Kind.reviews.rawValue
    }

    static func matches(_ notification: Notification, patientURL: URL) -> Bool {
        (notification.object as? URL)?.standardizedFileURL == patientURL.standardizedFileURL
    }
}
