// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct ConsultationSummaryServiceTests {
    @Test("refuses an unavailable device before sending clinical text")
    func refusesUnavailableDevice() async {
        let engine = SyntheticSummaryEngine(availability: .deviceNotEligible)
        let service = ConsultationSummaryService(engine: engine)
        await #expect(throws: ConsultationSummaryIssue.deviceNotEligible) {
            _ = try await service.propose(from: "Paciente sintético estável.")
        }
        let unavailableSources = await engine.sources
        #expect(unavailableSources.isEmpty)
    }

    @Test("checks pt-BR support before generation")
    func checksLocale() async {
        let engine = SyntheticSummaryEngine(availability: .localeUnsupported("pt-BR"))
        let service = ConsultationSummaryService(engine: engine)
        await #expect(throws: ConsultationSummaryIssue.localeUnsupported("pt-BR")) {
            _ = try await service.propose(from: "Consulta sintética.")
        }
    }

    @Test("chunks a bounded input without silently losing characters")
    func chunksWithoutTruncation() async throws {
        let source = "Paciente estável. Nega febre. Retorno em 7 dias."
        let engine = SyntheticSummaryEngine(maximumCharacters: 18)
        let date = Date(timeIntervalSince1970: 1_788_195_600)
        let service = ConsultationSummaryService(
            engine: engine,
            now: { date },
            generationID: { _ in "gen_0198f5d8-0000-7000-8000-000000000001" }
        )

        let proposal = try await service.propose(from: source)

        let summarizedSources = await engine.sources
        #expect(summarizedSources.joined() == source)
        #expect(proposal.provenance.sourceTranscript == source)
        #expect(proposal.provenance.chunkCount == summarizedSources.count)
        #expect(proposal.provenance.generationID == "gen_0198f5d8-0000-7000-8000-000000000001")
        #expect(proposal.provenance.sourceSHA256.count == 64)
        #expect(proposal.text.contains("[trecho 1 de"))
        for index in proposal.provenance.sourceChunks.indices {
            #expect(proposal.text.contains("_Fonte processada: [trecho \(index + 1) de \(summarizedSources.count)]_"))
        }
    }

    @Test("cancellation stops the remaining chunks")
    func cancellationStopsWork() async throws {
        let engine = SyntheticSummaryEngine(maximumCharacters: 12, delay: .seconds(30))
        let service = ConsultationSummaryService(engine: engine)
        let task = Task { try await service.propose(from: "Um texto. Outro texto.") }
        var didStart = false
        for _ in 0..<10_000 {
            if !(await engine.sources).isEmpty {
                didStart = true
                break
            }
            await Task.yield()
        }
        #expect(didStart)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

private actor SyntheticSummaryEngine: ConsultationSummaryEngine {
    let configuredAvailability: ConsultationSummaryAvailability
    let maximumCharacters: Int
    let delay: Duration?
    private(set) var sources: [String] = []

    init(
        availability: ConsultationSummaryAvailability = .ready,
        maximumCharacters: Int = 100_000,
        delay: Duration? = nil
    ) {
        configuredAvailability = availability
        self.maximumCharacters = maximumCharacters
        self.delay = delay
    }

    func availability(for locale: Locale) -> ConsultationSummaryAvailability {
        configuredAvailability
    }

    func accepts(_ source: String, sourceLabel: String, locale: Locale) -> Bool {
        source.count <= maximumCharacters
    }

    func summarize(_ source: String, sourceLabel: String, locale: Locale) async throws -> String {
        sources.append(source)
        if let delay { try await Task.sleep(for: delay) }
        return "- Conteúdo sintético [\(sourceLabel)]"
    }
}
