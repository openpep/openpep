// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import OSLog
import SwiftUI

struct PatientWikiView: View {
    typealias TextRequester = @MainActor @Sendable (
        _ input: String,
        _ instructions: String,
        _ responseFormat: OpenAITextResponseFormat?
    ) async throws -> OpenAITextResult

    let patient: PatientSummary
    let context: PatientHistoryContext
    let canWrite: Bool
    var automaticallyUpdates = true
    var textRequester: TextRequester? = nil
    @AppStorage(AITextSettings.enabledKey) private var allowsText = false
    @AppStorage(AITextSettings.autoWikiKey) private var autoWiki = false
    @State private var saved: PatientWikiSnapshot?
    @State private var sources: PatientWikiContext?
    @State private var corrections = ""
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var loading = false
    @State private var refreshID = UUID()
    @State private var invalidated = false
    @State private var verifiedFingerprint: String?
    @State private var sourcePreview: PatientHistoryEntry?
    @State private var correctionConfirmation: CorrectionConfirmation?
    @State private var showingCorrectionConfirmation = false
    @State private var showingCoverage = false
    @State private var editingIPS = false

    private struct CorrectionConfirmation {
        let summaryData: Data
        let corrections: PatientWikiCorrections
    }

    private static let wikiLogger = Logger(subsystem: "org.openpep.OpenPEP", category: "PatientWiki")

    init(
        patient: PatientSummary,
        context: PatientHistoryContext,
        canWrite: Bool,
        automaticallyUpdates: Bool = true,
        textRequester: TextRequester? = nil
    ) {
        self.patient = patient
        self.context = context
        self.canWrite = canWrite
        self.automaticallyUpdates = automaticallyUpdates
        self.textRequester = textRequester
    }

    private var dirtyCorrections: Bool { corrections != (saved?.corrections?.markdown ?? "") }
    private var stale: Bool { saved?.summary?.sourceFingerprint != sources?.fingerprint }
    private var needsGeneration: Bool {
        Self.needsGeneration(
            summarySourceFingerprint: saved?.summary?.sourceFingerprint,
            summaryPromptVersion: saved?.summary?.promptVersion,
            sourceFingerprint: sources?.fingerprint,
            currentPromptVersion: PatientWikiGeneration.prompt.id
        )
    }

    var body: some View {
        GroupBox("Resumo Internacional do Paciente") {
            VStack(alignment: .leading, spacing: 12) {
                generationControls
                if let issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = saved?.summaryIssue { Text(error).foregroundStyle(.secondary) }
                if let error = saved?.correctionsIssue { Text(error).foregroundStyle(.secondary) }
                if let summary = saved?.summary {
                    Label("Última atualização · \(Self.displayDate(summary.generatedAt)) · IA", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                    if invalidated || sources == nil {
                        Text("Atualização pendente: o resumo anterior ainda não foi conferido com as fontes.").font(.callout)
                    } else if stale {
                        Text(newSourceCount > 0
                            ? "Resumo desatualizado · \(newSourceCount) novas fontes. Atualize para conferir as fontes atuais."
                            : "Resumo desatualizado · fontes ou correções alteradas. Atualize o resumo.").font(.callout)
                    } else if needsGeneration {
                        Text("O resumo aguarda atualização para as instruções atuais.").font(.callout)
                    }

                } else {
                    Text("Problemas, medicamentos, procedimentos, alergias, exames, imunizações e estilo de vida aparecerão aqui para sua revisão.")
                        .foregroundStyle(.secondary)
                }
                if let summary = saved?.summary, let sources {
                    PatientWikiReviewView(summary: summary, sourceContext: sources,
                        historyContext: context, canWrite: canWrite && !invalidated && sources.writingAllowed
                            && !sources.patient.isArchived && task == nil && !dirtyCorrections,
                        onEditingChange: { editingIPS = $0 })
                }
                if let summary = saved?.summary {
                    DisclosureGroup("Narrativa e fontes") {
                        PatientWikiSummaryView(summary: summary, sourceEntries: sourceEntries(for: summary),
                            onOpenSource: { sourcePreview = $0 })
                    }
                }
                if saved?.summary?.exclusions != nil {
                    Button(showingCoverage ? "Ocultar cobertura das fontes" : "Conferir cobertura das fontes",
                           systemImage: showingCoverage ? "chevron.up" : "doc.text.magnifyingglass") { showingCoverage.toggle() }
                        .accessibilityValue(showingCoverage ? "Expandido" : "Recolhido")
                    if showingCoverage {
                        if let exclusions = saved?.summary?.exclusions {
                            Text(exclusions.description).font(.caption).foregroundStyle(.secondary)
                        }
                        if stale, let sources {
                            Text("Fontes atuais. " + sources.exclusions.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Correções e orientações do médico") {
                    Text("As correções ficam preservadas até você confirmar quais foram incorporadas. Notas finais permanecem intactas.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $corrections).frame(minHeight: 100)
                        .accessibilityLabel("Correções do resumo")
                        .disabled(!canWrite || task != nil || loading || saved?.correctionsIssue != nil)
                    HStack {
                        Button("Salvar correções", action: saveCorrections)
                            .disabled(!canWrite || !dirtyCorrections || task != nil || loading || saved?.correctionsIssue != nil)
                        if currentCorrectionConfirmation != nil {
                            Button("Conferir correções incorporadas…") { showingCorrectionConfirmation = true }
                                .disabled(!canWrite || dirtyCorrections || task != nil || loading || invalidated)
                        }
                    }
                }
            }.padding(10)
        }
        .task(id: patient.url.path + refreshID.uuidString) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await load()
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: PatientClinicalChange.notification).receive(on: RunLoop.main)) { change in
            guard PatientClinicalChange.matches(change, patientURL: patient.url),
                  !PatientClinicalChange.isReview(change) else { return }
            invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Recheck external changes without disabling an unchanged editor.
            refreshID = UUID()
        }
        .onChange(of: task == nil) { _, idle in
            if idle && invalidated { refreshID = UUID() }
        }
        .onChange(of: dirtyCorrections) { _, dirty in
            if !dirty && invalidated { refreshID = UUID() }
        }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $showingCorrectionConfirmation) {
            if let confirmation = correctionConfirmation {
                PatientWikiCorrectionConfirmationView(markdown: confirmation.corrections.markdown,
                    onCancel: { showingCorrectionConfirmation = false },
                    onConfirm: { removeConfirmedCorrections($0, confirmation: confirmation) })
            }
        }
        .sheet(item: $sourcePreview) { entry in
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.title + " · " + entry.displayDate).font(.headline)
                ScrollView { ClinicalFormattedText(text: entry.text) }
                Button("Fechar") { sourcePreview = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(minWidth: 600, minHeight: 450)
        }
    }

    private var currentCorrectionConfirmation: CorrectionConfirmation? {
        guard let confirmation = correctionConfirmation,
              confirmation.summaryData == saved?.summary?.persistedData,
              confirmation.corrections.persistedData == saved?.corrections?.persistedData,
              !invalidated, !loading, let sources, sources.writingAllowed, !sources.patient.isArchived,
              sources.fingerprint == saved?.summary?.sourceFingerprint else { return nil }
        return confirmation
    }

    private var newSourceCount: Int {
        let previous = Set(saved?.summary?.sources.map { $0.id + "|" + $0.path } ?? [])
        return sources?.entries.filter { !previous.contains($0.id + "|" + $0.source) }.count ?? 0
    }

    static func displayDate(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return date.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "pt_BR")))
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(saved?.summary == nil ? "Gerar IPS" : "Atualizar IPS", systemImage: "arrow.clockwise", action: generate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canWrite || invalidated || sources?.writingAllowed != true || sources?.patient.isArchived != false || !allowsText || dirtyCorrections || task != nil || loading || sources?.entries.isEmpty != false || saved?.summaryIssue != nil || saved?.correctionsIssue != nil)
                if task != nil { ProgressView("Gerando IPS…").controlSize(.small) }
                else if loading { ProgressView("Conferindo fontes locais…").controlSize(.small) }
                if task != nil { Button("Cancelar") { task?.cancel() } }
                if invalidated && !dirtyCorrections && !loading && task == nil { Button("Verificar fontes", action: retryLoad) }
            }
            if !allowsText { Text("Ative a IA de texto em Configurações para gerar.").font(.caption).foregroundStyle(.secondary) }
            else if !autoWiki && (invalidated || needsGeneration) {
                Text("Atualização automática desativada. Atualize pelo botão acima.").font(.caption).foregroundStyle(.secondary)
            }
            if dirtyCorrections { Text("Salve as correções antes de atualizar.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func removeConfirmedCorrections(_ lineIndices: Set<Int>, confirmation: CorrectionConfirmation) {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            let vault = try VaultReader().open(context.vaultURL)
            guard canWrite, !dirtyCorrections, task == nil, vault.writingAllowed,
                  let currentPatient = vault.patients.first(where: { $0.patientID == patient.patientID }),
                  !currentPatient.isArchived,
                  currentCorrectionConfirmation != nil,
                  let generatedFingerprint = saved?.summary?.sourceFingerprint else { throw PatientAIIssue.changed }
            _ = try PatientWikiStore().removeConfirmedCorrectionLines(for: currentPatient,
                lineIndices: lineIndices, generatedSummaryData: confirmation.summaryData,
                usedCorrectionsData: confirmation.corrections.persistedData,
                validateSources: {
                    let latest = try PatientWikiContext.load(context: context, corrections: confirmation.corrections.markdown)
                    guard latest.writingAllowed, !latest.patient.isArchived,
                          latest.fingerprint == generatedFingerprint else { throw PatientAIIssue.changed }
                })
            saved = try PatientWikiStore().load(for: patient)
            corrections = saved?.corrections?.markdown ?? ""
            correctionConfirmation = nil
            showingCorrectionConfirmation = false
            issue = "Correções confirmadas removidas. As demais foram preservadas."
            invalidate()
        } catch {
            showingCorrectionConfirmation = false
            issue = "As correções não foram removidas. " + error.localizedDescription
        }
    }

    private func invalidate() {
        invalidated = true
        refreshID = UUID()
    }

    private func retryLoad() {
        issue = nil
        refreshID = UUID()
    }

    static func needsGeneration(
        summarySourceFingerprint: String?,
        summaryPromptVersion: String?,
        sourceFingerprint: String?,
        currentPromptVersion: String
    ) -> Bool {
        guard summarySourceFingerprint != nil else { return sourceFingerprint != nil }
        return summarySourceFingerprint != sourceFingerprint || summaryPromptVersion != currentPromptVersion
    }

    private func sourceEntries(for summary: PatientWikiSummary) -> [String: PatientHistoryEntry] {
        guard let sources else { return [:] }
        return Dictionary(uniqueKeysWithValues: summary.sources.enumerated().compactMap { index, source in
            guard let entry = sources.entries.first(where: { $0.id == source.id && $0.source == source.path
                && PatientAIContext.digest(Data($0.text.utf8)) == source.sha256 }) else {
                return nil
            }
            return ("F\(index + 1)", entry)
        })
    }

    @MainActor
    private func load() async {
        guard !dirtyCorrections, task == nil else { return }
        let previousFingerprint = verifiedFingerprint
        let updatesAfterChange = invalidated
        loading = sources == nil || invalidated
        defer { loading = false }
        do {
            let patient = patient, context = context
            let (result, current) = try await Task.detached {
                let granted = context.authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
                let saved = try PatientWikiStore().load(for: patient)
                let sources = try PatientWikiContext.load(context: context, corrections: saved.corrections?.markdown ?? "")
                return (saved, sources)
            }.value
            try Task.checkCancellation()
            if saved?.summary?.persistedData != result.summary?.persistedData
                || saved?.corrections?.persistedData != result.corrections?.persistedData
                || saved?.summaryIssue != result.summaryIssue || saved?.correctionsIssue != result.correctionsIssue {
                saved = result
            }
            corrections = result.corrections?.markdown ?? ""
            if sources?.fingerprint != current.fingerprint || sources?.writingAllowed != current.writingAllowed
                || sources?.patient.isArchived != current.patient.isArchived { sources = current }
            verifiedFingerprint = current.fingerprint
            invalidated = false
            if (automaticallyUpdates || (updatesAfterChange && previousFingerprint != nil && previousFingerprint != current.fingerprint)) && allowsText && autoWiki && canWrite && !editingIPS
                && current.writingAllowed && !current.patient.isArchived && needsGeneration
                && result.summaryIssue == nil && result.correctionsIssue == nil && !current.entries.isEmpty {
                generate()
            }
        } catch is CancellationError { }
        catch {
            invalidated = true
            issue = "Não foi possível conferir as fontes. " + error.localizedDescription
        }
    }

    private func saveCorrections() {
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            guard try VaultReader().open(context.vaultURL).writingAllowed else { throw PatientAIIssue.changed }
            _ = try PatientWikiStore().saveCorrections(for: patient, markdown: corrections,
                expectedData: saved?.corrections?.persistedData)
            saved = try PatientWikiStore().load(for: patient)
            corrections = saved?.corrections?.markdown ?? ""
            correctionConfirmation = nil
            issue = "Correções salvas. Atualize o resumo para incorporá-las."
            invalidate()
        } catch { issue = error.localizedDescription }
    }

    private func generate() {
        guard task == nil, canWrite, allowsText, !dirtyCorrections,
              sources?.writingAllowed == true, sources?.patient.isArchived == false else { return }
        let expectedSummary = saved?.summary?.persistedData
        let expectedCorrections = saved?.corrections?.persistedData
        let correctionText = corrections
        let attemptID = UUID().uuidString.lowercased()
        let attemptStarted = DispatchTime.now().uptimeNanoseconds
        issue = nil
        correctionConfirmation = nil
        task = Task { @MainActor in
            var generationDiagnostic: PatientWikiGenerationDiagnostic?
            var factDiagnostic: PatientWikiFactBindingDiagnostic?
            var attemptSourceCount = 0
            var attemptInputBytes = 0
            var attemptResponseBytes = 0
            var omittedFactCount = 0
            defer { task = nil }
            do {
                let context = context
                let captured = try await Task.detached {
                    try PatientWikiContext.load(context: context, corrections: correctionText)
                }.value
                guard !captured.entries.isEmpty else { throw PatientAIIssue.noSources }
                attemptSourceCount = captured.entries.count
                attemptInputBytes = captured.input.utf8.count
                Self.logAttempt(attemptID, phase: "start", started: attemptStarted,
                    sourceCount: attemptSourceCount, inputBytes: attemptInputBytes)
                try Task.checkCancellation()
                let result = try await requestText(input: captured.input,
                    instructions: PatientWikiGeneration.instructions, responseFormat: .patientWiki)
                attemptResponseBytes = result.text.utf8.count
                Self.logAttempt(attemptID, phase: "providerReceived", started: attemptStarted,
                    sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                    responseBytes: attemptResponseBytes)
                let generation: PatientWikiGeneration
                do {
                    generation = try PatientWikiGeneration.decode(result.text,
                        sourceCount: captured.entries.count,
                        diagnostic: { generationDiagnostic = $0 })
                    Self.logAttempt(attemptID, phase: "decode", started: attemptStarted,
                        sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                        responseBytes: attemptResponseBytes)
                } catch {
                    Self.logAttempt(attemptID, phase: "decode", started: attemptStarted,
                        sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                        responseBytes: attemptResponseBytes,
                        diagnostic: generationDiagnostic.map { "wiki.\($0.code.rawValue)" }
                            ?? Self.safeErrorCode(error))
                    throw error
                }
                let current = try await Task.detached {
                    try PatientWikiContext.load(context: context, corrections: correctionText)
                }.value
                try Task.checkCancellation()
                guard current.writingAllowed, current.fingerprint == captured.fingerprint else { throw PatientAIIssue.changed }
                let granted = context.authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
                let proposals: [PatientWikiFact]
                do {
                    let binding = try PatientWikiFact.bindPartially(generation.facts, to: captured,
                        diagnostic: { factDiagnostic = $0 })
                    proposals = binding.facts
                    omittedFactCount = binding.omittedCount
                    Self.logAttempt(attemptID, phase: "bind", started: attemptStarted,
                        sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                        responseBytes: attemptResponseBytes,
                        diagnostic: omittedFactCount == 0
                            ? "none"
                            : "facts_omitted.\(factDiagnostic?.code.rawValue ?? "unknown")")
                    // An omitted fact is a successful partial result. A later
                    // global publication error must use its own reason.
                    factDiagnostic = nil
                } catch {
                    Self.logAttempt(attemptID, phase: "bind", started: attemptStarted,
                        sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                        responseBytes: attemptResponseBytes,
                        diagnostic: factDiagnostic.map { "fact.\($0.code.rawValue)" }
                            ?? Self.safeErrorCode(error))
                    throw error
                }
                let published = try PatientWikiStore().saveSummary(for: current.patient,
                    input: PatientWikiSummaryInput(markdown: generation.markdown, sourceFingerprint: captured.fingerprint,
                        model: result.model, generatedAt: ISO8601DateFormatter().string(from: Date()),
                        sources: captured.entries.map { PatientWikiSource(id: $0.id, path: $0.source,
                            sha256: PatientAIContext.digest(Data($0.text.utf8))) },
                        overview: generation.overviewText, exclusions: captured.exclusions,
                        proposals: proposals,
                        promptVersion: PatientWikiGeneration.prompt.id,
                        omittedFactCount: omittedFactCount),
                    expectedData: expectedSummary, expectedCorrectionsData: expectedCorrections,
                    validateSources: {
                        let latest = try PatientWikiContext.load(context: context, corrections: correctionText)
                        guard latest.writingAllowed, latest.fingerprint == captured.fingerprint else { throw PatientAIIssue.changed }
                        try Task.checkCancellation()
                    })
                saved = try PatientWikiStore().load(for: current.patient)
                sources = current
                if let usedData = expectedCorrections, !correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    correctionConfirmation = CorrectionConfirmation(summaryData: published.persistedData,
                        corrections: PatientWikiCorrections(markdown: correctionText, persistedData: usedData))
                }
                Self.logAttempt(attemptID, phase: "published", started: attemptStarted,
                    sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                    responseBytes: attemptResponseBytes)
                if proposals.isEmpty && omittedFactCount > 0 {
                    issue = "A IA respondeu, mas nenhum item passou pela validação das fontes. Dados não incluídos no IPS: \(omittedFactCount). A narrativa foi salva; o IPS ainda precisa de revisão."
                } else if proposals.isEmpty {
                    issue = "A narrativa foi atualizada, mas a IA não retornou itens para os cards do IPS. Confira as fontes antes de concluir a revisão."
                } else {
                    issue = omittedFactCount > 0
                        ? "IPS atualizado. Dados não incluídos no IPS: \(omittedFactCount). Confira as fontes."
                        : "IPS atualizado."
                }
            } catch is CancellationError {
                Self.logAttempt(attemptID, phase: "cancel", started: attemptStarted,
                    sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                    responseBytes: attemptResponseBytes, diagnostic: "cancelled")
                issue = "Geração cancelada. O resumo anterior foi mantido."
            }
            catch {
                Self.logAttempt(attemptID, phase: "failed", started: attemptStarted,
                    sourceCount: attemptSourceCount, inputBytes: attemptInputBytes,
                    responseBytes: attemptResponseBytes,
                    diagnostic: generationDiagnostic.map { "wiki.\($0.code.rawValue)" }
                        ?? factDiagnostic.map { "fact.\($0.code.rawValue)" }
                        ?? Self.safeErrorCode(error))
                issue = generationDiagnostic?.message ?? factDiagnostic?.message ?? error.localizedDescription
            }
        }
    }

    private static func logAttempt(_ attemptID: String, phase: String, started: UInt64,
                                   sourceCount: Int = 0, inputBytes: Int = 0,
                                   responseBytes: Int = 0, diagnostic: String = "none") {
        let fields = "attempt=\(attemptID) phase=\(phase) elapsedMs=\(elapsedMilliseconds(since: started)) "
            + "sourceCount=\(sourceCount) inputBytes=\(inputBytes) responseBytes=\(responseBytes) "
            + "diagnostic=\(diagnostic)"
        if phase == "failed" {
            wikiLogger.error("\(fields, privacy: .public)")
        } else {
            wikiLogger.notice("\(fields, privacy: .public)")
        }
    }

    private static func elapsedMilliseconds(since started: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private static func safeErrorCode(_ error: Error) -> String {
        switch error {
        case let issue as OpenAITextIssue:
            switch issue {
            case .emptyInput: "empty_input"
            case .inputTooLong: "input_too_long"
            case .invalidInstructions: "invalid_instructions"
            case .invalidModel: "invalid_model"
            case .invalidAPIKey: "invalid_api_key"
            case .credentialsRejected: "credentials_rejected"
            case .usageLimitReached: "usage_limit"
            case .requestRejected: "request_rejected"
            case .networkUnavailable: "network_unavailable"
            case .responseTooLarge: "response_too_large"
            case .invalidResponse: "invalid_response"
            case .incompleteResponse: "incomplete_response"
            case .refusedResponse: "refused_response"
            case .emptyResponse: "empty_response"
            }
        case let issue as AITextSettingsIssue:
            switch issue {
            case .disabled: "text_disabled"
            case .summaryDisabled: "summary_disabled"
            case .transcriptionDisabled: "transcription_disabled"
            case .missingKey: "missing_key"
            case .changed: "settings_changed"
            }
        case let issue as PatientAIIssue:
            switch issue {
            case .patientUnavailable: "patient_unavailable"
            case .tooLong: "input_too_long"
            case .changed: "context_changed"
            case .noSources: "no_sources"
            }
        case let issue as PatientWikiGenerationIssue:
            switch issue {
            case .overviewTooLong: "overview_too_long"
            }
        case is IntegrationCredentialIssue: "credential_store"
        case is CancellationError: "cancelled"
        case let issue as VaultValidationIssue:
            switch issue.rule {
            case "wiki.revision_conflict": "revision_conflict"
            case "wiki.rollback_failed": "rollback_failed"
            default: "vault_validation"
            }
        default: "unknown_error"
        }
    }

    @MainActor
    private func requestText(
        input: String,
        instructions: String,
        responseFormat: OpenAITextResponseFormat?
    ) async throws -> OpenAITextResult {
        if let textRequester {
            return try await textRequester(input, instructions, responseFormat)
        }
        return try await AITextSettings.configuredRequest(
            input: input, instructions: instructions, responseFormat: responseFormat)
    }
}
