// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import OpenPEP

@Suite("ASSISTANT-001 closed intent and local resolution")
struct AssistantIntentTests {
    @Test func decoder() throws {
        #expect(try AssistantIntent.decode(#"{"action":"openPatient","query":" José Fictício "}"#) == .openPatient("José Fictício"))
        #expect(try AssistantIntent.decode(#"{"action":"unsupported","query":""}"#) == .unsupported)
        for text in ["invalid", "[]", #"{"action":"openPatient","query":""}"#,
                     #"{"action":"openPatient","query":"Ana","patientID":"invented"}"#,
                     #"{"action":"reissuePrescription","query":"Ana"}"#,
                     #"{"action":"openPatient","query":["Ana","José"]}"#,
                     #"{"action":"unsupported","query":"Ana"}"#,
                     #"{"action":"openPatient","query":"Ana\nFictícia"}"#,
                     String(repeating: "x", count: 8_193)] {
            #expect(throws: OpenAITextIssue.invalidResponse) { try AssistantIntent.decode(text) }
        }
    }

    @Test func historyDecoderAndContext() throws {
        #expect(try AssistantIntent.decode(#"{"action":"openHistory","query":" Ana Fictícia "}"#) == .openHistory("Ana Fictícia"))
        #expect(try AssistantIntent.decode(#"{"action":"openHistory","query":""}"#) == .openHistory(""))
        for value in [#"{"action":"openHistory","query":"Ana\nFictícia"}"#,
                      #"{"action":"openHistory","query":"Ana","patientID":"pt_invented"}"#] {
            #expect(throws: OpenAITextIssue.invalidResponse) { try AssistantIntent.decode(value) }
        }
        let ana = patient("1", "Ana Fictícia"), sameName = patient("2", "Ana Fictícia")
        let context = try AssistantPatientMatches.contextual(patientID: sameName.patientID, in: [ana, sameName])
        #expect(context.unambiguousPatient == sameName)
        #expect(throws: AssistantIssue.self) { try AssistantPatientMatches.contextual(patientID: nil, in: [ana]) }
        #expect(throws: AssistantIssue.self) { try AssistantPatientMatches.contextual(patientID: "missing", in: [ana]) }
        let archived = patient("3", "José Sintético", archived: true)
        #expect(throws: AssistantIssue.self) { try AssistantPatientMatches.contextual(patientID: archived.patientID, in: [archived]) }
        #expect(AssistantPatientMatches.resolve("Ana Fictícia", in: [ana, sameName]).unambiguousPatient == nil)
        #expect(AssistantPatientMatches.resolve("Ana Fictíca", in: [ana]).unambiguousPatient == nil)
    }

    @Test func localCandidates() {
        let ana = patient("1", "Ana Fictícia"), ana2 = patient("2", "Ana Fictícia")
        let archived = patient("3", "José Sintético", archived: true)
        #expect(AssistantPatientMatches.resolve("ANA FICTICIA", in: [ana, ana2, archived]).patients.count == 2)
        #expect(AssistantPatientMatches.resolve("José Sintético", in: [archived]).patients.isEmpty)
        #expect(AssistantPatientMatches.resolve("Inexistente", in: [ana]).patients.isEmpty)
        #expect(AssistantPatientMatches.resolve("", in: [ana]).patients.isEmpty)
        let typo = AssistantPatientMatches.resolve("Ana Fictíca", in: [ana])
        #expect(typo.approximate && typo.patients == [ana])
        #expect(!AssistantPatientMatches.resolve("Ana Fictícia", in: [ana]).approximate)
    }

    @Test func documentIntentContainsIdentityOnlyAndDraftPreservesProfessionalText() throws {
        #expect(try AssistantIntent.decode(#"{"action":"prepareDocument","query":" Ana Fictícia "}"#) == .prepareDocument("Ana Fictícia"))
        #expect(try AssistantIntent.decode(#"{"action":"prepareDocument","query":""}"#) == .prepareDocument(""))
        for text in [#"{"action":"prepareDocument","query":"Ana","text":"Inventado pelo modelo"}"#,
                     #"{"action":"emitDocument","query":"Ana"}"#,
                     #"{"action":"prepareDocument","query":"Ana\nFictícia"}"#] {
            #expect(throws: OpenAITextIssue.invalidResponse) { try AssistantIntent.decode(text) }
        }
        let draft = AssistantDocumentDraft(title: "Declaração sintética", text: "Linha livre, sem alteração.\n\n  Segundo parágrafo: não inferir nada.\n")
        let page = try LinearConsultationPage(body: draft.composerBody())
        #expect(page.customTitle == draft.title)
        #expect(page.text(for: .custom) == draft.text)
        #expect(page.consultation.isEmpty)
        #expect(throws: ConsultationFieldsError.emptyDocument) { try AssistantDocumentDraft(title: "", text: "Texto").composerBody() }
        #expect(throws: ConsultationFieldsError.emptyDocument) { try AssistantDocumentDraft(title: "Finalidade", text: " \n").composerBody() }
        #expect(throws: ConsultationFieldsError.ambiguous) { try AssistantDocumentDraft(title: "Finalidade", text: ConsultationFields.start).composerBody() }
        #expect(throws: ConsultationFieldsError.tooLarge) { try AssistantDocumentDraft(title: "Finalidade", text: String(repeating: "x", count: 20_001)).composerBody() }
    }
}

@Suite("ASSISTANT-001 cancellable window session", .serialized)
@MainActor struct AssistantSessionTests {
    @Test func uniqueAndUnsupported() async throws {
        let session = AssistantSession(), ana = patient("1", "Ana Fictícia")
        var opened: [String] = []
        session.prompt = "Quero ver o cadastro de Ana Fictícia"
        session.submit(interpret: { _ in .openPatient("Ana Fictícia") },
                       resolve: { _ in .init(patients: [ana], approximate: false) },
                       navigate: { _, matches in opened.append(contentsOf: matches.patients.map(\.patientID)) })
        try await settled(session)
        #expect(opened == [ana.patientID])
        session.prompt = "Reemita a receita de Ana Fictícia"
        session.submit(interpret: { _ in .unsupported }, resolve: { _ in Issue.record("unsupported must not resolve"); return .init(patients: [], approximate: false) }, navigate: { _, _ in Issue.record("unsupported must not navigate") })
        try await settled(session)
        #expect(session.message?.contains("Por enquanto") == true)
    }

    @Test func resultsRouteToFilteredList() async throws {
        let ana = patient("1", "Ana Fictícia"), other = patient("2", "Ana Fictícia"), outside = patient("3", "Outro Exemplo")
        for (query, patients, approximate, expectedCount) in [
            ("Ana Fictícia", [ana, outside], false, 1),
            ("Ana Fictícia", [ana, other, outside], false, 2),
            ("Ana Fictíca", [ana, outside], true, 1)
        ] {
            let session = AssistantSession()
            session.prompt = "Busque " + query
            var filter: AssistantPatientFilter?
            session.submit(interpret: { _ in .openPatient(query) },
                           resolve: { AssistantPatientMatches.resolve($0, in: patients) },
                           navigate: { filter = AssistantPatientFilter(query: $0.query, matches: $1) })
            try await settled(session)
            let result = try #require(filter)
            #expect(result.patientIDs.count == expectedCount && result.approximate == approximate)
            #expect(!result.includes(outside))
            #expect(result.includes(ana))
            #expect(result.expandedPatientID == (expectedCount == 1 && !approximate ? ana.patientID : nil))
        }
    }

    @Test func historyPreservesActionAndExplicitNameOverridesContext() async throws {
        let ana = patient("1", "Ana Fictícia"), jose = patient("2", "José Sintético")
        for intent in [AssistantIntent.openHistory("Ana Fictícia"), .openHistory("")] {
            let session = AssistantSession()
            session.prompt = "Abra o histórico"
            var received: AssistantIntent?, opened: PatientSummary?
            session.submit(interpret: { _ in intent }, resolve: { query in
                query.isEmpty
                    ? try AssistantPatientMatches.contextual(patientID: jose.patientID, in: [ana, jose])
                    : AssistantPatientMatches.resolve(query, in: [ana, jose])
            }, navigate: { action, matches in received = action; opened = matches.unambiguousPatient })
            try await settled(session)
            #expect(received == intent && received?.opensHistory == true)
            #expect(opened == (intent.query.isEmpty ? jose : ana))
        }
        let session = AssistantSession()
        session.prompt = "Abra o histórico deste paciente"
        session.submit(interpret: { _ in .openHistory("") }, resolve: { _ in
            try AssistantPatientMatches.contextual(patientID: nil, in: [ana])
        }, navigate: { _, _ in Issue.record("missing context must not navigate") })
        try await settled(session)
        #expect(session.message == AssistantIssue.missingPatient.localizedDescription)
    }

    @Test func historyAmbiguityRetainsExplicitChoice() async throws {
        let ana = patient("1", "Ana Fictícia"), other = patient("2", "Ana Fictícia")
        for (query, patients) in [("Ana Fictícia", [ana, other]), ("Ana Fictíca", [ana])] {
            let session = AssistantSession()
            session.prompt = "Abra o histórico de " + query
            var filter: AssistantPatientFilter?
            session.submit(interpret: { _ in .openHistory(query) },
                resolve: { AssistantPatientMatches.resolve($0, in: patients) }, navigate: { intent, matches in
                    #expect(matches.unambiguousPatient == nil)
                    filter = AssistantPatientFilter(query: intent.query, matches: matches, opensHistory: intent.opensHistory)
                })
            try await settled(session)
            #expect(filter?.opensHistory == true && filter?.expandedPatientID == nil)
            #expect(filter?.patientIDs == Set(patients.map(\.patientID)))
        }
    }

    @Test func lateResponseCannotAffectNewRequestOrOtherWindow() async throws {
        let first = AssistantSession(), second = AssistantSession()
        let gate = AssistantTestGate()
        var resolved = 0, opened = 0
        first.prompt = "Abra o histórico de Ana Fictícia"
        first.submit(interpret: { _ in await gate.wait() }, resolve: { _ in resolved += 1; return .init(patients: [], approximate: false) }, navigate: { _, _ in opened += 1 })
        try await until { gate.continuation != nil }
        first.reset()
        second.prompt = "Outro pedido"
        gate.continuation?.resume(returning: .openHistory("Ana"))
        // A marker on the same actor lets the resumed continuation run.
        for _ in 0..<20 { await Task.yield() }
        #expect(resolved == 0 && opened == 0)
        #expect(second.prompt == "Outro pedido" && second.message == nil)
    }

    @Test func failuresAndOversizedInputDoNotNavigate() async throws {
        let session = AssistantSession()
        session.prompt = String(repeating: "x", count: 4_001)
        session.submit(interpret: { _ in Issue.record("must not send oversized input"); return .unsupported }, resolve: { _ in .init(patients: [], approximate: false) }, navigate: { _, _ in Issue.record("must not navigate") })
        #expect(!session.isBusy && session.message != nil)
        session.prompt = "Busque Ana Fictícia"
        session.submit(interpret: { _ in throw OpenAITextIssue.networkUnavailable }, resolve: { _ in Issue.record("must not resolve on failure"); return .init(patients: [], approximate: false) }, navigate: { _, _ in Issue.record("must not navigate") })
        try await settled(session)
        #expect(session.message == OpenAITextIssue.networkUnavailable.localizedDescription)
    }

    @Test func cancelledResolutionDoesNotNavigate() async throws {
        let session = AssistantSession(), gate = AssistantTestGate()
        var opened = 0
        session.prompt = "Abra Ana"
        session.submit(interpret: { _ in .openPatient("Ana") }, resolve: { _ in
            _ = await gate.wait()
            return .init(patients: [patient("1", "Ana Fictícia")], approximate: false)
        }, navigate: { _, _ in opened += 1 })
        try await until { gate.continuation != nil }
        session.prompt = "Novo pedido"
        gate.continuation?.resume(returning: .unsupported)
        for _ in 0..<20 { await Task.yield() }
        #expect(opened == 0)
    }

    @Test func questionsChooseIdentityAndKeepSourceInPanel() async throws {
        #expect(try AssistantIntent.decode(#"{"action":"askPatient","query":""}"#) == .askPatient(""))
        #expect(try AssistantIntent.decode(#"{"action":"askPatient","query":"Ana Fictícia"}"#) == .askPatient("Ana Fictícia"))
        let session = AssistantSession()
        let people = [patient("1", "Ana Fictícia"), patient("2", "Ana Fictícia")]
        var requested: [String] = []
        session.prompt = "Como está a função renal de Ana Fictícia?"
        let original = session.prompt
        session.submit(interpret: { _ in .askPatient("Ana Fictícia") },
            resolve: { AssistantPatientMatches.resolve($0, in: people) },
            navigate: { _, _ in Issue.record("Question must stay in panel") }, answer: { question, person in
                #expect(question == original)
                requested.append(person.patientID)
                return syntheticAssistantAnswer()
            })
        try await settled(session)
        #expect(requested.isEmpty && session.candidates.count == 2)
        session.choose(people[1])
        try await settled(session)
        #expect(requested == [people[1].patientID])
        let answer = try #require(session.answer)
        session.source = answer.entries.first
        #expect(session.source?.text.contains("1,0 mg/dL") == true)
        session.source = nil
        #expect(session.answer?.result.text == answer.result.text && session.prompt == original)
        session.prompt = ""
        #expect(session.answer == nil && session.source == nil && session.candidates.isEmpty)
    }

    @Test func cancelledQuestionCannotPublishAndUnconnectedQuestionIsRefused() async throws {
        let session = AssistantSession(), gate = AssistantTestGate()
        let person = patient("1", "Ana Fictícia")
        session.prompt = "Como está a função renal deste paciente?"
        session.submit(interpret: { _ in .askPatient("") },
            resolve: { _ in .init(patients: [person], approximate: false) },
            navigate: { _, _ in Issue.record("Question must not navigate") }, answer: { _, _ in
                _ = await gate.wait()
                return syntheticAssistantAnswer()
            })
        try await until { gate.continuation != nil }
        session.cancel()
        gate.continuation?.resume(returning: .unsupported)
        for _ in 0..<20 { await Task.yield() }
        #expect(session.answer == nil)
        session.submit(interpret: { _ in .askPatient("") },
            resolve: { _ in .init(patients: [person], approximate: false) },
            navigate: { _, _ in Issue.record("Question must not navigate") })
        try await settled(session)
        #expect(session.answer == nil && session.message == AssistantIssue.unavailable.localizedDescription)
    }

    @Test func documentPreparationRequiresIdentityChoiceAndProfessionalContent() async throws {
        let people = [patient("1", "Ana Fictícia"), patient("2", "Ana Fictícia")]
        for query in ["Ana Fictícia", "Ana Fictíca"] {
            let session = AssistantSession()
            var opened: [(AssistantDocumentDraft, String)] = []
            session.prompt = "Prepare um documento personalizado para " + query
            session.submit(interpret: { _ in .prepareDocument(query) },
                resolve: { AssistantPatientMatches.resolve($0, in: people) },
                navigate: { _, _ in Issue.record("Preparation must not navigate or start encounter") },
                prepare: { draft, person in opened.append((draft, person.patientID)) })
            try await settled(session)
            #expect(session.documentPatient == nil && !session.candidates.isEmpty && opened.isEmpty)
            session.choose(people[1])
            #expect(session.documentPatient == people[1] && session.candidates.isEmpty)
            session.openDocumentComposer()
            #expect(opened.isEmpty && !session.canOpenDocumentComposer)
            session.documentTitle = "Declaração sintética"
            session.documentText = "Texto informado pelo profissional.\nNão acrescentar conteúdo."
            #expect(session.canOpenDocumentComposer && opened.isEmpty)
            session.openDocumentComposer()
            try await settled(session)
            #expect(opened.count == 1 && opened.first?.1 == people[1].patientID)
            #expect(opened.first?.0.text == "Texto informado pelo profissional.\nNão acrescentar conteúdo.")
            #expect(session.documentPatient == nil && session.documentText.isEmpty)
        }
    }

    @Test func documentPreparationRespectsContextAndExplicitIdentity() async throws {
        let ana = patient("1", "Ana Fictícia"), jose = patient("2", "José Sintético")
        for query in ["Ana Fictícia", ""] {
            let session = AssistantSession()
            session.prompt = "Prepare um documento personalizado"
            session.submit(interpret: { _ in .prepareDocument(query) }, resolve: { query in
                query.isEmpty ? try AssistantPatientMatches.contextual(patientID: jose.patientID, in: [ana, jose])
                    : AssistantPatientMatches.resolve(query, in: [ana, jose])
            }, navigate: { _, _ in Issue.record("must stay in panel") }, prepare: { _, _ in Issue.record("content must be supplied first") })
            try await settled(session)
            #expect(session.documentPatient == (query.isEmpty ? jose : ana))
            session.documentTitle = "Título"; session.documentText = "Texto"
            session.prompt = "Novo pedido"
            #expect(session.documentPatient == nil && session.documentText.isEmpty && !session.canOpenDocumentComposer)
        }
        let session = AssistantSession()
        session.prompt = "Prepare um documento personalizado"
        session.submit(interpret: { _ in .prepareDocument("") }, resolve: { _ in
            try AssistantPatientMatches.contextual(patientID: nil, in: [ana, jose])
        }, navigate: { _, _ in Issue.record("missing identity must not navigate") },
        prepare: { _, _ in Issue.record("missing identity must not prepare") })
        try await settled(session)
        #expect(session.documentPatient == nil && session.message == AssistantIssue.missingPatient.localizedDescription)
    }

    @Test func editedDocumentCancelsLatePreparationAndChangedContextIsRefused() async throws {
        let session = AssistantSession(), gate = AssistantTestGate(), ana = patient("1", "Ana Fictícia")
        var opened = 0
        session.prompt = "Prepare um documento personalizado"
        session.submit(interpret: { _ in .prepareDocument("") },
            resolve: { _ in .init(patients: [ana], approximate: false) },
            navigate: { _, _ in Issue.record("must not navigate") }, prepare: { _, _ in
                _ = await gate.wait()
                try Task.checkCancellation()
                opened += 1
            })
        try await settled(session)
        session.documentTitle = "Finalidade"; session.documentText = "Texto inicial"
        session.openDocumentComposer()
        try await until { gate.continuation != nil }
        session.documentText = "Texto revisado"
        gate.continuation?.resume(returning: .unsupported)
        for _ in 0..<20 { await Task.yield() }
        #expect(opened == 0 && session.documentText == "Texto revisado")
        session.prompt = "Prepare outro documento"
        session.submit(interpret: { _ in .prepareDocument("") },
            resolve: { _ in .init(patients: [ana], approximate: false) },
            navigate: { _, _ in Issue.record("must not navigate") }, prepare: { _, _ in throw AssistantIssue.changed })
        try await settled(session)
        session.documentTitle = "Finalidade"; session.documentText = "Texto"
        session.openDocumentComposer()
        try await settled(session)
        #expect(opened == 0 && session.message == AssistantIssue.changed.localizedDescription)
        #expect(session.documentText == "Texto")
    }

    @Test func localWikiReadingUsesOnlyItsReaderAndPreservesPrompt() async throws {
        let session = AssistantSession()
        let snapshot = try syntheticLocalWikiReading()
        session.prompt = "Pedido profissional preservado"
        var reads = 0
        session.readWiki { reads += 1; return snapshot }
        try await settled(session)
        #expect(reads == 1 && session.localReading?.fingerprint == snapshot.fingerprint)
        #expect(session.answer == nil && session.prompt == "Pedido profissional preservado")
        #expect(!session.isReadingWiki)
        session.cancel()
        #expect(session.localReading?.fingerprint == snapshot.fingerprint)
        session.source = snapshot.entries.first
        session.invalidateLocalReading()
        #expect(session.localReading == nil && session.source == nil)
        #expect(session.message?.contains("fontes atuais") == true)
        #expect(session.prompt == "Pedido profissional preservado")
        session.prompt = "Novo pedido"
        #expect(session.localReading == nil && session.message == nil)
    }

    @Test func localWikiReadingRejectsLateResultsAfterEditCancelResetOrInvalidation() async throws {
        let snapshot = try syntheticLocalWikiReading()
        for action in ["edit", "cancel", "reset", "invalidate"] {
            let session = AssistantSession(), gate = AssistantLocalReadingGate()
            session.prompt = "Pedido inicial"
            session.readWiki { await gate.wait() }
            try await until { gate.continuation != nil }
            #expect(session.isReadingWiki && session.localReading == nil)
            switch action {
            case "edit": session.prompt = "Pedido revisado"
            case "cancel": session.cancel()
            case "reset": session.reset()
            default: session.invalidateLocalReading()
            }
            #expect(!session.isBusy && !session.isReadingWiki)
            gate.continuation?.resume(returning: snapshot)
            for _ in 0..<20 { await Task.yield() }
            #expect(session.localReading == nil && session.answer == nil)
            if action == "invalidate" { #expect(session.message?.contains("fontes atuais") == true) }
        }
    }

    @Test func localWikiInvalidationDoesNotCancelAnUnrelatedInterpreter() async throws {
        let session = AssistantSession(), gate = AssistantTestGate()
        session.prompt = "Pedido de interpretação"
        session.submit(interpret: { _ in await gate.wait() },
            resolve: { _ in Issue.record("Unsupported must not resolve"); return .init(patients: [], approximate: false) },
            navigate: { _, _ in Issue.record("Unsupported must not navigate") })
        try await until { gate.continuation != nil }
        session.invalidateLocalReading()
        #expect(session.isBusy && !session.isReadingWiki && session.message == nil)
        gate.continuation?.resume(returning: .unsupported)
        try await settled(session)
        #expect(session.message != nil && session.localReading == nil)
        session.submit(interpret: { _ in .askPatient("Ana") },
            resolve: { _ in .init(patients: [patient("1", "Ana Fictícia")], approximate: false) },
            navigate: { _, _ in Issue.record("Question must not navigate") },
            answer: { _, _ in syntheticAssistantAnswer() })
        try await settled(session)
        session.source = session.answer?.entries.first
        session.invalidateLocalReading()
        #expect(session.answer != nil && session.source != nil && session.message == nil)
    }

    @Test func localWikiReadFailureCannotRepublishPreviousReading() async throws {
        let session = AssistantSession(), snapshot = try syntheticLocalWikiReading()
        session.readWiki { snapshot }
        try await settled(session)
        #expect(session.localReading != nil)
        session.readWiki { throw PatientAIIssue.changed }
        try await settled(session)
        #expect(session.localReading == nil && session.message != nil && !session.isReadingWiki)
        session.invalidateLocalReading()
        #expect(session.message == PatientAIIssue.changed.localizedDescription)
    }

    private func settled(_ session: AssistantSession) async throws { try await until { !session.isBusy } }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

@MainActor private final class AssistantTestGate {
    var continuation: CheckedContinuation<AssistantIntent, Never>?
    func wait() async -> AssistantIntent { await withCheckedContinuation { continuation = $0 } }
}

private func patient(_ suffix: String, _ name: String, archived: Bool = false) -> PatientSummary {
    let id = "pt_0198f5c2-0000-7000-8000-00000000000" + suffix
    let record = PatientRecord(schema: "openpep/patient@1", patientID: id, status: archived ? .archived : .active,
        fullName: name, preferredName: nil, birthDate: "2000-01-01", contacts: [], identifiers: [], alerts: [],
        createdAt: "2026-09-09T00:00:00Z", updatedAt: "2026-09-09T00:00:00Z",
        archivedAt: archived ? "2026-09-09T00:00:00Z" : nil, extensions: [:])
    return PatientSummary(patientID: id, url: URL(fileURLWithPath: "/synthetic/" + id),
                          record: record, rawAssets: [], encounters: [])
}

func syntheticAssistantAnswer() -> PatientAIAnswer {
    PatientAIAnswer(result: .init(text: "Creatinina: 1,0 mg/dL em 01/09/2026 [F1].", model: "synthetic", responseID: "synthetic"),
        generationID: "synthetic", promptVersion: "synthetic", sourceText: "synthetic", sourceFingerprint: "synthetic",
        entries: [.init(id: "synthetic", title: "Exame sintético", timestamp: "2026-09-01T12:00:00Z", status: "Documento sintético",
            text: "Coleta em 01/09/2026. Creatinina: 1,0 mg/dL.", source: "synthetic", assetID: nil, issue: nil)], corrections: "")
}

@MainActor private final class AssistantLocalReadingGate {
    var continuation: CheckedContinuation<PatientWikiReadingSnapshot, Never>?
    func wait() async -> PatientWikiReadingSnapshot { await withCheckedContinuation { continuation = $0 } }
}

func syntheticLocalWikiReading() throws -> PatientWikiReadingSnapshot {
    let person = patient("1", "Ana Fictícia")
    let entry = PatientHistoryEntry(id: "enc_0198f5c3-0000-7000-8000-000000000001",
        title: "Consulta inteiramente sintética", timestamp: "2026-09-17T12:00:00Z", status: "Finalizada",
        text: "Informação sintética confirmada somente no texto de ensaio.",
        source: "content/notes/final/synthetic.md", assetID: nil, issue: nil)
    let context = try PatientWikiContext.make(patient: person, entries: [entry], corrections: "")
    let summary = PatientWikiSummary(markdown: "# Resumo breve\n\nLeitura inteiramente sintética. [F1]",
        sourceFingerprint: context.fingerprint, model: "synthetic", generatedAt: "2026-09-17T12:00:00Z",
        sources: [.init(id: entry.id, path: entry.source, sha256: PatientAIContext.digest(Data(entry.text.utf8)))],
        overview: "Leitura inteiramente sintética.", exclusions: context.exclusions, proposals: [],
        persistedData: Data("synthetic-local-reading".utf8))
    return try PatientWikiReadingSnapshot.make(context: context,
        wiki: .init(summary: summary, corrections: nil, summaryIssue: nil, correctionsIssue: nil),
        reviews: nil, reviewData: nil)
}
