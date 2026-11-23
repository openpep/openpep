// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

enum AssistantIntent: Equatable, Sendable {
    case openPatient(String)
    case openHistory(String)
    case askPatient(String)
    case prepareDocument(String)

    var query: String {
        switch self { case let .openPatient(query), let .openHistory(query), let .askPatient(query), let .prepareDocument(query): query; case .unsupported: "" }
    }
    var opensHistory: Bool { if case .openHistory = self { true } else { false } }
    case unsupported

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 8_192,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["action", "query"],
              let action = object["action"] as? String,
              let query = object["query"] as? String else { throw OpenAITextIssue.invalidResponse }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "askPatient" where term.isEmpty: return .askPatient("")
        case "openHistory" where term.isEmpty: return .openHistory("")
        case "prepareDocument" where term.isEmpty: return .prepareDocument("")
        case "openPatient", "openHistory", "askPatient", "prepareDocument":
            guard (2...200).contains(term.count),
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw OpenAITextIssue.invalidResponse
            }
            if action == "askPatient" { return .askPatient(term) }
            if action == "prepareDocument" { return .prepareDocument(term) }
            return action == "openHistory" ? .openHistory(term) : .openPatient(term)
        case "unsupported":
            guard term.isEmpty else { throw OpenAITextIssue.invalidResponse }
            return .unsupported
        default: throw OpenAITextIssue.invalidResponse
        }
    }
}

/// Professional-supplied text; the interpreter never supplies document content.
struct AssistantDocumentDraft: Equatable, Sendable {
    let title: String
    let text: String

    var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func composerBody() throws -> String {
        guard isComplete else { throw ConsultationFieldsError.emptyDocument }
        guard title.count <= 200, text.count <= 20_000 else { throw ConsultationFieldsError.tooLarge }
        return try LinearConsultationPage(body: "").replacing(.custom, text: text, title: title)
    }
}

struct AssistantPatientMatches: Sendable {
    let patients: [PatientSummary]
    let approximate: Bool
    var unambiguousPatient: PatientSummary? { patients.count == 1 && !approximate ? patients.first : nil }

    static func resolve(_ query: String, in patients: [PatientSummary]) -> Self {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self(patients: [], approximate: false)
        }
        let active = patients.filter { !$0.isArchived && $0.record != nil }
        let exact = active.filter { PatientSearch.matches($0, query: query) }
        if !exact.isEmpty { return Self(patients: exact, approximate: false) }
        // A spelling suggestion always requires a choice, even when unique.
        let term = PatientSearch.normalize(query)
        guard term.count >= 5 else { return Self(patients: [], approximate: false) }
        let suggested = active.filter { patient in
            [patient.record?.fullName, patient.record?.preferredName].compactMap { $0 }.contains {
                differsByOneEdit(term, PatientSearch.normalize($0))
            }
        }
        return Self(patients: suggested, approximate: !suggested.isEmpty)
    }

    static func contextual(patientID: String?, in patients: [PatientSummary]) throws -> Self {
        guard let patientID else { throw AssistantIssue.missingPatient }
        guard let patient = patients.first(where: { $0.patientID == patientID && !$0.isArchived && $0.record != nil }) else {
            throw AssistantIssue.changed
        }
        return Self(patients: [patient], approximate: false)
    }

    private static func differsByOneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }
}

struct AssistantPatientFilter: Equatable {
    let query: String
    let patientIDs: Set<String>
    let approximate: Bool
    let expandedPatientID: String?
    let opensHistory: Bool

    init(query: String, matches: AssistantPatientMatches, opensHistory: Bool = false) {
        self.query = query
        self.opensHistory = opensHistory
        patientIDs = Set(matches.patients.map(\.patientID))
        approximate = matches.approximate
        expandedPatientID = matches.unambiguousPatient?.patientID
    }

    func includes(_ patient: PatientSummary) -> Bool {
        !patient.isArchived && patientIDs.contains(patient.patientID)
    }
}

enum AssistantIssue: LocalizedError {
    case unavailable, changed, formOpen, saveFailed, missingPatient
    var errorDescription: String? {
        switch self {
        case .missingPatient: "Qual paciente? Informe o nome ou abra seu cartão antes de fazer o pedido."
        case .unavailable: "Ative IA de texto e a interpretação de pedidos do Assistente em Configurações."
        case .changed: "O contexto mudou. Faça o pedido novamente."
        case .formOpen: "Conclua ou cancele a tela aberta antes de navegar. Depois, abra o Assistente novamente."
        case .saveFailed: "O rascunho ainda não foi salvo. Confira o aviso na consulta antes de navegar."
        }
    }
}

/// A single ephemeral interaction. Closures keep navigation and local data in the owning window.
@MainActor @Observable
final class AssistantSession {
    var prompt = "" {
        didSet { if prompt != oldValue { cancel(); message = nil; answer = nil; localReading = nil; source = nil; candidates = []; pendingQuestion = nil; clearPreparation() } }
    }
    private(set) var answer: PatientAIAnswer?
    private(set) var answerPatientName: String?
    private(set) var localReading: PatientWikiReadingSnapshot?
    private(set) var isReadingWiki = false
    var source: PatientHistoryEntry?
    private(set) var candidates: [PatientSummary] = []
    private var pendingQuestion: String?
    private var answerRequest: Answer?
    private(set) var documentPatient: PatientSummary?
    var documentTitle = "" { didSet { if documentTitle != oldValue { cancel() } } }
    var documentText = "" { didSet { if documentText != oldValue { cancel() } } }
    private var pendingDocument = false
    private var preparationRequest: Prepare?
    var canOpenDocumentComposer: Bool {
        documentPatient != nil && AssistantDocumentDraft(title: documentTitle, text: documentText).isComplete
    }
    private(set) var isBusy = false
    private(set) var message: String?
    private var requestID = UUID()
    private var task: Task<Void, Never>?

    typealias Answer = @MainActor (String, PatientSummary) async throws -> PatientAIAnswer
    typealias Interpret = @MainActor (String) async throws -> AssistantIntent
    typealias Resolve = @MainActor (String) async throws -> AssistantPatientMatches
    typealias Navigate = @MainActor (AssistantIntent, AssistantPatientMatches) async throws -> Void
    typealias Prepare = @MainActor (AssistantDocumentDraft, PatientSummary) async throws -> Void
    typealias ReadWiki = @MainActor () async throws -> PatientWikiReadingSnapshot

    static func interpretConfigured(_ input: String) async throws -> AssistantIntent {
        guard UserDefaults.standard.bool(forKey: AITextSettings.assistantEnabledKey) else {
            throw AssistantIssue.unavailable
        }
        let response = try await AITextSettings.configuredRequest(input: input,
            instructions: AIPromptCatalog.assistantIntent.instructions, responseFormat: .assistantIntent)
        guard UserDefaults.standard.bool(forKey: AITextSettings.assistantEnabledKey) else {
            throw AITextSettingsIssue.changed
        }
        return try AssistantIntent.decode(response.text)
    }

    func submit(interpret: @escaping Interpret, resolve: @escaping Resolve, navigate: @escaping Navigate, answer: Answer? = nil, prepare: Prepare? = nil) {
        guard !isBusy else { return }
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard prompt.count <= 4_000 else {
            message = "Use um pedido de até 4.000 caracteres. Nenhum texto foi enviado."
            return
        }
        cancel()
        message = nil
        self.answer = nil; localReading = nil; source = nil; candidates = []; pendingQuestion = nil; answerRequest = answer
        clearPreparation(); preparationRequest = prepare
        isBusy = true
        let id = requestID
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.isBusy = false; self.task = nil } }
            do {
                let intent = try await interpret(input)
                guard self.isCurrent(id) else { return }
                guard intent != .unsupported else {
                    self.message = "Por enquanto, posso buscar pacientes, abrir seu histórico, responder perguntas e preparar documentos personalizados para revisão. Experimente: ‘Prepare um documento personalizado para Ana Fictícia’."
                    return
                }
                let matches = try await resolve(intent.query)
                guard self.isCurrent(id) else { return }
                if matches.patients.isEmpty {
                    self.message = "Nenhum paciente encontrado entre os cadastros ativos."
                } else if case .prepareDocument = intent {
                    guard prepare != nil else { throw AssistantIssue.unavailable }
                    if let patient = matches.unambiguousPatient {
                        self.documentPatient = patient
                        self.message = "Informe a finalidade ou título e o texto do documento. O compositor será aberto para revisão."
                    } else {
                        self.candidates = matches.patients; self.pendingDocument = true
                        self.message = "Escolha o paciente para preparar o documento."
                    }
                } else if case .askPatient = intent {
                    guard let answer else { throw AssistantIssue.unavailable }
                    if let patient = matches.unambiguousPatient {
                        let result = try await answer(input, patient)
                        guard self.isCurrent(id) else { return }
                        self.answerPatientName = patient.displayName; self.answer = result
                    } else {
                        self.candidates = matches.patients
                        self.pendingQuestion = input
                        self.message = "Escolha o paciente para responder à pergunta."
                    }
                } else {
                    try await navigate(intent, matches)
                }
            } catch is CancellationError {
                // Cancellation is silent and never publishes a late result.
            } catch {
                if self.isCurrent(id) { self.message = error.localizedDescription }
            }
        }
    }

    func choose(_ patient: PatientSummary) {
        guard !isBusy, let selected = candidates.first(where: { $0.patientID == patient.patientID }) else { return }
        if pendingDocument {
            documentPatient = selected; candidates = []; pendingDocument = false
            message = "Informe a finalidade ou título e o texto do documento. O compositor será aberto para revisão."
            return
        }
        guard let question = pendingQuestion, let answerRequest else { return }
        cancel(); isBusy = true; message = nil
        let id = requestID
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.isBusy = false; self.task = nil } }
            do {
                let result = try await answerRequest(question, patient)
                guard self.isCurrent(id) else { return }
                self.answerPatientName = patient.displayName; self.answer = result; self.candidates = []; self.pendingQuestion = nil
            } catch {
                if self.isCurrent(id) { self.message = error.localizedDescription }
            }
        }
    }

    func openDocumentComposer() {
        guard !isBusy, let patient = documentPatient, let preparationRequest else { return }
        let draft = AssistantDocumentDraft(title: documentTitle, text: documentText)
        do { _ = try draft.composerBody() } catch { message = error.localizedDescription; return }
        cancel(); isBusy = true; message = nil
        let id = requestID
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.isBusy = false; self.task = nil } }
            do {
                try await preparationRequest(draft, patient)
                guard self.isCurrent(id) else { return }
                self.clearPreparation()
            } catch is CancellationError {
            } catch { if self.isCurrent(id) { self.message = error.localizedDescription } }
        }
    }

    private func clearPreparation() {
        documentPatient = nil; documentTitle = ""; documentText = ""; pendingDocument = false; preparationRequest = nil
    }

    /// The local reading action never invokes the interpreter or a text provider.
    func readWiki(using read: @escaping ReadWiki) {
        guard !isBusy else { return }
        cancel(); clearPreparation()
        answer = nil; source = nil; localReading = nil; candidates = []; pendingQuestion = nil
        message = nil; isBusy = true; isReadingWiki = true
        let id = requestID
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.isBusy = false; self.isReadingWiki = false; self.task = nil } }
            do {
                let snapshot = try await read()
                guard self.isCurrent(id) else { return }
                self.localReading = snapshot
            } catch is CancellationError {
            } catch { if self.isCurrent(id) { self.message = error.localizedDescription } }
        }
    }

    func invalidateLocalReading() {
        guard localReading != nil || isReadingWiki else { return }
        if isReadingWiki { cancel() }
        localReading = nil; source = nil
        message = "Consulte novamente a wiki e o IPS para conferir as fontes atuais."
    }

    func showMessage(_ text: String?) { message = text }

    func cancel() {
        requestID = UUID(); task?.cancel(); task = nil; isBusy = false; isReadingWiki = false
    }

    func reset() {
        cancel(); prompt = ""; message = nil; answer = nil; localReading = nil; source = nil; candidates = []; pendingQuestion = nil; answerRequest = nil
        clearPreparation()
    }

    private func isCurrent(_ id: UUID) -> Bool { requestID == id && !Task.isCancelled }
}
