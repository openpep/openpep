// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A single, persistent representation of the consultation currently being captured.
///
/// The strip intentionally receives the session rather than duplicating its state. It can
/// therefore remain visible while the physician navigates to another record without making
/// that record look like the source of the capture.
struct ConsultationLiveStatusStrip: View {
    @ObservedObject var session: EncounterTranscriptionSession
    let onReturn: () -> Void
    let onShowSummary: () -> Void

    var body: some View {
        if let binding = session.binding {
            ViewThatFits(in: .horizontal) {
                wideContent(binding: binding)
                compactContent(binding: binding)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityElement(children: .contain)
        }
    }

    private func wideContent(binding: EncounterTranscriptionBinding) -> some View {
        HStack(alignment: .center, spacing: 16) {
            consultationIdentity(binding)
            Divider().frame(height: 38)
            duration
            captureState
            audioLevels
            Spacer(minLength: 8)
            summaryState
            stripActions
        }
    }

    private func compactContent(binding: EncounterTranscriptionBinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                consultationIdentity(binding)
                Spacer(minLength: 8)
                duration
                if session.isRecording {
                    stopButton
                }
            }
            HStack(spacing: 12) {
                captureState
                audioLevels
                Spacer(minLength: 8)
                Button("Resumo", action: onShowSummary)
                if !session.isRecording && session.canReset {
                    Button { _ = session.reset() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar acompanhamento da consulta")
                }
            }
            summaryState
        }
    }

    private func consultationIdentity(_ binding: EncounterTranscriptionBinding) -> some View {
        Button(action: onReturn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Consulta de \(binding.patientName)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Voltar à consulta de origem")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voltar à consulta de \(binding.patientName)")
        .accessibilityHint("Retoma o rascunho que recebe esta transcrição e seus resumos")
    }

    private var duration: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = capturedSeconds(at: context.date)
            Text(Self.durationLabel(seconds))
                .font(.body.monospacedDigit())
                .accessibilityLabel("Duração capturada: \(Self.accessibleDuration(seconds))")
        }
    }

    private var captureState: some View {
        Label(captureStatus, systemImage: captureSymbol)
            .font(.callout)
            .lineLimit(2)
            .accessibilityLabel("Captura: \(captureStatus)")
    }

    private var audioLevels: some View {
        HStack(spacing: 10) {
            ConsultationAudioLevel(label: "Microfone", level: session.microphoneLevel)
            if session.progressiveWork?.capture.source == .telecall || session.callLevel > 0 {
                ConsultationAudioLevel(label: "Chamada", level: session.callLevel)
            }
        }
    }

    private var summaryState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(summaryStatus, systemImage: summarySymbol)
                .font(.caption)
                .lineLimit(1)
            if !session.progressiveSaveStatus.isEmpty {
                Label(session.progressiveSaveStatus, systemImage: saveStatusSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resumo: \(summaryStatus). \(session.progressiveSaveStatus)")
    }

    @ViewBuilder
    private var stripActions: some View {
        Button("Ver resumo", action: onShowSummary)
        if session.isRecording {
            stopButton
        } else if session.canReset {
            Button { _ = session.reset() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Fechar acompanhamento da consulta")
                .help("Fechar acompanhamento")
        }
    }

    private var stopButton: some View {
        Button("Parar gravação", systemImage: "stop.fill") { session.stop() }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityHint("Encerra a captura e mantém o rascunho para completar o trecho final")
    }

    private var captureStatus: String {
        if session.isPaused { return "Gravação pausada · áudio não está sendo captado" }
        if session.isRecording {
            if session.summaryIsUpdating { return "Gravando · resumo em atualização" }
            if session.partialTranscript.isEmpty && session.stableTranscript.isEmpty { return "Gravando · aguardando fala" }
            return "Gravando · transcrição em andamento"
        }
        if session.isBusy { return session.status }
        return session.status
    }

    private var captureSymbol: String {
        if session.isPaused { return "pause.circle" }
        if session.isRecording { return "record.circle" }
        if session.isBusy { return "arrow.triangle.2.circlepath" }
        return "waveform"
    }

    private var summaryStatus: String {
        if let work = session.progressiveWork, !work.pendingRanges.isEmpty {
            return "Transcrição interrompida · o resumo cobre somente o texto estabilizado"
        }
        if let error = session.progressiveWork?.lastError, !error.isEmpty {
            return "Resumo precisa de revisão: \(error)"
        }
        if session.summaryIsUpdating { return "Resumo em atualização" }
        if !session.progressiveSummaryText.isEmpty {
            return "Resumo até \(Self.durationLabel(session.progressiveSummaryCoveredThrough))"
        }
        if session.isRecording, session.progressiveWork?.summaryEngine != "openai/responses" {
            return "Resumo Apple ao encerrar a gravação"
        }
        if !session.stableTranscript.isEmpty { return "Aguardando o próximo intervalo do resumo" }
        return "Aguardando texto estabilizado"
    }

    private var summarySymbol: String {
        if session.progressiveWork?.lastError?.isEmpty == false { return "exclamationmark.triangle" }
        return session.summaryIsUpdating ? "sparkles" : "doc.text"
    }

    private var saveStatusSymbol: String {
        session.progressiveSaveStatus.hasPrefix("Não foi possível")
            ? "exclamationmark.triangle" : "checkmark.circle"
    }

    private func capturedSeconds(at date: Date) -> Double {
        let stored = session.progressiveWork?.capture.capturedSeconds ?? 0
        return stored
    }

    fileprivate static func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func accessibleDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let remainder = total % 60
        return minutes == 0 ? "\(remainder) segundos" : "\(minutes) minutos e \(remainder) segundos"
    }
}

private struct ConsultationAudioLevel: View {
    let label: String
    let level: Double

    private var normalizedLevel: Double { min(1, max(0, level)) }
    private var percentage: Int { Int((normalizedLevel * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2)
            GeometryReader { geometry in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.primary)
                            .frame(width: geometry.size.width * normalizedLevel)
                    }
            }
            .frame(width: 54, height: 6)
            Text("\(percentage)%").font(.caption2.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nível de áudio do \(label): \(percentage) por cento")
        .accessibilityValue("\(percentage) por cento")
    }
}

struct ConsultationLivePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary
        case transcript

        var id: Self { self }
        var label: String { self == .summary ? "Resumo" : "Transcrição" }
    }

    @ObservedObject var session: EncounterTranscriptionSession
    let onAccept: (ConsultationSummaryBlock) -> Void
    let onUndo: (ConsultationSummaryBlock) -> Void
    let canUndo: (ConsultationSummaryBlock) -> Bool

    let onResume: (() -> Void)?
    @Binding var isCollapsed: Bool
    @State private var showsSummaryDetails = false
    @State private var selectedTab: Tab = .summary
    @State private var transcriptTargetID: String?
    @State private var editorText = ""
    @State private var editorSelection: TextSelection?
    @State private var displayedRevision = 0
    @State private var unseenUpdateCount = 0
    @State private var editorIsAtBottom = true
    @State private var showsHistory = false
    @FocusState private var summaryEditorFocused: Bool

    init(
        session: EncounterTranscriptionSession,
        onAccept: @escaping (ConsultationSummaryBlock) -> Void,
        onUndo: @escaping (ConsultationSummaryBlock) -> Void,
        canUndo: @escaping (ConsultationSummaryBlock) -> Bool = { _ in false },
        isCollapsed: Binding<Bool> = .constant(false),
        onResume: (() -> Void)? = nil
    ) {
        self.session = session
        self.onAccept = onAccept
        self.onUndo = onUndo
        self.canUndo = canUndo
        self._isCollapsed = isCollapsed
        self.onResume = onResume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveCaptureOverview
            if !isCollapsed {
                Divider()
                GeometryReader { geometry in
                    if geometry.size.width >= 720 {
                        HStack(alignment: .top, spacing: 20) {
                            transcriptColumn.frame(width: geometry.size.width * 0.38)
                            Divider()
                            ScrollView { summary }.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Picker("Conteúdo", selection: $selectedTab) {
                                ForEach(Tab.allCases) { tab in Text(tab.label).tag(tab) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .accessibilityLabel("Conteúdo da transcrição")
                            if selectedTab == .summary {
                                ScrollView { summary }
                            } else {
                                transcriptColumn
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: -3)
        .onChange(of: isCollapsed) { _, collapsed in
            if collapsed { summaryEditorFocused = false }
        }
        .onAppear { displayLatestSummary(followEnd: true) }
        .onChange(of: session.progressiveSummaryWasAccepted) { _, _ in
            summaryEditorFocused = false
            displayLatestSummary(followEnd: true)
        }
        .onChange(of: session.progressiveWork?.sessionID) { _, _ in
            summaryEditorFocused = false
            displayLatestSummary(followEnd: true)
        }
        .onChange(of: session.progressiveSummaryRevision) { oldRevision, newRevision in
            guard newRevision != oldRevision else { return }
            if editorText == session.progressiveSummaryText {
                displayedRevision = newRevision
                unseenUpdateCount = 0
                return
            }
            if summaryEditorFocused || !editorIsAtBottom {
                unseenUpdateCount += max(1, newRevision - displayedRevision)
            } else {
                displayLatestSummary(followEnd: true)
            }
        }
        .sheet(isPresented: $showsHistory) { summaryHistory }
    }

    private var liveCaptureOverview: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                captureIndicator
                Spacer(minLength: 8)
                captureActions
                collapseButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    captureIndicator
                    Spacer(minLength: 8)
                    collapseButton
                }
                HStack { captureActions }
            }
        }
    }

    private var captureIndicator: some View {
        HStack(spacing: 8) {
            Label(captureStatus, systemImage: captureOverviewSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(session.isRecording && !session.isPaused ? .red : .primary)
                .lineLimit(2).help(session.status)
            Text(ConsultationLiveStatusStrip.durationLabel(session.progressiveWork?.capture.capturedSeconds ?? 0))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Duração capturada")
                .accessibilityValue(ConsultationLiveStatusStrip.durationLabel(session.progressiveWork?.capture.capturedSeconds ?? 0))
        }
    }

    @ViewBuilder
    private var captureActions: some View {
        if session.isRecording {
            if session.canPauseLiveCapture || session.isPauseTransitioning {
                if session.isPauseTransitioning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Alterando pausa da gravação")
                }
                Button(
                    session.isPaused ? "Continuar" : "Pausar",
                    systemImage: session.isPaused ? "play.fill" : "pause.fill"
                ) {
                    session.togglePause()
                }
                .disabled(session.isPauseTransitioning)
            }
            Button("Encerrar gravação", systemImage: "stop.fill") { session.stop() }
                .accessibilityHint("Encerra a captura; não finaliza a consulta")
        } else if let onResume {
            Button(session.progressiveSummaryWasAccepted ? "Nova transcrição" : "Retomar transcrição",
                   systemImage: "mic.fill", action: onResume)
                .disabled(!session.canResumeCapture)
        }
    }

    private var collapseButton: some View {
        Button {
            withAnimation { isCollapsed.toggle() }
        } label: {
            Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expandir transcrição" : "Recolher transcrição")
        .help("Recolher mantém a gravação em andamento")
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcrição ao vivo").font(.headline)
            ConsultationTranscriptPanel(
                segments: session.progressiveWork?.segments ?? [],
                partialText: session.partialTranscript,
                targetID: $transcriptTargetID
            )
            if session.isRecording {
                HStack(spacing: 16) {
                    ConsultationAudioLevel(label: "Microfone", level: session.microphoneLevel)
                    if session.progressiveWork?.capture.source == .telecall || session.callLevel > 0 {
                        ConsultationAudioLevel(label: "Chamada", level: session.callLevel)
                    }
                    Text(session.isPaused ? "Pausado" : "Ouvindo…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !session.progressiveSaveStatus.isEmpty {
                Label(saveOverview, systemImage: saveOverviewSymbol)
                    .font(.caption)
                    .foregroundStyle(session.progressiveSaveStatus.hasPrefix("Não foi possível") ? .red : .secondary)
            }
        }
    }

    private var captureStatus: String {
        if session.isPaused { return "Gravação pausada" }
        if session.isRecording, session.progressiveWork?.pendingRanges.isEmpty == false {
            return "Gravando áudio · transcrição interrompida"
        }
        if session.isRecording { return "Gravando" }
        if session.isBusy { return "Finalizando transcrição" }
        if session.status.hasPrefix("Rascunho de acompanhamento recuperado") { return "Transcrição recuperada" }
        return session.status
    }

    private var captureOverviewSymbol: String {
        if session.isPaused { return "pause.circle.fill" }
        if session.isRecording, session.progressiveWork?.pendingRanges.isEmpty == false {
            return "exclamationmark.triangle.fill"
        }
        if session.isRecording { return "record.circle.fill" }
        if session.isBusy { return "hourglass" }
        return "waveform"
    }

    private var saveOverview: String {
        if session.progressiveWork?.capture.status == .failed,
           session.progressiveWork?.capture.capturedSeconds == 0,
           session.stableTranscript.isEmpty {
            return "A gravação não começou. Clique no microfone para tentar novamente."
        }
        if session.progressiveWork?.pendingRanges.isEmpty == false {
            return "Áudio e texto estabilizado salvos; há trecho pendente"
        }
        if session.progressiveSaveStatus.isEmpty { return "A transcrição e o resumo serão salvos neste Mac" }
        return session.progressiveSaveStatus == "Salvo neste Mac"
            ? "Transcrição e resumo salvos neste Mac"
            : session.progressiveSaveStatus
    }

    private var saveOverviewSymbol: String {
        session.progressiveSaveStatus.hasPrefix("Não foi possível")
            ? "exclamationmark.triangle" : "checkmark.circle"
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resumo").font(.headline)
                    Text(summarySubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.progressiveWork?.summaryEngine == "openai/responses" {
                    Button("Resumir agora", action: session.summarizeNow)
                        .disabled(
                            session.progressiveSummaryWasAccepted || session.summaryIsUpdating
                                || session.stableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if unseenUpdateCount > 0 {
                Button("Ver \(unseenUpdateCount == 1 ? "atualização" : "\(unseenUpdateCount) atualizações")") {
                    displayLatestSummary(followEnd: true)
                }
                .disabled(session.progressiveSummaryHasPendingEdit)
                .accessibilityHint("Mostra o conteúdo mais recente sem substituir uma edição em andamento")
            }

            if let work = session.progressiveWork,
                let error = work.lastError, !error.isEmpty
            {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        work.pendingRanges.isEmpty
                            ? "Não foi possível concluir o resumo: \(error)"
                            : "A transcrição foi interrompida: \(error) O resumo cobre somente o texto estabilizado.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    if !work.pendingRanges.isEmpty {
                        EmptyView()
                    } else if canRetryCompletion {
                        Button("Tentar concluir resumo", action: session.retryProgressiveCompletion)
                    } else {
                        Button("Tentar resumo novamente", action: session.retryProgressiveSummary)
                            .disabled(session.summaryIsUpdating)
                    }
                }
                .accessibilityElement(children: .contain)
            }

            if session.progressiveSaveStatus.hasPrefix("Não foi possível") {
                Label(session.progressiveSaveStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if session.progressiveSummaryWasAccepted {
                HStack {
                    Label("Resumo adicionado à nota", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let block = session.progressiveSummaryBlockForInsertion(), canUndo(block) {
                        Button("Desfazer adição") { onUndo(block) }
                    }
                }
            } else if session.progressiveSummaryText.isEmpty && editorText.isEmpty {
                Text(emptySummaryDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .padding(12)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                Button("Adicionar à nota", systemImage: "text.badge.plus") {}.disabled(true)
            } else {
                TextEditor(text: $editorText, selection: $editorSelection)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(6)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    .focused($summaryEditorFocused)
                    .disabled(session.progressiveSummaryWasAccepted)
                    .accessibilityLabel("Resumo da consulta editável")
                    .accessibilityHint("Rascunho criado por IA; revise antes de adicionar ao prontuário")
                    .onChange(of: editorText) { _, newText in
                        guard summaryEditorFocused else { return }
                        session.editProgressiveSummary(newText)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 24
                    } action: { _, atBottom in
                        editorIsAtBottom = atBottom
                    }

                HStack {
                    Menu {
                        Button("Ver transcrição-fonte") {
                            transcriptTargetID =
                                session.progressiveWork?.summary?
                                .coveredSegmentReferences.first?.segmentID
                            selectedTab = .transcript
                        }
                        Button("Histórico de alterações") { showsHistory = true }
                        Button("Detalhes do resumo") { showsSummaryDetails = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .fixedSize().accessibilityLabel("Mais opções do resumo")
                    .popover(isPresented: $showsSummaryDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(coverageStatus)
                            Text(generationStatus)
                            Text(saveStatus)
                        }.font(.callout).padding(16)
                    }
                    Spacer()
                    if let block = session.progressiveSummaryBlockForInsertion() {
                        if session.progressiveSummaryWasAccepted {
                            if canUndo(block) {
                                Button("Desfazer adição") { onUndo(block) }
                            } else {
                                Label("Adicionado à nota", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Adicionar à nota", systemImage: "text.badge.plus") {
                                onAccept(block)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.progressiveSummaryInsertionIssue(editorText: editorText) != nil)
                            .accessibilityHint("Acrescenta o resumo revisado ao rascunho da consulta")
                        }
                    }
                }
                if let issue = session.progressiveSummaryInsertionIssue(editorText: editorText) {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
                if session.progressiveSummaryNeedsReview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pontos para conferir").font(.headline)
                        ForEach(session.progressiveWork?.summary?.items.filter { $0.state == .needsReview } ?? []) { item in
                            Text(item.text).font(.callout)
                        }
                        Button("Editar resumo para resolver") { summaryEditorFocused = true }
                            .disabled(session.summaryIsUpdating || session.isBusy || session.progressiveSummaryHasPendingEdit
                                      || editorText != session.progressiveSummaryText)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var summarySubtitle: String {
        if session.summaryIsUpdating { return "Atualizando resumo…" }
        if session.progressiveSummaryNeedsReview { return "Divergência para revisar" }
        if session.progressiveSummaryText.isEmpty { return "Aguardando o primeiro resumo" }
        return "Proposta de IA · revise antes de adicionar"
    }

    private var coverageStatus: String {
        "Cobertura até \(ConsultationLiveStatusStrip.durationLabel(session.progressiveSummaryCoveredThrough))"
    }

    private var generationStatus: String {
        if session.summaryIsUpdating {
            return "Atualizando · \(session.progressiveSummaryProviderLabel)"
        }
        if session.progressiveSummaryNeedsReview { return "Divergência para revisar" }
        return "IA revisável · \(session.progressiveSummaryProviderLabel)"
    }

    private var saveStatus: String {
        session.progressiveSaveStatus.isEmpty ? "Aguardando salvamento" : session.progressiveSaveStatus
    }

    private var emptySummaryDescription: String {
        if session.progressiveWork?.summaryEngine != "openai/responses" {
            return "O resumo será gerado ao encerrar a gravação."
        }
        return "O resumo aparecerá aqui quando houver transcrição suficiente."
    }

    private func displayLatestSummary(followEnd: Bool) {
        editorText = session.visibleProgressiveSummaryText
        displayedRevision = session.progressiveSummaryRevision
        unseenUpdateCount = 0
        guard followEnd else { return }
        editorIsAtBottom = true
        editorSelection = TextSelection(insertionPoint: editorText.endIndex)
    }

    private var summaryHistory: some View {
        NavigationStack {
            List(session.progressiveWork?.summary?.revisions.reversed() ?? []) { revision in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revisão \(revision.sequence) · \(revision.origin == .model ? "IA" : "profissional")")
                        .font(.headline)
                    Text(revision.savedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(revision.computedDiff.isEmpty ? "Sem alteração no resumo." : revision.computedDiff)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Histórico do resumo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { showsHistory = false }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var canRetryCompletion: Bool {
        guard let work = session.progressiveWork, !work.segments.isEmpty,
            !session.isRecording, !session.isBusy
        else { return false }
        return work.status == .incomplete || work.status == .failed
    }

}

private struct ConsultationTranscriptPanel: View {
    let segments: [ConsultationTranscriptSegment]
    let partialText: String
    @Binding var targetID: String?

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if segments.isEmpty {
                        Text("Aguardando transcrição…")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "\(ConsultationLiveStatusStrip.durationLabel(segment.range.startSeconds))–\(ConsultationLiveStatusStrip.durationLabel(segment.range.endSeconds))"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                        }
                        .id(segment.id)
                    }
                    if !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Frase provisória", systemImage: "text.line.first.and.arrowtriangle.forward")
                                .font(.caption.weight(.semibold))
                            Text(partialText).italic()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Frase provisória, ainda não estabilizada pelo motor: \(partialText)")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: targetID) { _, id in
                guard let id else { return }
                withAnimation(.none) { reader.scrollTo(id, anchor: .center) }
                targetID = nil
            }
        }
        .accessibilityLabel("Transcrição da consulta")
    }
}
/// Compact capture controls anchored outside the document scroll view.
struct ConsultationRecordingFooter: View {
    @ObservedObject var session: EncounterTranscriptionSession
    let onReturn: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Label(session.isRecording ? (session.isPaused ? "Pausado" : "Gravando") : (session.isBusy ? "Processando" : "Gravação encerrada"),
                  systemImage: session.isRecording ? "record.circle" : "waveform")
                .foregroundStyle(session.isRecording && !session.isPaused ? Color.red : .secondary)
            Text(ConsultationLiveStatusStrip.durationLabel(session.progressiveWork?.capture.capturedSeconds ?? 0))
                .monospacedDigit().accessibilityLabel("Tempo de gravação")
            Spacer()
            Button("Ver transcrição", action: onReturn)
            if session.isRecording {
                Button("Parar", systemImage: "stop.fill") { session.stop() }
            }
        }
        .font(.callout).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
}
