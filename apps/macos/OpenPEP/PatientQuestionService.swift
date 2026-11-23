// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

@MainActor
struct PatientQuestionService {
    typealias Request = @MainActor (String, String) async throws -> OpenAITextResult
    func answer(question: String, context: PatientHistoryContext, selected: Set<String>? = nil,
                request: Request = { input, instructions in
                    try await AITextSettings.configuredRequest(input: input, instructions: instructions)
                }) async throws -> PatientAIAnswer {
        guard question.count <= 4_000 else { throw PatientAIIssue.tooLong }
        let loaded = try await Task.detached { try Self.load(context) }.value
        try Task.checkCancellation()
        let chosen = loaded.entries.filter { selected?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { throw PatientAIIssue.noSources }
        let source = try PatientAIContext.make(patient: loaded.patient, entries: chosen, corrections: loaded.corrections)
        // Preserve the existing clinical-source boundary; registration added by
        // the wiki reader is never implicitly added to a remote question.
        let selectedIDs = Set(chosen.map(\.id))
        let reading = try await Task.detached {
            try PatientWikiReadingSnapshot.load(context: context, selectedSourceIDs: selectedIDs)
        }.value
        try Task.checkCancellation()
        let verifiedSource = try PatientAIContext.make(patient: reading.patient, entries: reading.entries,
                                                       corrections: reading.corrections)
        guard reading.hasClinicalSources, reading.patient.record == loaded.patient.record,
              verifiedSource.input == source.input else { throw PatientAIIssue.changed }
        let input = "Pergunta do médico: " + (question.isEmpty ? "Resuma este paciente." : question)
            + "\nFontes excluídas ou sem texto: \(loaded.excludedCount). Rascunhos não foram consultados."
            + "\n\n" + source.input + "\n\n" + Self.derivedContext(reading)
        guard input.count <= PatientAIContext.maximumCharacters else { throw PatientAIIssue.tooLong }
        try await Self.revalidate(loaded: loaded, reading: reading, context: context)
        try Task.checkCancellation()
        let prompt = AIPromptCatalog.patientHistoryOpenAI
        let response = try await request(input, prompt.instructions)
        try Task.checkCancellation()
        let references = try NSRegularExpression(pattern: #"\[F(\d+)\]"#)
        let text = response.text as NSString
        for match in references.matches(in: response.text, range: NSRange(location: 0, length: text.length)) {
            guard let index = Int(text.substring(with: match.range(at: 1))), (1...chosen.count).contains(index) else {
                throw OpenAITextIssue.invalidResponse
            }
        }
        try await Self.revalidate(loaded: loaded, reading: reading, context: context)
        try Task.checkCancellation()
        return PatientAIAnswer(result: response, generationID: "gen_" + (try UUIDv7.generate(at: Date())),
            promptVersion: prompt.id, sourceText: input, sourceFingerprint: loaded.fingerprint,
            entries: chosen, corrections: loaded.corrections, wikiReadingSnapshot: reading)
    }

    nonisolated private static func derivedContext(_ reading: PatientWikiReadingSnapshot) -> String {
        let state: String
        switch reading.freshness {
        case .current: state = "atual para as fontes disponíveis"
        case .outdated: state = "desatualizada; síntese antiga não incluída"
        case .missing: state = "ausente"
        case .invalid: state = "indisponível; síntese inválida não incluída"
        }
        var lines = ["Leitura auxiliar derivada; as evidências são as fontes originais [F#] acima.",
                     "Wiki: " + state + ". Atualidade documental não confirma situação clínica atual.",
                     reading.exclusions.description]
        if !reading.wikiParagraphs.isEmpty {
            lines.append("Síntese da wiki de IA, restrita às fontes selecionadas:")
            lines.append(contentsOf: reading.wikiParagraphs.map(\.text))
        }
        lines.append("Visão IPS: somente extrações aceitas com evidência ainda correspondente às fontes selecionadas.")
        if let issue = reading.reviewsIssue { lines.append(issue) }
        if reading.acceptedIPS.isEmpty { lines.append("Nenhuma extração aceita elegível neste recorte; isso não prova ausência clínica.") }
        for accepted in reading.acceptedIPS {
            let description = PatientWikiExport.factDescription(accepted.fact, note: accepted.note)
                .replacingOccurrences(of: #"\[F[0-9]+\]"#, with: "", options: .regularExpression)
            let conflict = reading.conflictingAcceptedIDs.contains(accepted.fact.id)
                ? "Conflito documental pendente: " : "Extração aceita: "
            lines.append(conflict + description + " [F\(accepted.sourceNumber)]")
            let quote = accepted.fact.draft.quote
                .replacingOccurrences(of: #"\[F[0-9]+\]"#, with: "", options: .regularExpression)
            lines.append("Trecho da evidência [F\(accepted.sourceNumber)]: " + quote)
        }
        if !reading.outdatedAcceptedIDs.isEmpty {
            lines.append("Aceites anteriores excluídos por evidência alterada ou indisponível: \(reading.outdatedAcceptedIDs.count).")
        }
        return lines.joined(separator: "\n\n")
    }

    nonisolated private static func revalidate(loaded: Loaded, reading: PatientWikiReadingSnapshot,
                                             context: PatientHistoryContext) async throws {
        try await Task.detached {
            let current = try Self.load(context)
            guard current.fingerprint == loaded.fingerprint, current.patient.record == loaded.patient.record,
                  current.corrections == loaded.corrections else { throw PatientAIIssue.changed }
            try reading.revalidate(context: context)
        }.value
    }
    private struct Loaded: Sendable {
        let patient: PatientSummary
        let entries: [PatientHistoryEntry]
        let corrections: String
        let fingerprint: String
        let excludedCount: Int
    }
    nonisolated private static func load(_ context: PatientHistoryContext) throws -> Loaded {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let base = try PatientAIContext.load(context: context, corrections: "", includeDrafts: false)
        let wiki = try PatientWikiStore().load(for: base.patient)
        guard wiki.correctionsIssue == nil else { throw PatientAIIssue.changed }
        let corrections = wiki.corrections?.markdown ?? ""
        let data = try PatientAIContext.load(context: context, corrections: corrections, includeDrafts: false)
        return Loaded(patient: data.patient, entries: data.entries, corrections: corrections,
                      fingerprint: data.fingerprint, excludedCount: data.excludedCount)
    }
}
