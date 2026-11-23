// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor
@Suite("CONSULTATION-LIVE-001/002 progressive consultation work")
struct ProgressiveConsultationWorkTests {
    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("reads v1 work as v2 without losing its summaries")
    func migratesV1Work() throws {
        let url = repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v1/valid/complete/work.json"
        )
        let work = try ProgressiveConsultationWorkStore().decode(data: Data(contentsOf: url))
        #expect(work.schema == ProgressiveConsultationWork.schema)
        #expect(work.blocks.isEmpty)
        #expect(work.summary?.revision == 1)
        #expect(work.summary?.text == "Evolução favorável, sem febre e com adesão ao plano.")
        #expect(work.summary?.acceptance?.acceptedText == work.summary?.text)
    }

    @Test("validates the v2 incremental fixture and its computed diff")
    func validatesV2Fixture() throws {
        let url = repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v2/valid/incremental/work.json"
        )
        let work = try ProgressiveConsultationWorkStore().decode(data: Data(contentsOf: url))
        #expect(work.summary?.revision == 1)
        #expect(work.summary?.revisions.first?.computedDiff == "+1: - Melhora referida.")
    }

    @Test("an empty model operation is a saved no-change revision")
    func acceptsNoChangeUpdate() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: []),
            now: { now },
            generationID: { _ in "gen_0198f5de-0000-7000-8000-000000000501" },
            revisionID: { "revision_0198f5dd-0000-7000-8000-000000000501" }
        )
        let update = try await service.generateUpdate(for: .init(
            baseRevision: 0, currentItems: [], newSegments: [segment], verificationSegments: []
        ))
        #expect(update.items.isEmpty)
        #expect(update.revision.kind == .noChange)
        #expect(update.revision.beforeText == update.revision.afterText)
        #expect(update.revision.computedDiff.isEmpty)
        #expect(update.revision.segmentReferences == [.init(segmentID: segment.id, revision: 1)])
    }

    @Test("provider references are bound locally to the stable interval")
    func bindsProviderOutputToStableInterval() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Paciente sintético nega febre.",
                references: [.init(segmentID: "segment_inventado", revision: 99)]
            )]),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 0,
            currentItems: [],
            newSegments: [segment],
            verificationSegments: []
        ))
        let expected = ConsultationTranscriptSegmentReference(
            segmentID: segment.id, revision: segment.revision
        )

        #expect(update.items.first?.segmentReferences == [expected])
        #expect(update.revision.generation?.segmentReferences == [expected])
    }

    @Test("a copied question is rejected without replacing the summary")
    func rejectsQuestionAsSummaryContent() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(
            attemptID: "attempt_0198f5df-0000-7000-8000-000000000501"
        )
        let existing = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Queixa sintética há dois dias.",
            state: .proposed,
            segmentReferences: [.init(segmentID: segment.id, revision: segment.revision)]
        )
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Você teve febre? Não.",
                references: []
            )])
        )

        await #expect(throws: ProgressiveSummaryIssue.invalidResponse) {
            try await service.generateUpdate(for: .init(
                baseRevision: 1,
                currentItems: [existing],
                newSegments: [segment],
                verificationSegments: []
            ))
        }
    }

    @Test("provider item indexes are resolved locally and invalid indexes are refused")
    func resolvesProviderItemIndexesLocally() throws {
        let item = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Uso de 5 mg.",
            state: .proposed,
            segmentReferences: [.init(
                segmentID: "segment_0198f5da-0000-7000-8000-000000000501",
                revision: 1
            )]
        )
        let operations = try progressiveOperations(
            from: #"{"operations":[{"action":"replace","target_item_index":1,"text":"Uso de 10 mg."}]}"#,
            currentItems: [item]
        )

        #expect(operations.first?.targetItemID == item.id)
        #expect(operations.first?.references.isEmpty == true)
        let addition = try progressiveOperations(
            from: #"{"operations":[{"action":"add","target_item_index":null,"text":"Novo fato."}]}"#,
            currentItems: [item]
        )
        #expect(addition.first?.targetItemID == nil)
        #expect(addition.first?.references.isEmpty == true)
        #expect(throws: ProgressiveSummaryIssue.invalidResponse) {
            try progressiveOperations(
                from: #"{"operations":[{"action":"replace","target_item_index":0,"text":"Uso de 10 mg."}]}"#,
                currentItems: [item]
            )
        }
    }

    @Test("Apple-style JSON is parsed, verified and bound without technical identifiers")
    func appliesAppleStyleJSONEndToEnd() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let attemptID = "attempt_0198f5df-0000-7000-8000-000000000501"
        let previousSegment = fixture.segment(attemptID: attemptID)
        let previousReference = ConsultationTranscriptSegmentReference(
            segmentID: previousSegment.id, revision: previousSegment.revision
        )
        let newSegment = ConsultationTranscriptSegment(
            id: "segment_0198f5da-0000-7000-8000-000000000502",
            revision: 1,
            range: .init(startSeconds: 60, endSeconds: 65, isApproximate: true),
            text: "Correção sintética: usa 10 mg.",
            engine: "apple/SpeechTranscriber",
            model: "pt-BR",
            attemptID: attemptID
        )
        let newReference = ConsultationTranscriptSegmentReference(
            segmentID: newSegment.id, revision: newSegment.revision
        )
        let existing = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Usa medicamento sintético 5 mg.",
            state: .proposed,
            segmentReferences: [previousReference]
        )
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: JSONSummaryGenerator(
                json: #"{"operations":[{"action":"replace","target_item_index":1,"text":"Usa medicamento sintético 10 mg."}]}"#
            ),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [existing],
            newSegments: [newSegment],
            verificationSegments: [],
            historicalSegments: [previousSegment]
        ))

        #expect(update.items.first?.id == existing.id)
        #expect(update.items.first?.text.contains("10 mg") == true)
        #expect(update.items.first?.segmentReferences == [previousReference, newReference])
        #expect(update.revision.segmentReferences == [newReference])
        #expect(update.revision.generation?.segmentReferences == [previousReference, newReference])
    }

    @Test("a correction to professional text is preserved as review-needed")
    func protectsProfessionalCorrection() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let professional = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Uso de 5 mg.", state: .professional, segmentReferences: [reference]
        )
        let operation = ProgressiveSummaryOperation(
            action: .replace,
            targetItemID: professional.id,
            text: "Uso de 10 mg.",
            references: [reference]
        )
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [operation]),
            now: { now },
            generationID: { _ in "gen_0198f5de-0000-7000-8000-000000000501" },
            revisionID: { "revision_0198f5dd-0000-7000-8000-000000000501" },
            itemID: { "summary_item_0198f5db-0000-7000-8000-000000000501" }
        )
        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [professional],
            newSegments: [segment],
            verificationSegments: []
        ))
        #expect(update.items.first == professional)
        #expect(update.items.last?.state == .needsReview)
        #expect(update.items.last?.text.contains("10 mg") == true)
        #expect(update.revision.computedDiff.contains("+2:"))
    }

    @Test("repeated information does not grow the summary")
    func ignoresRepeatedAddition() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let existing = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Paciente sintético nega febre.",
            state: .proposed,
            segmentReferences: [reference]
        )
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Paciente sintético nega febre.",
                references: [reference]
            )]),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [existing],
            newSegments: [segment],
            verificationSegments: []
        ))

        #expect(update.items == [existing])
        #expect(update.revision.kind == .noChange)
        #expect(update.revision.computedDiff.isEmpty)
    }

    @Test("an explicit dose correction replaces a proposed item and records the diff")
    func replacesProposedDose() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let existing = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Usa medicamento sintético 5 mg.",
            state: .proposed,
            segmentReferences: [reference]
        )
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [.init(
                action: .replace,
                targetItemID: existing.id,
                text: "Usa medicamento sintético 10 mg.",
                references: [reference]
            )]),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [existing],
            newSegments: [segment],
            verificationSegments: [segment]
        ))

        #expect(update.items.count == 1)
        #expect(update.items[0].id == existing.id)
        #expect(update.items[0].text.contains("10 mg"))
        #expect(update.revision.kind == .update)
        #expect(update.revision.computedDiff.contains("5 mg"))
        #expect(update.revision.computedDiff.contains("10 mg"))
    }

    @Test("an unresolved contradiction remains visibly pending review")
    func flagsAmbiguousContradiction() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let existing = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Uso referido de medicamento sintético.",
            state: .proposed,
            segmentReferences: [reference]
        )
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: [.init(
                action: .flag,
                targetItemID: existing.id,
                text: "Há falas incompatíveis sobre a dose.",
                references: [reference]
            )]),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [existing],
            newSegments: [segment],
            verificationSegments: [segment]
        ))

        #expect(update.items.first == existing)
        #expect(update.items.last?.state == .needsReview)
        #expect(update.items.last?.text.contains("Revisar divergência") == true)
    }

    @Test("the add limit scales to the minutes in a forced remaining interval")
    func scalesAdditionLimitByIntervalDuration() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let attemptID = "attempt_0198f5df-0000-7000-8000-000000000501"
        let original = fixture.segment(attemptID: attemptID)
        let segment = ConsultationTranscriptSegment(
            id: original.id,
            revision: original.revision,
            range: .init(startSeconds: 0, endSeconds: 180, isApproximate: true),
            text: original.text,
            engine: original.engine,
            model: original.model,
            attemptID: attemptID
        )
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let operations = (1...3).map { index in
            ProgressiveSummaryOperation(
                action: .add,
                targetItemID: nil,
                text: "Fato sintético essencial \(index).",
                references: [reference]
            )
        }
        let now = fixture.now
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: operations),
            now: { now }
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 0,
            currentItems: [],
            newSegments: [segment],
            verificationSegments: []
        ))

        #expect(update.items.count == 3)
    }

    @Test("essential additions are not silently discarded by a per-minute quota")
    func boundsExtraAdditions() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(
            attemptID: "attempt_0198f5df-0000-7000-8000-000000000501"
        )
        let reference = ConsultationTranscriptSegmentReference(
            segmentID: segment.id, revision: segment.revision
        )
        let operations = (1...4).map { index in
            ProgressiveSummaryOperation(
                action: .add,
                targetItemID: nil,
                text: "Fato sintético essencial \(index).",
                references: [reference]
            )
        }
        let service = ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: operations)
        )

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 0,
            currentItems: [],
            newSegments: [segment],
            verificationSegments: []
        ))

        #expect(update.items.map(\.text) == [
            "- Fato sintético essencial 1.",
            "- Fato sintético essencial 2.",
            "- Fato sintético essencial 3.",
            "- Fato sintético essencial 4.",
        ])
    }

    @Test("final review accepts twelve corrections without applying a per-minute quota")
    func finalReviewAcceptsTwelveCorrections() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let segment = fixture.segment(attemptID: "attempt_0198f5df-0000-7000-8000-000000000501")
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: 1)
        let items = (1...12).map { index in
            ConsultationSummaryItem(id: "item_\(index)", text: "Informação \(index).", state: .proposed, segmentReferences: [reference])
        }
        let operations = items.map {
            ProgressiveSummaryOperation(action: .replace, targetItemID: $0.id, text: "Correção sintética de \($0.text)", references: [reference])
        }
        let update = try await ProgressiveConsultationSummaryService(
            generator: StaticSummaryGenerator(operations: operations)
        ).generateUpdate(for: .init(
            baseRevision: 1, currentItems: items, newSegments: [segment],
            verificationSegments: [], isFinalReview: true
        ))
        #expect(update.items.count == 12)
        #expect(update.items.allSatisfy { $0.text.contains("Correção sintética") })
    }

    @Test("a correction loads only the original source of its target item")
    func verifiesTargetedCorrectionAgainstOriginalSource() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let attemptID = "attempt_0198f5df-0000-7000-8000-000000000501"
        let prior = fixture.segment(attemptID: attemptID)
        let newSegment = ConsultationTranscriptSegment(
            id: "segment_0198f5da-0000-7000-8000-000000000599",
            revision: 1,
            range: .init(startSeconds: 5, endSeconds: 10, isApproximate: true),
            text: "Correção sintética explícita para 10 mg.",
            engine: prior.engine,
            model: prior.model,
            attemptID: attemptID
        )
        let priorReference = ConsultationTranscriptSegmentReference(
            segmentID: prior.id, revision: prior.revision
        )
        let target = ConsultationSummaryItem(
            id: "summary_item_0198f5dc-0000-7000-8000-000000000501",
            text: "- Uso de 5 mg.",
            state: .proposed,
            segmentReferences: [priorReference]
        )
        let generator = TargetedVerificationGenerator(targetItemID: target.id)
        let service = ProgressiveConsultationSummaryService(generator: generator)

        let update = try await service.generateUpdate(for: .init(
            baseRevision: 1,
            currentItems: [target],
            newSegments: [newSegment],
            verificationSegments: [],
            historicalSegments: [prior]
        ))

        #expect(update.items.first?.text.contains("10 mg") == true)
        #expect(await generator.requestCount() == 2)
        #expect(await generator.lastVerificationReferences() == [priorReference])
    }

    @Test("stores a bound work document atomically and recovers without resuming capture")
    func roundTripAndRecovery() throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let store = ProgressiveConsultationWorkStore()
        var work = ProgressiveConsultationWork(
            binding: fixture.binding,
            source: .microphone,
            summaryIntervalSeconds: 180,
            transcriptionEngine: "openai/realtime",
            transcriptionModel: "gpt-live-transcribe",
            summaryEngine: "openai/responses",
            summaryModel: "gpt-4o",
            now: fixture.now
        )
        work.capture.status = .recording
        work.status = .recording
        work.capture.startedAt = fixture.now
        work.segments = [fixture.segment(attemptID: work.capture.attemptID)]

        let first = try store.save(work, binding: fixture.binding)
        #expect(try store.load(binding: fixture.binding) == work)

        work.status = .incomplete
        work.capture.status = .incomplete
        work.updatedAt = fixture.now.addingTimeInterval(10)
        let second = try store.save(work, binding: fixture.binding, expectedData: first)
        #expect(second != first)

        let session = EncounterTranscriptionSession()
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onLoadWork: { (work, second) },
            onPersistWork: { document, expected in
                try store.save(document, binding: fixture.binding, expectedData: expected)
            }
        ))
        #expect(session.progressiveWork?.status == .incomplete)
        #expect(!session.isRecording)
        #expect(session.status.contains("não foi retomada"))
    }

    @Test("summary insertion explains review, pending edits and stale displayed text")
    func insertionExplainsReviewAndPendingEdits() async throws {
        let fixture = try WorkFixture(); defer { fixture.remove() }
        let store = ProgressiveConsultationWorkStore()
        var work = try store.decode(data: Data(contentsOf: repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v2/valid/incremental/work.json")))
        work.summary!.items[0].state = .needsReview
        let data = try store.encode(work)
        let session = EncounterTranscriptionSession()
        #expect(session.prepare(binding: .init(vaultURL: fixture.root, vaultID: work.vaultID,
            patientID: work.patientID, encounterID: work.encounterID, patientName: "Paciente Sintético"),
            onPersist: { _, _, _ in }, onLoadWork: { (work, data) },
            onPersistWork: { document, _ in try store.encode(document) }))
        let previous = session.progressiveSummaryText
        #expect(session.progressiveSummaryNeedsReview)
        #expect(session.progressiveSummaryInsertionIssue(editorText: previous)?.contains("pontos marcados") == true)
        #expect(session.progressiveSummaryBlockForInsertion()?.state == .needsReview)
        let reviewed = "Texto sintético corrigido após conferir a transcrição."
        session.editProgressiveSummary(reviewed)
        #expect(session.progressiveSummaryInsertionIssue(editorText: reviewed) == "Salvando sua revisão…")
        await waitUntil { !session.progressiveSummaryHasPendingEdit && session.progressiveSummaryRevision == 2 }
        #expect(!session.progressiveSummaryNeedsReview)
        #expect(session.progressiveSummaryInsertionIssue(editorText: reviewed) == nil)
        #expect(session.progressiveSummaryInsertionIssue(editorText: previous)?.contains("versão mais recente") == true)
        #expect(session.progressiveWork?.summary?.revisions.last?.origin == .professional)
        #expect(session.progressiveSummaryBlockForInsertion()?.state == .edited)
        session.shutdown()
    }

    @Test("a delayed model response cannot replace a pending professional edit")
    func delayedResponsePreservesProfessionalEdit() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let fixtureURL = repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v2/valid/incremental/work.json"
        )
        let store = ProgressiveConsultationWorkStore()
        var work = try store.decode(data: Data(contentsOf: fixtureURL))
        let secondSegment = ConsultationTranscriptSegment(
            id: "segment_0198f7a5-0000-7000-8000-000000000099",
            revision: 1,
            range: .init(startSeconds: 60, endSeconds: 120, isApproximate: true),
            text: "Trecho sintético novo.",
            engine: "apple/SpeechTranscriber",
            model: "system",
            attemptID: work.capture.attemptID
        )
        work.segments.append(secondSegment)
        work.summaryEngine = "openai/responses"
        work.summaryModel = "gpt-4o"
        work.capture.capturedSeconds = 120
        work.updatedAt = fixture.now
        let loadedData = try store.encode(work)
        let delayed = DelayedSummaryGenerator()
        let session = EncounterTranscriptionSession(summaryServiceFactory: { _, _ in
            ProgressiveConsultationSummaryService(generator: delayed)
        })
        let binding = EncounterTranscriptionBinding(
            vaultURL: fixture.root,
            vaultID: work.vaultID,
            patientID: work.patientID,
            encounterID: work.encounterID,
            patientName: "Paciente Sintético"
        )
        #expect(session.prepare(
            binding: binding,
            onPersist: { _, _, _ in },
            onLoadWork: { (work, loadedData) },
            onPersistWork: { document, _ in try store.encode(document) }
        ))

        session.summarizeNow()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, !(await delayed.hasStarted()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await delayed.hasStarted())
        session.editProgressiveSummary("- Texto profissional preservado.")
        await delayed.finish(reference: .init(segmentID: secondSegment.id, revision: 1))
        await waitUntil {
            !session.summaryIsUpdating && !session.progressiveSummaryHasPendingEdit
                && session.progressiveSummaryRevision == 2
        }

        #expect(session.progressiveSummaryText == "- Texto profissional preservado.")
        #expect(session.progressiveWork?.summary?.revisions.last?.origin == .professional)
        session.shutdown()
    }

    @Test("failed acceptance persistence leaves the local summary unaccepted")
    func acceptancePersistenceFailureIsVisible() throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let fixtureURL = repositoryRoot.appending(
            path: "fixtures/progressive-summary-work-v2/valid/incremental/work.json"
        )
        let store = ProgressiveConsultationWorkStore()
        let data = try Data(contentsOf: fixtureURL)
        let work = try store.decode(data: data)
        let binding = EncounterTranscriptionBinding(
            vaultURL: fixture.root,
            vaultID: work.vaultID,
            patientID: work.patientID,
            encounterID: work.encounterID,
            patientName: "Paciente Sintético"
        )
        let session = EncounterTranscriptionSession()
        #expect(session.prepare(
            binding: binding,
            onPersist: { _, _, _ in },
            onLoadWork: { (work, data) },
            onPersistWork: { _, _ in throw SyntheticPersistenceFailure() }
        ))
        let acceptance = ConsultationSummaryAcceptance(
            acceptanceID: "acceptance_0198f7a9-0000-7000-8000-000000000099",
            acceptedBy: "usr_0198f7aa-0000-7000-8000-000000000099",
            acceptedAt: fixture.now,
            acceptedText: work.summary?.text ?? "",
            sourceAssetID: "asset_0198f7ab-0000-7000-8000-000000000099"
        )

        #expect(throws: SyntheticPersistenceFailure.self) {
            try session.markProgressiveSummaryAccepted(acceptance)
        }
        #expect(session.progressiveWork?.summary?.acceptance == nil)
        #expect(session.progressiveSaveStatus.hasPrefix("Não foi possível salvar"))
        session.shutdown()
    }

    @Test("encodes every nullable field required by progressive-summary-work@2")
    func encodesRequiredNulls() throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let store = ProgressiveConsultationWorkStore()
        var work = ProgressiveConsultationWork(
            binding: fixture.binding,
            source: .microphone,
            summaryIntervalSeconds: 180,
            transcriptionEngine: "apple/SpeechTranscriber",
            transcriptionModel: "system",
            summaryEngine: "apple/FoundationModels.SystemLanguageModel",
            summaryModel: nil,
            now: fixture.now
        )
        let segment = fixture.segment(attemptID: work.capture.attemptID)
        work.segments = [segment]
        let reference = ConsultationTranscriptSegmentReference(segmentID: segment.id, revision: segment.revision)
        let item = ConsultationSummaryItem(
            id: "summary_item_0198f5dd-0000-7000-8000-000000000501",
            text: "- Paciente sintético nega febre.",
            state: .proposed,
            segmentReferences: [reference]
        )
        let generation = ConsultationSummaryGeneration(
                generationID: "gen_0198f5de-0000-7000-8000-000000000501",
                engine: "apple/FoundationModels.SystemLanguageModel",
                model: nil,
                responseID: nil,
                promptVersion: "openpep/progressive-consultation-summary-pt-BR@3",
                generatedAt: fixture.now,
                source: "Paciente sintético nega febre.",
                segmentReferences: [reference]
        )
        work.summary = ConsultationIncrementalSummary(
            revision: 1,
            coveredSegmentReferences: [reference],
            items: [item],
            revisions: [.init(
                id: "revision_0198f5df-0000-7000-8000-000000000501",
                sequence: 1,
                baseRevision: 0,
                savedAt: fixture.now,
                origin: .model,
                kind: .update,
                affectedItemIDs: [item.id],
                segmentReferences: [reference],
                beforeText: "",
                afterText: item.text,
                computedDiff: ConsultationSummaryDiff.make(before: "", after: item.text),
                generation: generation
            )],
            acceptance: nil
        )

        let data = try store.encode(work)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let capture = try #require(json["capture"] as? [String: Any])
        let summary = try #require(json["summary"] as? [String: Any])
        let revision = try #require((summary["revisions"] as? [[String: Any]])?.first)
        let encodedGeneration = try #require(revision["generation"] as? [String: Any])
        #expect(json["summary_model"] is NSNull)
        #expect(json["last_error"] is NSNull)
        #expect(capture["started_at"] is NSNull)
        #expect(capture["ended_at"] is NSNull)
        #expect(capture["audio_filename"] is NSNull)
        #expect(summary["acceptance"] is NSNull)
        #expect(encodedGeneration["model"] is NSNull)
        #expect(encodedGeneration["response_id"] is NSNull)
        #expect(try store.decode(data: data) == work)
    }

    @Test("rejects a segment from another capture attempt")
    func rejectsSegmentFromAnotherAttempt() throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        var work = ProgressiveConsultationWork(
            binding: fixture.binding,
            source: .microphone,
            summaryIntervalSeconds: 180,
            transcriptionEngine: "apple/SpeechTranscriber",
            transcriptionModel: "system",
            summaryEngine: "apple/FoundationModels.SystemLanguageModel",
            summaryModel: nil,
            now: fixture.now
        )
        work.segments = [fixture.segment(
            attemptID: "attempt_0198f5df-0000-7000-8000-000000000501"
        )]
        #expect(throws: ProgressiveConsultationWorkIssue.self) {
            try ProgressiveConsultationWorkStore().validate(work)
        }
    }

    @Test("batch transcription automatically saves one incremental summary")
    func batchCreatesProgressiveSummary() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-sintetica.wav")
        try Data("audio sintetico".utf8).write(to: audioURL)
        let engine = WorkTranscriptionEngine()
        let generator = WorkSummaryGenerator()
        let summaryNow = fixture.now.addingTimeInterval(30)
        var savedWorkData: Data?
        let store = ProgressiveConsultationWorkStore()
        let session = EncounterTranscriptionSession(
            transcriptionService: LocalTranscriptionService(engine: engine),
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(
                    generator: generator,
                    now: { summaryNow },
                    generationID: { date in "gen_\(try UUIDv7.generate(at: date))" }
                )
            }
        )
        let prepared = session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, expected in
                if let expected, expected != savedWorkData {
                    throw ProgressiveConsultationWorkIssue.revisionConflict
                }
                let data = try store.encode(document)
                savedWorkData = data
                return data
            }
        )
        #expect(prepared)
        session.configureProgressive(.init(
            source: .imported,
            usesLiveTranscription: false,
            summaryIntervalSeconds: 180
        ))
        session.transcribe(url: audioURL)
        await waitUntil { session.progressiveWork?.status == .ready && !session.summaryIsUpdating }

        #expect(session.saved)
        #expect(session.progressiveWork?.segments.map(\.text) == ["Paciente sintético nega febre."])
        #expect(session.progressiveWork?.summary?.items.count == 1)
        #expect(session.progressiveWork?.summary?.revision == 1)
        #expect(session.progressiveSaveStatus == "Salvo neste Mac")
        #expect(savedWorkData != nil)
    }

    @Test("live microphone publishes partial and final text, then drains a saved summary")
    func liveMicrophoneCompletesProgressiveWork() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-ao-vivo-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let socket = WorkRealtimeSocket()
        let secondSocket = WorkRealtimeSocket()
        let socketPool = WorkRealtimeSocketPool(sockets: [socket, secondSocket])
        let generator = WorkSummaryGenerator()
        let summaryDate = fixture.now.addingTimeInterval(30)
        var savedWorkData: Data?
        let store = ProgressiveConsultationWorkStore()
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            realtimeFactory: { socketPool.makeService(eventHandler: $0) },
            liveTranscriptionConfiguration: {
                ("sk-synthetic-key-never-sent", OpenAIRealtimeTranscription.model)
            },
            liveTranscriptionPermission: { true },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(
                    generator: generator,
                    now: { summaryDate },
                    generationID: { date in "gen_\(try UUIDv7.generate(at: date))" }
                )
            },
            liveDrainDelay: .zero
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, expected in
                if let expected, expected != savedWorkData {
                    throw ProgressiveConsultationWorkIssue.revisionConflict
                }
                let data = try store.encode(document)
                savedWorkData = data
                return data
            }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            usesLiveTranscription: true,
            summaryIntervalSeconds: 180,
            summaryProvider: .apple,
            summaryModel: nil
        ))

        await session.startRecording(at: audioURL, consent: true)
        #expect(session.isRecording)
        session.togglePause()
        #expect(session.isPauseTransitioning)
        session.togglePause()
        await waitUntil { session.isPaused && capture.didPause }
        #expect(capture.pauseCount == 1)
        #expect(!session.isPauseTransitioning)
        #expect(session.status.contains("áudio não está sendo captado"))
        session.togglePause()
        #expect(session.isPauseTransitioning)
        session.togglePause()
        await waitUntil { !session.isPaused && capture.didResume }
        #expect(capture.resumeCount == 1)
        #expect(!session.isPauseTransitioning)
        let chunk = try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 4_800),
            samplePosition: 0,
            monotonicTime: 1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.25
        )
        capture.emit(chunk)
        await waitUntil { socket.sent.count >= 2 }
        socket.emit(#"{"type":"conversation.item.input_audio_transcription.delta","event_id":"event_synthetic_partial","item_id":"item_synthetic","content_index":0,"delta":"Paciente sintético "}"#)
        await waitUntil { session.partialTranscript == "Paciente sintético " }
        socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_synthetic","content_index":0,"transcript":"Paciente sintético nega febre."}"#)
        await waitUntil { session.progressiveWork?.segments.count == 1 }

        session.stop()
        await waitUntil { session.progressiveWork?.status == .ready && !session.isBusy }

        #expect(session.partialTranscript.isEmpty)
        #expect(session.progressiveWork?.segments.map(\.text) == ["Paciente sintético nega febre."])
        #expect(session.progressiveWork?.summary?.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(savedWorkData != nil)
        let priorSegment = try #require(session.progressiveWork?.segments.first)
        let nextURL = fixture.root.appending(path: "segunda-openai.wav")
        await session.startRecording(at: nextURL, consent: true)
        #expect(session.isRecording)
        capture.emit(chunk)
        await waitUntil { secondSocket.sent.count >= 2 }
        secondSocket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_synthetic","content_index":0,"transcript":"Mantém boa evolução."}"#)
        await waitUntil { session.progressiveWork?.segments.count == 2 }
        #expect(session.progressiveWork?.segments.first == priorSegment)
        #expect(session.progressiveWork?.segments.last?.range.startSeconds == priorSegment.range.endSeconds)
        session.stop()
        await waitUntil { !session.isBusy }
        #expect(session.progressiveWork?.segments.last?.text == "Mantém boa evolução.")
        #expect(session.progressiveWork?.capture.audioFilenames?.count == 2)
        session.shutdown()
    }

    @Test("failed startup can retry in the configured folder without replacing captured content")
    func retriesEmptyCaptureWithFolderAuthorization() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let capture = WorkLiveMicrophoneCapture()
        let apple = WorkAppleLiveTranscription()
        capture.failsStart = true
        var savedData: Data?
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            appleLiveFactory: { handler in apple.eventHandler = handler; return apple })
        let prepared = session.prepare(binding: fixture.binding, onPersist: { _, _, _ in },
            onPersistWork: { document, expected in
                #expect(expected == savedData)
                let data = try ProgressiveConsultationWorkStore().encode(document)
                savedData = data
                return data
            })
        #expect(prepared)
        session.configureProgressive(.init(source: .microphone, transcriptionMode: .appleLive,
            summaryIntervalSeconds: 60, summaryProvider: .apple, summaryModel: nil))
        await session.startRecording(at: fixture.root.appending(path: "failed.wav"), consent: true, authorizationURL: fixture.root)
        #expect(!session.isBusy)
        #expect(session.canRetryEmptyCapture)
        #expect(session.scopeAccessURL == nil)
        #expect(session.prepareRetryAfterEmptyCaptureFailure())
        capture.failsStart = false
        let destination = fixture.root.appending(path: "retry.wav")
        await session.startRecording(at: destination, consent: true, authorizationURL: fixture.root)
        #expect(session.isRecording)
        #expect(session.scopeURL == destination)
        #expect(session.scopeAccessURL == fixture.root)
        #expect(session.progressiveWork?.capture.audioFilename == "retry.wav")
        #expect(!session.prepareRetryAfterEmptyCaptureFailure())
        apple.emit(.final(text: "Relato sintético preservado.", startSeconds: 0, endSeconds: 2))
        #expect(!session.canRetryEmptyCapture)
        session.shutdown()
        await waitUntil { !session.isBusy }
    }

    @Test("Apple live keeps audio local, publishes only final text, and supports one-minute test blocks")
    func appleLiveCompletesLocalProgressiveWork() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-apple-ao-vivo-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let apple = WorkAppleLiveTranscription()
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            appleLiveFactory: { handler in
                apple.eventHandler = handler
                return apple
            },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: WorkSummaryGenerator())
            }
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, _ in try ProgressiveConsultationWorkStore().encode(document) }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            transcriptionMode: .appleLive,
            summaryIntervalSeconds: 60,
            summaryProvider: .apple,
            summaryModel: nil
        ))

        await session.startRecording(at: audioURL, consent: true)
        #expect(session.isRecording)
        let chunk = try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 4_800),
            samplePosition: 0,
            monotonicTime: 1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.25
        )
        capture.emit(chunk)
        await waitUntil { apple.chunks == [chunk] }
        apple.emit(.partial(text: "Paciente sintético"))
        #expect(session.partialTranscript == "Paciente sintético")
        #expect(session.progressiveWork?.segments.isEmpty == true)
        apple.emit(.final(text: "Paciente sintético nega febre.", startSeconds: 0, endSeconds: 60))
        await waitUntil { session.progressiveWork?.segments.count == 1 }

        session.stop()
        await waitUntil { session.progressiveWork?.status == .ready && !session.isBusy }

        #expect(apple.didFinish)
        #expect(session.progressiveWork?.summaryIntervalSeconds == 60)
        #expect(session.progressiveWork?.segments.first?.engine == "apple/SpeechTranscriber")
        #expect(session.progressiveWork?.summary?.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        session.shutdown()
    }

    @Test("stopped and reopened capture resumes, preserves edits, clears accepted text and blocks closed encounters")
    func resumesCaptureUntilEncounterCloses() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let store = ProgressiveConsultationWorkStore()
        var savedData: Data?
        var encounterIsOpen = true
        var rejectPersistence = false
        let apple = WorkAppleLiveTranscription()
        let capture = WorkLiveMicrophoneCapture()
        func makeSession() -> EncounterTranscriptionSession {
            let session = EncounterTranscriptionSession(liveMicrophoneCapture: capture,
                appleLiveFactory: { handler in apple.eventHandler = handler; return apple },
                summaryServiceFactory: { _, _ in ProgressiveConsultationSummaryService(generator: WorkSummaryGenerator()) })
            let prepared = session.prepare(binding: fixture.binding, onPersist: { _, _, _ in },
                onLoadWork: {
                    guard let data = savedData else { return nil }
                    return (try store.decode(data: data), data)
                },
                onPersistWork: { document, expected in
                    if rejectPersistence { throw SyntheticPersistenceFailure() }
                    #expect(expected == savedData)
                    try store.validate(document, binding: fixture.binding)
                    let data = try store.encode(document)
                    savedData = data
                    return data
                },
                onValidateCapture: {
                    guard encounterIsOpen else { throw SyntheticPersistenceFailure() }
                })
            #expect(prepared)
            session.configureProgressive(.init(source: .microphone, transcriptionMode: .appleLive,
                summaryIntervalSeconds: 60, summaryProvider: .apple, summaryModel: nil))
            return session
        }
        let first = makeSession()
        let firstURL = fixture.root.appending(path: "primeira.wav")
        await first.startRecording(at: firstURL, consent: true)
        #expect(first.isRecording)
        apple.emit(.final(text: "Refere melhora da dor.", startSeconds: 0, endSeconds: 60))
        first.stop()
        await waitUntil { !first.isBusy }
        first.editProgressiveSummary("Dor melhorou. Manter acompanhamento em duas semanas.")
        await waitUntil { !first.progressiveSummaryHasPendingEdit }
        let original = try #require(first.progressiveWork)
        let firstBytes = try Data(contentsOf: firstURL)
        first.shutdown()

        let resumed = makeSession()
        #expect(resumed.progressiveSummaryText == original.summary?.text)
        #expect(resumed.canResumeCapture)
        let nextURL = fixture.root.appending(path: "segunda.wav")
        rejectPersistence = true
        await resumed.startRecording(at: nextURL, consent: true)
        #expect(!resumed.isRecording)
        #expect(!FileManager.default.fileExists(atPath: nextURL.path))
        #expect(resumed.progressiveWork?.segments == original.segments)
        rejectPersistence = false
        await resumed.startRecording(at: nextURL, consent: true)
        #expect(resumed.isRecording)
        #expect(resumed.progressiveSummaryText == original.summary?.text)
        apple.emit(.final(text: "Nega febre desde o retorno.", startSeconds: 0, endSeconds: 10))
        #expect(resumed.progressiveWork?.segments.count == 2)
        #expect(resumed.progressiveWork?.segments.last?.range.startSeconds == 60)
        #expect(resumed.progressiveWork?.segments.last?.range.endSeconds == 70)
        #expect(resumed.progressiveWork?.capture.audioFilenames == ["primeira.wav", "segunda.wav"])
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        resumed.stop()
        await waitUntil { !resumed.isBusy }
        #expect(resumed.progressiveWork?.summary?.revisions.contains { $0.afterText == original.summary?.text } == true)
        #expect(resumed.progressiveSummaryText.contains("Manter acompanhamento em duas semanas."))
        let beforeAcceptance = resumed.progressiveSummaryText
        let acceptance = ConsultationSummaryAcceptance(
            acceptanceID: "acceptance_0198f7a9-0000-7000-8000-000000000099",
            acceptedBy: "usr_0198f7aa-0000-7000-8000-000000000099",
            acceptedAt: Date(), acceptedText: beforeAcceptance,
            sourceAssetID: "asset_0198f7ab-0000-7000-8000-000000000099")
        try resumed.markProgressiveSummaryAccepted(acceptance)
        #expect(resumed.visibleProgressiveSummaryText.isEmpty)
        #expect(resumed.progressiveWork?.summary?.acceptance?.acceptedText == beforeAcceptance)
        try resumed.markProgressiveSummaryUndone()
        #expect(resumed.visibleProgressiveSummaryText == beforeAcceptance)
        try resumed.markProgressiveSummaryAccepted(acceptance)
        let acceptedSessionID = resumed.progressiveWork?.sessionID
        let thirdURL = fixture.root.appending(path: "terceira.wav")
        await resumed.startRecording(at: thirdURL, consent: true)
        #expect(resumed.isRecording)
        #expect(resumed.progressiveWork?.sessionID != acceptedSessionID)
        #expect(resumed.visibleProgressiveSummaryText.isEmpty)
        #expect(resumed.progressiveWork?.segments.isEmpty == true)
        resumed.stop()
        await waitUntil { !resumed.isBusy }
        encounterIsOpen = false
        let blockedURL = fixture.root.appending(path: "bloqueada.wav")
        await resumed.startRecording(at: blockedURL, consent: true)
        #expect(!resumed.isRecording)
        #expect(!FileManager.default.fileExists(atPath: blockedURL.path))
        resumed.shutdown()
    }

    @Test("resumed audio filename fixtures retain old work compatibility")
    func resumedAudioFilenames() throws {
        let store = ProgressiveConsultationWorkStore()
        let base = repositoryRoot.appending(path: "fixtures/progressive-summary-work-v2")
        let old = try store.decode(data: Data(contentsOf: base.appending(path: "valid/incremental/work.json")))
        #expect(old.capture.audioFilenames == nil)
        let resumed = try store.decode(data: Data(contentsOf: base.appending(path: "valid/resumed/work.json")))
        #expect(resumed.capture.audioFilenames?.count == 2)
        #expect(throws: (any Error).self) {
            try store.decode(data: Data(contentsOf: base.appending(path: "invalid/audio-filename-mismatch/work.json")))
        }
    }

    @Test("Apple transcription supports final-only Apple or progressive OpenAI summary", arguments: [ProgressiveSummaryProvider.apple, .openAI])
    func appleLiveSummarizesMinuteByMinute(provider: ProgressiveSummaryProvider) async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-tres-minutos-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let apple = WorkAppleLiveTranscription()
        let generator = RecordingSummaryGenerator(provider: provider)
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            appleLiveFactory: { handler in
                apple.eventHandler = handler
                return apple
            },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: generator)
            }
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, _ in try ProgressiveConsultationWorkStore().encode(document) }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            transcriptionMode: .appleLive,
            summaryIntervalSeconds: 60,
            summaryProvider: provider,
            summaryModel: provider == .openAI ? "gpt-4o" : nil
        ))
        await session.startRecording(at: audioURL, consent: true)

        for minute in 1...3 {
            capture.emit(try EncounterAudioChunk(
                pcm16: Data(repeating: UInt8(minute), count: 4_800),
                samplePosition: Int64(minute * 60 * 24_000),
                monotonicTime: Double(minute * 60),
                format: .pcm16Mono24k,
                source: .microphone,
                level: 0.25
            ))
            apple.emit(.final(
                text: "Informação sintética do minuto \(minute).",
                startSeconds: Double((minute - 1) * 60),
                endSeconds: Double(minute * 60)
            ))
            if provider == .openAI {
                await waitUntil { session.progressiveSummaryRevision == minute }
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await generator.incrementalRequestCount() == (provider == .openAI ? minute : 0))
            if provider == .openAI, minute > 1 {
                let contextCount = await generator.lastIncrementalVerificationCount()
                #expect((1...2).contains(contextCount))
            }
        }

        #expect(session.progressiveSummaryCoveredThrough == (provider == .openAI ? 180 : 0))
        session.stop()
        await waitUntil { session.progressiveWork?.status == .ready && !session.isBusy }
        #expect(session.progressiveWork?.summary?.items.count == (provider == .openAI ? 3 : 0))
        #expect(await generator.finalReviewRequestCount() == 1)
        session.shutdown()
    }

    @Test("finalization covers a stable segment whose end exceeds the capture clock fraction")
    func finalizationCoversFractionalLastSegment() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let store = ProgressiveConsultationWorkStore()
        var work = ProgressiveConsultationWork(
            binding: fixture.binding,
            source: .microphone,
            summaryIntervalSeconds: 60,
            transcriptionEngine: "apple/SpeechTranscriber",
            transcriptionModel: "pt-BR",
            summaryEngine: "openai/responses",
            summaryModel: "gpt-4o",
            now: fixture.now
        )
        work.capture.capturedSeconds = 81.8
        work.capture.status = .incomplete
        work.status = .incomplete
        work.segments = [ConsultationTranscriptSegment(
            id: "segment_0198f5da-0000-7000-8000-000000000099",
            revision: 1,
            range: .init(startSeconds: 0, endSeconds: 81.8006875, isApproximate: false),
            text: "Queixa sintética com evolução de oito meses.",
            engine: "apple/SpeechTranscriber",
            model: "pt-BR",
            attemptID: work.capture.attemptID
        )]
        let loadedData = try store.encode(work)
        let generator = SnapshotSummaryGenerator()
        let session = EncounterTranscriptionSession(summaryServiceFactory: { _, _ in
            ProgressiveConsultationSummaryService(generator: generator)
        })
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onLoadWork: { (work, loadedData) },
            onPersistWork: { document, _ in try store.encode(document) }
        ))

        session.retryProgressiveCompletion()
        await waitUntil { session.progressiveWork?.status == .ready && !session.isBusy }

        #expect(session.progressiveSummaryCoveredThrough == 81.8006875)
        #expect(session.progressiveWork?.summaryModel == "gpt-4o")
        #expect(session.progressiveWork?.summary?.revisions.last?.generation?.model
                == "gpt-4o-synthetic-snapshot")
        session.shutdown()
    }

    @Test("a failed minute is not retried in a tight loop")
    func summaryFailureWaitsBeforeRetry() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-falha-resumo-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let apple = WorkAppleLiveTranscription()
        let generator = FailingSummaryGenerator()
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            appleLiveFactory: { handler in
                apple.eventHandler = handler
                return apple
            },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: generator)
            }
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, _ in try ProgressiveConsultationWorkStore().encode(document) }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            transcriptionMode: .appleLive,
            summaryIntervalSeconds: 60,
            summaryProvider: .openAI,
            summaryModel: "gpt-4o"
        ))
        await session.startRecording(at: audioURL, consent: true)
        capture.emit(try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 4_800),
            samplePosition: 60 * 24_000,
            monotonicTime: 60,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.25
        ))
        apple.emit(.final(
            text: "Informação sintética estabilizada.",
            startSeconds: 0,
            endSeconds: 60
        ))
        await waitUntil { !session.summaryIsUpdating && session.progressiveWork?.lastError != nil }
        try await Task.sleep(for: .milliseconds(250))

        #expect(await generator.requestCount() == 1)
        session.stop()
        await waitUntil { !session.isBusy }
        #expect(session.progressiveWork?.status == .incomplete)
        session.shutdown()
    }

    @Test("revoking live audio keeps local capture and records the untranscribed range")
    func revocationKeepsLocalCapture() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-revogacao-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let socket = WorkRealtimeSocket()
        let generator = WorkSummaryGenerator()
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            realtimeFactory: { handler in
                OpenAIRealtimeTranscription(
                    socketFactory: WorkRealtimeSocketFactory(socket: socket),
                    eventHandler: handler
                )
            },
            liveTranscriptionConfiguration: {
                ("sk-synthetic-key-never-sent", OpenAIRealtimeTranscription.model)
            },
            liveTranscriptionPermission: { true },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: generator)
            },
            liveDrainDelay: .zero
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, _ in try ProgressiveConsultationWorkStore().encode(document) }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            usesLiveTranscription: true,
            summaryIntervalSeconds: 180,
            summaryProvider: .apple,
            summaryModel: nil
        ))
        await session.startRecording(at: audioURL, consent: true)
        capture.emit(try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 4_800),
            samplePosition: 0,
            monotonicTime: 1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.25
        ))
        await waitUntil { socket.sent.count >= 2 }
        session.applyRemotePermissionChanges(liveTranscriptionAllowed: false)
        let sentBeforeLocalOnlyChunk = socket.sent.count
        capture.emit(try EncounterAudioChunk(
            pcm16: Data(repeating: 2, count: 4_800),
            samplePosition: 2_400,
            monotonicTime: 1.1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.5
        ))
        await Task.yield()

        #expect(session.isRecording)
        #expect(session.microphoneLevel == 0.5)
        #expect(socket.sent.count == sentBeforeLocalOnlyChunk)
        #expect(session.status.contains("somente neste Mac"))

        session.stop()
        await waitUntil { !session.isBusy }
        #expect(session.progressiveWork?.status == .incomplete)
        #expect(session.progressiveWork?.pendingRanges.last?.endSeconds == 0.2)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        session.shutdown()
    }

    @Test("realtime reconnect keeps the local recording and preserves the network gap")
    func realtimeReconnectPreservesGap() async throws {
        let fixture = try WorkFixture()
        defer { fixture.remove() }
        let audioURL = fixture.root.appending(path: "consulta-reconexao-sintetica.wav")
        let capture = WorkLiveMicrophoneCapture()
        let firstSocket = WorkRealtimeSocket()
        let secondSocket = WorkRealtimeSocket()
        let socketPool = WorkRealtimeSocketPool(sockets: [firstSocket, secondSocket])
        let session = EncounterTranscriptionSession(
            liveMicrophoneCapture: capture,
            realtimeFactory: { handler in socketPool.makeService(eventHandler: handler) },
            liveTranscriptionConfiguration: {
                ("sk-synthetic-key-never-sent", OpenAIRealtimeTranscription.model)
            },
            liveTranscriptionPermission: { true },
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: WorkSummaryGenerator())
            },
            liveDrainDelay: .zero,
            realtimeReconnectDelay: { _ in .zero }
        )
        #expect(session.prepare(
            binding: fixture.binding,
            onPersist: { _, _, _ in },
            onPersistWork: { document, _ in try ProgressiveConsultationWorkStore().encode(document) }
        ))
        session.configureProgressive(.init(
            source: .microphone,
            usesLiveTranscription: true,
            summaryIntervalSeconds: 180,
            summaryProvider: .apple,
            summaryModel: nil
        ))
        await session.startRecording(at: audioURL, consent: true)
        capture.emit(try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 4_800),
            samplePosition: 0,
            monotonicTime: 1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.25
        ))
        await waitUntil { firstSocket.sent.count >= 2 }

        firstSocket.emit(#"{"type":"error","event_id":"event_disconnect","error":{"message":"synthetic"}}"#)
        await waitUntil { socketPool.serviceCount == 2 && secondSocket.sent.count == 1 }

        capture.emit(try EncounterAudioChunk(
            pcm16: Data(repeating: 2, count: 4_800),
            samplePosition: 2_400,
            monotonicTime: 1.1,
            format: .pcm16Mono24k,
            source: .microphone,
            level: 0.5
        ))
        await waitUntil { secondSocket.sent.count >= 2 }
        secondSocket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_after_reconnect","content_index":0,"transcript":"Trecho sintético após reconexão."}"#)
        await waitUntil { session.progressiveWork?.segments.count == 1 }

        session.stop()
        await waitUntil { !session.isBusy }

        #expect(firstSocket.sent.count == 2)
        #expect(session.progressiveWork?.segments.map(\.text) == ["Trecho sintético após reconexão."])
        #expect(session.progressiveWork?.pendingRanges.isEmpty == false)
        #expect(session.progressiveWork?.status == .incomplete)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        session.shutdown()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        // Other suites share MainActor and can occupy it for several seconds
        // on CI. Check completion after resumption before evaluating timeout.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("A condição sintética não foi alcançada no limite do teste")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class WorkFixture {
    let root: URL
    let binding: EncounterTranscriptionBinding
    let now = Date(timeIntervalSince1970: 1_788_585_840)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "openpep-progressive-work-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        binding = EncounterTranscriptionBinding(
            vaultURL: root,
            vaultID: "vlt_0198f5c0-0000-7000-8000-000000000501",
            patientID: "pt_0198f5c2-0000-7000-8000-000000000501",
            encounterID: "enc_0198f5d1-0000-7000-8000-000000000501",
            patientName: "Paciente Sintético"
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "patients/\(binding.patientID)/content", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func segment(attemptID: String) -> ConsultationTranscriptSegment {
        ConsultationTranscriptSegment(
            id: "segment_0198f5da-0000-7000-8000-000000000501",
            revision: 1,
            range: .init(startSeconds: 0, endSeconds: 5, isApproximate: true),
            text: "Paciente sintético nega febre.",
            engine: "openai/realtime",
            model: "gpt-live-transcribe",
            attemptID: attemptID
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor WorkTranscriptionEngine: LocalTranscriptionEngine {
    func availability(for locale: Locale) async -> LocalTranscriptionAvailability {
        .ready(localeIdentifier: "pt-BR")
    }

    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String {
        "Paciente sintético nega febre."
    }

    func cancel(operationID: UUID) {}
}

private actor StaticSummaryGenerator: ProgressiveSummaryGenerating {
    let operations: [ProgressiveSummaryOperation]

    init(operations: [ProgressiveSummaryOperation]) {
        self.operations = operations
    }

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        ProgressiveSummaryEngineOutput(
            operations: operations,
            engine: "apple/FoundationModels.SystemLanguageModel",
            model: nil,
            responseID: nil
        )
    }
}

private actor JSONSummaryGenerator: ProgressiveSummaryGenerating {
    let json: String

    init(json: String) {
        self.json = json
    }

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        ProgressiveSummaryEngineOutput(
            operations: try progressiveOperations(from: json, currentItems: request.currentItems),
            engine: "apple/FoundationModels.SystemLanguageModel",
            model: nil,
            responseID: nil
        )
    }
}

private struct SyntheticPersistenceFailure: Error {}

private actor DelayedSummaryGenerator: ProgressiveSummaryGenerating {
    private var continuation: CheckedContinuation<ProgressiveSummaryEngineOutput, Never>?
    private var started = false

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func finish(reference: ConsultationTranscriptSegmentReference) {
        continuation?.resume(returning: ProgressiveSummaryEngineOutput(
            operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Resposta atrasada que não deve ser aplicada.",
                references: [reference]
            )],
            engine: "apple/FoundationModels.SystemLanguageModel",
            model: nil,
            responseID: nil
        ))
        continuation = nil
    }
}

private actor TargetedVerificationGenerator: ProgressiveSummaryGenerating {
    private let targetItemID: String
    private var requests: [ProgressiveSummaryRequest] = []

    init(targetItemID: String) { self.targetItemID = targetItemID }

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        requests.append(request)
        return ProgressiveSummaryEngineOutput(
            operations: [.init(
                action: .replace,
                targetItemID: targetItemID,
                text: "Uso de 10 mg.",
                references: []
            )],
            engine: "apple/FoundationModels.SystemLanguageModel",
            model: nil,
            responseID: nil
        )
    }

    func requestCount() -> Int { requests.count }

    func lastVerificationReferences() -> [ConsultationTranscriptSegmentReference] {
        requests.last?.verificationSegments.map {
            .init(segmentID: $0.id, revision: $0.revision)
        } ?? []
    }
}

private actor WorkSummaryGenerator: ProgressiveSummaryGenerating {
    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        ProgressiveSummaryEngineOutput(
            operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Paciente sintético nega febre.",
                references: request.newReferences
            )],
            engine: "apple/FoundationModels.SystemLanguageModel",
            model: nil,
            responseID: nil
        )
    }
}

private actor RecordingSummaryGenerator: ProgressiveSummaryGenerating {
    private var requests: [ProgressiveSummaryRequest] = []
    let provider: ProgressiveSummaryProvider
    init(provider: ProgressiveSummaryProvider = .apple) { self.provider = provider }

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        requests.append(request)
        let operations: [ProgressiveSummaryOperation]
        if request.isFinalReview {
            operations = []
        } else {
            operations = [.init(
                action: .add,
                targetItemID: nil,
                text: "Resumo do minuto \(requests.filter { !$0.isFinalReview }.count).",
                references: []
            )]
        }
        return ProgressiveSummaryEngineOutput(
            operations: operations,
            engine: provider == .openAI ? "openai/responses" : ConsultationSummaryProvenance.engine,
            model: provider == .openAI ? "gpt-4o" : nil,
            responseID: provider == .openAI ? "resp_synthetic_summary" : nil
        )
    }

    func incrementalRequestCount() -> Int { requests.filter { !$0.isFinalReview }.count }
    func finalReviewRequestCount() -> Int { requests.filter { $0.isFinalReview }.count }
    func lastIncrementalVerificationCount() -> Int {
        requests.last(where: { !$0.isFinalReview })?.verificationSegments.count ?? 0
    }
}

private actor SnapshotSummaryGenerator: ProgressiveSummaryGenerating {
    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        ProgressiveSummaryEngineOutput(
            operations: [.init(
                action: .add,
                targetItemID: nil,
                text: "Queixa com evolução de oito meses.",
                references: []
            )],
            engine: "openai/responses",
            model: "gpt-4o-synthetic-snapshot",
            responseID: "resp_synthetic_snapshot"
        )
    }
}

private actor FailingSummaryGenerator: ProgressiveSummaryGenerating {
    private var requests = 0

    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        requests += 1
        throw ProgressiveSummaryIssue.invalidResponse
    }

    func requestCount() -> Int { requests }
}

@MainActor
private final class WorkLiveMicrophoneCapture: EncounterLiveMicrophoneCapturing {
    var failsStart = false
    private var chunkHandler: (@Sendable (EncounterAudioChunk) -> Void)?
    private var eventHandler: (@Sendable (EncounterLiveCaptureEvent) -> Void)?
    private(set) var didPause = false
    private(set) var didResume = false
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0

    func requestAccess() async -> Bool { true }

    func start(
        at url: URL,
        maximumDuration: TimeInterval,
        chunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterLiveCaptureEvent) -> Void
    ) throws {
        if failsStart { throw EncounterLiveAudioIssue.fileWriteFailed }
        try Data("audio sintetico ao vivo".utf8).write(to: url, options: [.withoutOverwriting])
        self.chunkHandler = chunkHandler
        self.eventHandler = eventHandler
    }

    func stop() {
        let handler = eventHandler
        chunkHandler = nil
        eventHandler = nil
        handler?(.finished)
    }

    func pause() async throws {
        didPause = true
        pauseCount += 1
    }

    func resume() async throws {
        didResume = true
        resumeCount += 1
    }

    func emit(_ chunk: EncounterAudioChunk) { chunkHandler?(chunk) }
}

@MainActor
private final class WorkAppleLiveTranscription: AppleLiveTranscribing {
    var eventHandler: (@MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void)?
    private(set) var chunks: [EncounterAudioChunk] = []
    private(set) var didFinish = false

    func start(locale: Locale) async throws {}
    func enqueue(_ chunk: EncounterAudioChunk) -> Bool {
        chunks.append(chunk)
        return true
    }
    func finish() async throws { didFinish = true }
    func cancel() async {}
    func emit(_ event: AppleLiveTranscriptionEvent) { eventHandler?(event) }
}

@MainActor
private final class WorkRealtimeSocketFactory: OpenAIRealtimeSocketFactory {
    let socket: WorkRealtimeSocket

    init(socket: WorkRealtimeSocket) { self.socket = socket }

    func connect(apiKey: String) throws -> any OpenAIRealtimeSocket { socket }
}

@MainActor
private final class WorkRealtimeSocketPool {
    private let sockets: [WorkRealtimeSocket]
    private(set) var serviceCount = 0

    init(sockets: [WorkRealtimeSocket]) { self.sockets = sockets }

    func makeService(
        eventHandler: @escaping @Sendable (OpenAIRealtimeEvent) -> Void
    ) -> OpenAIRealtimeTranscription {
        let index = min(serviceCount, sockets.count - 1)
        serviceCount += 1
        return OpenAIRealtimeTranscription(
            socketFactory: WorkRealtimeSocketFactory(socket: sockets[index]),
            eventHandler: eventHandler
        )
    }
}

@MainActor
private final class WorkRealtimeSocket: OpenAIRealtimeSocket {
    private var incoming: [Data] = [Data(#"{"type":"session.updated","session":{"type":"transcription"}}"#.utf8)]
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var sent: [Data] = []

    func send(_ data: Data) async throws { sent.append(data) }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func close() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func emit(_ event: String) {
        let data = Data(event.utf8)
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }
}
