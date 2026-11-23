// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import AVFoundation
import Combine
import CryptoKit
import Foundation

struct EncounterTranscriptionBinding: Equatable, Sendable {
    let vaultURL: URL
    let vaultID: String
    let patientID: String
    let encounterID: String
    let patientName: String
}

typealias EncounterTranscriptionPersist = (
    EncounterTranscriptInput,
    RawAssetCreationIdentity,
    Date
) throws -> Void

typealias EncounterConsultationWorkLoad = () throws -> (ProgressiveConsultationWork, Data)?
typealias EncounterConsultationWorkPersist = (ProgressiveConsultationWork, Data?) throws -> Data
typealias EncounterRealtimeTranscriptionFactory = (
    @escaping @Sendable (OpenAIRealtimeEvent) -> Void
) -> OpenAIRealtimeTranscription
typealias EncounterLiveTranscriptionConfiguration = () throws -> (apiKey: String, model: String)
typealias EncounterLiveTranscriptionPermission = () -> Bool
typealias EncounterRealtimeReconnectDelay = (Int) -> Duration
typealias EncounterAppleLiveTranscriptionFactory = (
    @escaping @MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void
) -> any AppleLiveTranscribing
typealias EncounterProgressiveSummaryFactory = (
    ProgressiveSummaryProvider,
    String?
) -> ProgressiveConsultationSummaryService

enum ConsultationTranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case appleLive
    case openAILive
    case appleAfterRecording

    var id: String { rawValue }
    var isLive: Bool { self != .appleAfterRecording }
}

struct EncounterProgressiveConfiguration: Equatable, Sendable {
    let source: ConsultationCaptureSource
    let transcriptionMode: ConsultationTranscriptionMode
    let summaryIntervalSeconds: Int
    let summaryProvider: ProgressiveSummaryProvider
    let summaryModel: String?

    init(
        source: ConsultationCaptureSource,
        transcriptionMode: ConsultationTranscriptionMode,
        summaryIntervalSeconds: Int,
        summaryProvider: ProgressiveSummaryProvider = .openAI,
        summaryModel: String? = AITextSettings.defaultConsultationSummaryModel
    ) {
        self.source = source
        self.transcriptionMode = transcriptionMode
        self.summaryIntervalSeconds = min(300, max(60, summaryIntervalSeconds))
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryProvider == .openAI ? summaryModel : nil
    }

    init(
        source: ConsultationCaptureSource,
        usesLiveTranscription: Bool,
        summaryIntervalSeconds: Int,
        summaryProvider: ProgressiveSummaryProvider = .openAI,
        summaryModel: String? = AITextSettings.defaultConsultationSummaryModel
    ) {
        self.init(
            source: source,
            transcriptionMode: usesLiveTranscription ? .openAILive : .appleAfterRecording,
            summaryIntervalSeconds: summaryIntervalSeconds,
            summaryProvider: summaryProvider,
            summaryModel: summaryModel
        )
    }
}

enum EncounterTelecallSessionIssue: Error, LocalizedError, Equatable, Sendable {
    case consentRequired
    case invalidDestination
    case destinationExists
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Confirme o consentimento dos participantes e o uso de conteúdo sintético antes de gravar."
        case .invalidDestination:
            "Escolha um novo arquivo WAV para guardar a gravação."
        case .destinationExists:
            "Já existe um arquivo nesse destino. Escolha outro nome para não substituir o conteúdo existente."
        case .operationInProgress:
            "Há uma gravação ou transcrição em andamento."
        }
    }
}

private enum EncounterScopeRelease {
    case clearURL
    case preserveURL
}

@MainActor
final class EncounterTranscriptionSession: ObservableObject {
    @Published private(set) var binding: EncounterTranscriptionBinding?
    @Published private(set) var scopeURL: URL?
    private(set) var scopeAccessURL: URL?
    @Published private(set) var transcript: EncounterTranscriptInput?
    @Published private(set) var identity: RawAssetCreationIdentity?
    @Published private(set) var savedAt: Date?
    @Published private(set) var saved = false
    @Published private(set) var recovered = false
    @Published private(set) var status = "Escolha um áudio sintético para transcrever neste Mac."
    @Published private(set) var isBusy = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var microphoneState: EncounterMicrophoneRecordingState = .idle
    @Published private(set) var telecallState: EncounterMicrophoneRecordingState = .idle
    @Published private(set) var progressiveWork: ProgressiveConsultationWork?
    @Published private(set) var partialTranscript = ""
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var callLevel = 0.0
    @Published private(set) var lastTranscriptUpdate: Date?
    @Published private(set) var progressiveSaveStatus = ""
    @Published private(set) var summaryIsUpdating = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPauseTransitioning = false

    let microphone: EncounterMicrophoneRecordingModel

    var hasUnsavedText: Bool { transcript != nil && !saved && !recovered }
    var canReset: Bool { !isBusy && !hasUnsavedText && workEditSaveTask == nil }
    var canDismiss: Bool { true }
    var isPrepared: Bool { binding != nil && persist != nil }
    var hasProgressiveWork: Bool { progressiveWork != nil }
    var stableTranscript: String {
        progressiveWork?.segments.map(\.text).joined(separator: "\n") ?? ""
    }
    var progressiveSummaryText: String { progressiveWork?.summary?.text ?? "" }
    var visibleProgressiveSummaryText: String { progressiveSummaryWasAccepted ? "" : progressiveSummaryText }
    var canResumeCapture: Bool { isPrepared && !isBusy && !hasUnsavedText }
    var progressiveSummaryRevision: Int { progressiveWork?.summary?.revision ?? 0 }
    var progressiveSummaryHasPendingEdit: Bool { pendingSummaryEditText != nil }
    var progressiveSummaryNeedsReview: Bool {
        progressiveWork?.summary?.items.contains(where: { $0.state == .needsReview }) == true
    }
    func progressiveSummaryInsertionIssue(editorText: String) -> String? {
        if isRecording { return "Encerre a gravação para adicionar o resumo à nota." }
        if isBusy { return "Aguarde a conclusão da transcrição." }
        if summaryIsUpdating { return "Aguarde a atualização do resumo." }
        if progressiveSummaryHasPendingEdit { return "Salvando sua revisão…" }
        if editorText != progressiveSummaryText { return "Há uma versão mais recente. Use Ver atualização para conferir o resumo antes de adicionar." }
        if progressiveSummaryNeedsReview { return "Confira os pontos marcados abaixo e ajuste o resumo acima. As alterações são salvas automaticamente." }
        if editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "O resumo ainda não tem texto para adicionar." }
        if progressiveWork?.summary?.revisions.contains(where: { $0.generation != nil }) != true { return "Aguardando o resumo e suas referências para adicionar à nota." }
        return nil
    }

    var progressiveSummaryWasAccepted: Bool {
        progressiveWork?.summary?.acceptance != nil
    }
    var progressiveSummaryProviderLabel: String {
        progressiveWork?.summaryEngine == "openai/responses"
            ? ProgressiveSummaryProvider.openAI.label
            : ProgressiveSummaryProvider.apple.label
    }
    var progressiveSummaryCoveredThrough: Double {
        guard let work = progressiveWork, let summary = work.summary else { return 0 }
        let covered = Set(summary.coveredSegmentReferences)
        return work.segments.filter {
            covered.contains(.init(segmentID: $0.id, revision: $0.revision))
        }.map(\.range.endSeconds).max() ?? 0
    }
    var isRecording: Bool {
        microphoneState == .recording
            || (telecallState == .recording && telecallCleanupTask == nil)
    }
    var isStartingRecording: Bool {
        microphoneState == .requestingPermission || telecallState == .requestingPermission
    }
    var canPauseLiveCapture: Bool {
        isRecording
            && liveCaptureActive
            && progressiveConfiguration?.source == .microphone
            && liveStopTask == nil
            && !isPauseTransitioning
    }

    private let transcriptionService: LocalTranscriptionService
    private let telecallCapture: any EncounterTelecallCapturing
    private let liveMicrophoneCapture: any EncounterLiveMicrophoneCapturing
    private let realtimeFactory: EncounterRealtimeTranscriptionFactory
    private let appleLiveFactory: EncounterAppleLiveTranscriptionFactory
    private let liveTranscriptionConfiguration: EncounterLiveTranscriptionConfiguration
    private let liveTranscriptionPermission: EncounterLiveTranscriptionPermission
    private let summaryServiceFactory: EncounterProgressiveSummaryFactory
    private let liveDrainDelay: Duration
    private let realtimeReconnectDelay: EncounterRealtimeReconnectDelay
    private var persist: EncounterTranscriptionPersist?
    private var loadWork: EncounterConsultationWorkLoad?
    private var persistWork: EncounterConsultationWorkPersist?
    private var persistedWorkData: Data?
    private var progressiveConfiguration: EncounterProgressiveConfiguration?
    private var liveTranscription: OpenAIRealtimeTranscription?
    private var appleLiveTranscription: (any AppleLiveTranscribing)?
    private var liveCaptureActive = false
    private var partialItems: [String: String] = [:]
    private var completedItems = Set<String>()
    private var summaryTask: Task<Void, Never>?
    private var summaryRetryWakeTask: Task<Void, Never>?
    private var summaryRetryNotBefore: Date?
    private var summaryRetryCount = 0
    private var nextAutomaticSummarySecond = 60.0
    private var workEditSaveTask: Task<Void, Never>?
    private var pendingSummaryEditText: String?
    private var pendingSummaryEditBaseText: String?
    private var pendingSummaryEditBaseRevision: Int?
    private var liveStopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var lastObservedLiveTranscriptionAllowed: Bool
    private var latestCapturedSeconds = 0.0
    private var captureTimeOffset = 0.0
    private var validateCapture: (() throws -> Void)?
    private var microphoneSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionCleanupTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var scopeAccessGranted = false
    private var acceptsRecordedAudio = false
    private var telecallURL: URL?
    private var telecallStartInFlight = false
    private var pendingTelecallEvent: EncounterMicrophoneCaptureEvent?
    private var telecallCleanupTask: Task<Void, Never>?
    private var transcribeTelecallAfterCleanup = false
    private var telecallCleanupStatus = "Operação cancelada."
    private var scopeReleaseAfterTranscriptionCleanup: EncounterScopeRelease?

    init(
        microphone: EncounterMicrophoneRecordingModel = EncounterMicrophoneRecordingModel(),
        telecallCapture: any EncounterTelecallCapturing = AppleEncounterTelecallCapture(),
        liveMicrophoneCapture: any EncounterLiveMicrophoneCapturing = AppleEncounterLiveMicrophoneCapture(),
        transcriptionService: LocalTranscriptionService = LocalTranscriptionService(),
        realtimeFactory: @escaping EncounterRealtimeTranscriptionFactory = {
            OpenAIRealtimeTranscription(eventHandler: $0)
        },
        appleLiveFactory: @escaping EncounterAppleLiveTranscriptionFactory = {
            AppleLiveTranscription(eventHandler: $0)
        },
        liveTranscriptionConfiguration: @escaping EncounterLiveTranscriptionConfiguration = {
            try AITextSettings.configuredLiveTranscription()
        },
        liveTranscriptionPermission: @escaping EncounterLiveTranscriptionPermission = {
            UserDefaults.standard.bool(forKey: AITextSettings.liveTranscriptionEnabledKey)
        },
        summaryServiceFactory: @escaping EncounterProgressiveSummaryFactory = { provider, model in
            ProgressiveConsultationSummaryService.configured(provider: provider, model: model)
        },
        liveDrainDelay: Duration = .seconds(20),
        realtimeReconnectDelay: @escaping EncounterRealtimeReconnectDelay = { attempt in
            .seconds(1 << min(2, max(0, attempt - 1)))
        }
    ) {
        self.microphone = microphone
        self.telecallCapture = telecallCapture
        self.liveMicrophoneCapture = liveMicrophoneCapture
        self.transcriptionService = transcriptionService
        self.realtimeFactory = realtimeFactory
        self.appleLiveFactory = appleLiveFactory
        self.liveTranscriptionConfiguration = liveTranscriptionConfiguration
        self.liveTranscriptionPermission = liveTranscriptionPermission
        self.lastObservedLiveTranscriptionAllowed = liveTranscriptionPermission()
        self.summaryServiceFactory = summaryServiceFactory
        self.liveDrainDelay = liveDrainDelay
        self.realtimeReconnectDelay = realtimeReconnectDelay
        microphoneState = microphone.state
        microphoneSubscription = microphone.$state.sink { [weak self] state in
            self?.receiveMicrophoneState(state)
        }
        settingsSubscription = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )
        .sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.receiveSettingsChange()
            }
        }
    }

    private func receiveMicrophoneState(_ state: EncounterMicrophoneRecordingState) {
        microphoneState = state
        updateBusy()
        switch state {
        case .idle:
            if transcriptionTask == nil, transcript == nil {
                status = "Escolha um áudio sintético para transcrever neste Mac."
            }
        case .requestingPermission:
            status = "Solicitando acesso ao microfone…"
        case .recording:
            startedAt = startedAt ?? Date()
            status = "Gravando pelo microfone… limite de 60 minutos."
            setProgressiveCaptureState(.recording, startedAt: startedAt)
        case .recorded:
            break
        case let .failed(message):
            status = message
        }
        guard state == .recorded,
              acceptsRecordedAudio,
              let url = microphone.recordedURL else { return }
        acceptsRecordedAudio = false
        beginTranscription(at: url)
    }

    private func receiveSettingsChange() {
        let isAllowed = liveTranscriptionPermission()
        let wasAllowed = lastObservedLiveTranscriptionAllowed
        lastObservedLiveTranscriptionAllowed = isAllowed
        guard wasAllowed, !isAllowed else { return }
        applyRemotePermissionChanges(liveTranscriptionAllowed: false)
    }

    func availableTelecallApplications() async throws -> [TeleconsultAudioApplication] {
        guard !isBusy else { throw EncounterTelecallSessionIssue.operationInProgress }
        return try await telecallCapture.availableApplications()
    }

    @discardableResult
    func prepare(
        binding newBinding: EncounterTranscriptionBinding,
        onPersist: @escaping EncounterTranscriptionPersist,
        onLoadWork: EncounterConsultationWorkLoad? = nil,
        onPersistWork: EncounterConsultationWorkPersist? = nil,
        onValidateCapture: (() throws -> Void)? = nil
    ) -> Bool {
        if binding == newBinding {
            persist = onPersist
            loadWork = onLoadWork
            persistWork = onPersistWork
            validateCapture = onValidateCapture
            if progressiveWork == nil { loadProgressiveWork() }
            return true
        }
        guard canReset else {
            status = isBusy
                ? "Há uma gravação ou transcrição em andamento para outra consulta."
                : "Guarde ou exporte o texto pendente antes de iniciar outra transcrição."
            return false
        }
        clearForNextSession()
        binding = newBinding
        persist = onPersist
        loadWork = onLoadWork
        persistWork = onPersistWork
        validateCapture = onValidateCapture
        loadProgressiveWork()
        status = "Escolha um áudio sintético para transcrever neste Mac."
        if progressiveWork != nil {
            status = "Rascunho de acompanhamento recuperado. A captura não foi retomada."
        }
        return true
    }

    func configureProgressive(_ configuration: EncounterProgressiveConfiguration) {
        guard isPrepared, !isBusy else { return }
        progressiveConfiguration = configuration
        nextAutomaticSummarySecond = Double(configuration.summaryIntervalSeconds)
    }

    func startRecording(at url: URL, consent: Bool, authorizationURL: URL? = nil) async {
        guard prepareForNewCapture() else { return }
        if progressiveConfiguration?.transcriptionMode.isLive == true {
            await startLiveMicrophoneRecording(at: url, consent: consent, authorizationURL: authorizationURL)
            return
        }
        guard isPrepared, !isBusy, transcriptionTask == nil, transcript == nil else { return }
        guard beginProgressiveWorkIfNeeded(audioURL: url) else { return }
        AssistantVoiceSession.observeClinical(self)
        AssistantVoiceSession.suspendForClinicalCapture()
        beginScopeAccess(to: url, authorizationURL: authorizationURL)
        acceptsRecordedAudio = true
        await microphone.start(at: url, consent: consent)
        if microphone.recordedURL == nil, !hasUsefulAudio(at: url) {
            endScopeAccess()
        }
        updateBusy()
    }

    func startTelecallRecording(
        at url: URL,
        application: TeleconsultAudioApplication,
        consent: Bool,
        authorizationURL: URL? = nil
    ) async {
        guard prepareForNewCapture() else { return }
        if progressiveConfiguration?.transcriptionMode.isLive == true {
            await startLiveTelecallRecording(at: url, application: application, consent: consent, authorizationURL: authorizationURL)
            return
        }
        guard isPrepared, !isBusy, transcriptionTask == nil, transcript == nil else { return }
        guard consent else {
            failTelecall(EncounterTelecallSessionIssue.consentRequired)
            return
        }
        do {
            try validateNewTelecallDestination(url)
        } catch {
            failTelecall(error)
            return
        }

        guard beginProgressiveWorkIfNeeded(audioURL: url) else { return }
        AssistantVoiceSession.observeClinical(self)
        AssistantVoiceSession.suspendForClinicalCapture()
        beginScopeAccess(to: url, authorizationURL: authorizationURL)
        generation &+= 1
        let operationGeneration = generation
        telecallURL = url
        telecallStartInFlight = true
        telecallState = .requestingPermission
        status = "Solicitando acesso à telechamada…"
        updateBusy()

        defer {
            telecallStartInFlight = false
            updateBusy()
        }

        do {
            try await withTaskCancellationHandler {
                try await telecallCapture.start(
                    at: url,
                    application: application,
                    maximumDuration: EncounterMicrophoneRecordingModel.maximumDuration,
                    eventHandler: { [weak self] event in
                        Task { @MainActor in
                            self?.receiveTelecall(
                                event,
                                at: url,
                                generation: operationGeneration
                            )
                        }
                    }
                )
                try Task.checkCancellation()
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelTelecallStart(generation: operationGeneration)
                }
            }

            if await resolvePendingTelecallEvent(generation: operationGeneration, at: url) { return }

            guard generation == operationGeneration,
                  telecallState == .requestingPermission else {
                if let telecallCleanupTask { await telecallCleanupTask.value }
                beginTelecallCleanup()
                if let telecallCleanupTask { await telecallCleanupTask.value }
                return
            }
            telecallState = .recording
            startedAt = startedAt ?? Date()
            status = "Gravando microfone e áudio da telechamada… limite de 60 minutos."
            setProgressiveCaptureState(.recording, startedAt: startedAt)
        } catch is CancellationError {
            if !Task.isCancelled,
               await resolvePendingTelecallEvent(generation: operationGeneration, at: url) {
                return
            }
            cancelTelecallStart(generation: operationGeneration)
            if let telecallCleanupTask { await telecallCleanupTask.value }
            beginTelecallCleanup()
            if let telecallCleanupTask { await telecallCleanupTask.value }
        } catch {
            guard generation == operationGeneration else {
                if let telecallCleanupTask { await telecallCleanupTask.value }
                return
            }
            generation &+= 1
            transcribeTelecallAfterCleanup = false
            telecallCleanupStatus = error.localizedDescription
            telecallState = .requestingPermission
            beginTelecallCleanup()
            if let telecallCleanupTask { await telecallCleanupTask.value }
        }
    }

    func transcribe(url: URL) {
        beginProgressiveWorkIfNeeded(audioURL: url)
        beginTranscription(at: url)
    }

    func stop() {
        if liveCaptureActive || liveTranscription != nil || appleLiveTranscription != nil || liveStopTask != nil {
            stopLiveRecording()
            return
        }
        if telecallCleanupTask != nil { return }
        if telecallState == .recording || telecallState == .requestingPermission
            || telecallStartInFlight {
            let shouldTranscribe = telecallState == .recording
            if !shouldTranscribe { generation &+= 1 }
            transcribeTelecallAfterCleanup = shouldTranscribe
            telecallCleanupStatus = shouldTranscribe
                ? "Gravação encerrada. O áudio foi preservado no destino escolhido."
                : "Operação cancelada."
            status = shouldTranscribe ? "Finalizando gravação…" : "Cancelando gravação…"
            beginTelecallCleanup()
            updateBusy()
            return
        }
        microphone.stop()
        if microphoneState == .recording {
            status = "Finalizando gravação…"
        }
        updateBusy()
    }

    func togglePause() {
        guard canPauseLiveCapture else { return }
        let wasPaused = isPaused
        let operationGeneration = generation
        isPauseTransitioning = true
        status = wasPaused ? "Retomando gravação…" : "Pausando gravação…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPauseTransitioning = false }
            do {
                if wasPaused {
                    try await self.liveMicrophoneCapture.resume()
                    guard self.generation == operationGeneration, self.liveCaptureActive else { return }
                    self.isPaused = false
                    self.status = "Gravando · aguardando fala"
                } else {
                    try await self.liveMicrophoneCapture.pause()
                    guard self.generation == operationGeneration, self.liveCaptureActive else { return }
                    self.isPaused = true
                    self.microphoneLevel = 0
                    self.callLevel = 0
                    self.status = "Gravação pausada · áudio não está sendo captado"
                }
            } catch {
                guard self.generation == operationGeneration, self.liveCaptureActive else { return }
                self.status = "Não foi possível alterar a pausa: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        let wasLive = liveCaptureActive || liveTranscription != nil
            || appleLiveTranscription != nil || liveStopTask != nil
        generation &+= 1
        cancelLivePipeline(reason: "Operação cancelada.")
        if !wasLive, progressiveWork != nil {
            setProgressiveCaptureState(.incomplete, endedAt: Date())
        }
        acceptsRecordedAudio = false
        cancelTranscriptionAndTrackCleanup()
        if microphoneState == .requestingPermission || microphoneState == .recording {
            microphone.stop()
            if microphone.recordedURL == nil,
               let scopeURL,
               !hasUsefulAudio(at: scopeURL) {
                endScopeAccess()
            }
        }
        if telecallState == .requestingPermission || telecallState == .recording
            || telecallStartInFlight || telecallCleanupTask != nil {
            transcribeTelecallAfterCleanup = false
            telecallCleanupStatus = "Operação cancelada."
            status = preservationStatus(prefix: "Operação cancelada.")
            beginTelecallCleanup()
        }
        status = preservationStatus(prefix: "Operação cancelada.")
        updateBusy()
    }

    func summarizeNow() {
        scheduleProgressiveSummary(force: true)
    }

    func retryProgressiveSummary() {
        guard progressiveWork != nil else { return }
        if !isRecording {
            retryProgressiveCompletion()
            return
        }
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        summaryRetryNotBefore = nil
        summaryRetryCount = 0
        scheduleProgressiveSummary(force: true)
    }

    func retryProgressiveCompletion() {
        guard progressiveWork != nil, !isBusy else { return }
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        summaryRetryNotBefore = nil
        summaryRetryCount = 0
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completeProgressiveWorkAfterStop(ownsSummaryTask: true)
            self.summaryTask = nil
            self.updateBusy()
        }
        updateBusy()
    }

    func editProgressiveSummary(_ text: String) {
        guard let work = progressiveWork,
              work.summary?.acceptance == nil,
              text.utf8.count <= 500_000 else { return }
        if pendingSummaryEditText == nil {
            pendingSummaryEditBaseText = work.summary?.text ?? ""
            pendingSummaryEditBaseRevision = work.summary?.revision ?? 0
            summaryTask?.cancel()
        }
        pendingSummaryEditText = text.precomposedStringWithCanonicalMapping
        workEditSaveTask?.cancel()
        progressiveSaveStatus = "Salvando…"
        workEditSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            guard let self else { return }
            self.workEditSaveTask = nil
            self.commitPendingSummaryEdit()
        }
    }

    func markProgressiveSummaryAccepted(_ acceptance: ConsultationSummaryAcceptance) throws {
        guard var work = progressiveWork, var summary = work.summary,
              summary.acceptance == nil,
              acceptance.acceptedText == summary.text else {
            throw ProgressiveConsultationWorkIssue.revisionConflict
        }
        summary.acceptance = acceptance
        work.summary = summary
        work.updatedAt = Date()
        try persistRequiredProgressiveWork(work)
    }

    func markProgressiveSummaryUndone() throws {
        guard var work = progressiveWork, var summary = work.summary,
              summary.acceptance != nil else {
            throw ProgressiveConsultationWorkIssue.revisionConflict
        }
        summary.acceptance = nil
        work.summary = summary
        work.updatedAt = Date()
        try persistRequiredProgressiveWork(work)
    }

    func progressiveSummaryBlockForInsertion() -> ConsultationSummaryBlock? {
        guard let work = progressiveWork, let summary = work.summary,
              !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let latestGeneration = summary.revisions.reversed().compactMap(\.generation).first else {
            return nil
        }
        let generations = summary.revisions.compactMap(\.generation)
        let references = uniqueReferences(summary.coveredSegmentReferences)
        let audit = summary.revisions.map { revision in
            """
            Revisão \(revision.sequence) · \(revision.origin.rawValue) · \(revision.kind.rawValue)
            Antes:
            \(revision.beforeText)
            Depois:
            \(revision.afterText)
            Diff calculado pelo OpenPEP:
            \(revision.computedDiff.isEmpty ? "(sem alteração)" : revision.computedDiff)
            """
        }.joined(separator: "\n\n")
        let source = """
        Cadeia de entradas do resumo incremental:

        \(generations.map(\.source).joined(separator: "\n\n--- próxima atualização ---\n\n"))

        Histórico local de revisões:

        \(audit)
        """
        let aggregateGeneration = ConsultationSummaryGeneration(
            generationID: latestGeneration.generationID,
            engine: latestGeneration.engine,
            model: latestGeneration.model,
            responseID: latestGeneration.responseID,
            promptVersion: ProgressiveConsultationSummaryService.promptVersion,
            generatedAt: latestGeneration.generatedAt,
            source: source,
            segmentReferences: references
        )
        let generatedText = summary.revisions.reversed().first(where: {
            $0.origin == .model && $0.kind == .update
        })?.afterText ?? summary.text
        let uuid = latestGeneration.generationID.dropFirst("gen_".count)
        return ConsultationSummaryBlock(
            id: "block_\(uuid)",
            kind: .consolidated,
            range: .init(startSeconds: 0, endSeconds: progressiveSummaryCoveredThrough,
                         isApproximate: true),
            subject: "Resumo da consulta",
            generatedText: generatedText,
            editedText: summary.text,
            state: summary.acceptance == nil
                ? (summary.items.contains(where: { $0.state == .needsReview }) ? .needsReview : .edited)
                : .added,
            generation: aggregateGeneration,
            acceptance: summary.acceptance
        )
    }

    private func commitPendingSummaryEdit() {
        guard var work = progressiveWork, var summary = work.summary,
              summary.acceptance == nil,
              let text = pendingSummaryEditText,
              let before = pendingSummaryEditBaseText,
              let baseRevision = pendingSummaryEditBaseRevision else { return }
        pendingSummaryEditText = nil
        pendingSummaryEditBaseText = nil
        pendingSummaryEditBaseRevision = nil
        guard summary.revision == baseRevision else {
            progressiveSaveStatus = "A atualização chegou durante a edição; revise o texto preservado."
            return
        }
        guard text != before else {
            progressiveSaveStatus = "Salvo neste Mac"
            return
        }
        let references = uniqueReferences(summary.coveredSegmentReferences)
        let itemID = "summary_item_\(UUID().uuidString.lowercased())"
        summary.items = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [
            ConsultationSummaryItem(
                id: itemID,
                text: text,
                state: .professional,
                segmentReferences: references
            )
        ]
        let affected = summary.items.map(\.id)
        let sequence = summary.revision + 1
        summary.revisions.append(.init(
            id: "revision_\(UUID().uuidString.lowercased())",
            sequence: sequence,
            baseRevision: summary.revision,
            savedAt: Date(),
            origin: .professional,
            kind: .update,
            affectedItemIDs: affected,
            segmentReferences: references,
            beforeText: before,
            afterText: text,
            computedDiff: ConsultationSummaryDiff.make(before: before, after: text),
            generation: nil
        ))
        summary.revision = sequence
        work.summary = summary
        work.updatedAt = Date()
        progressiveWork = work
        saveProgressiveWork()
        if isRecording, progressiveSummaryIntervalIsReady {
            scheduleProgressiveSummary(force: false)
        }
    }

    private func persistRequiredProgressiveWork(_ work: ProgressiveConsultationWork) throws {
        guard let persistWork else {
            progressiveWork = work
            return
        }
        progressiveSaveStatus = "Salvando…"
        do {
            let data = try persistWork(work, persistedWorkData)
            progressiveWork = work
            persistedWorkData = data
            progressiveSaveStatus = "Salvo neste Mac"
        } catch {
            progressiveSaveStatus = "Não foi possível salvar: \(error.localizedDescription)"
            status = "A alteração clínica não foi concluída porque o rascunho local não pôde ser salvo."
            throw error
        }
    }

    private func uniqueReferences(
        _ references: [ConsultationTranscriptSegmentReference]
    ) -> [ConsultationTranscriptSegmentReference] {
        var seen = Set<ConsultationTranscriptSegmentReference>()
        return references.filter { seen.insert($0).inserted }
    }

    func retryPersist() {
        guard !saved, let transcript, let identity, let savedAt, let persist else { return }
        do {
            try persist(transcript, identity, savedAt)
            saved = true
            recovered = false
            status = "Transcrição guardada nos documentos da consulta."
        } catch {
            status = "O texto permanece disponível para recuperação. " + error.localizedDescription
        }
    }

    func markRecovered() {
        guard transcript != nil, !saved else { return }
        recovered = true
        status = "Cópia de recuperação salva. A inclusão na consulta continua pendente."
    }

    @discardableResult
    func dismiss() -> Bool {
        true
    }

    var canRetryEmptyCapture: Bool {
        guard canReset, let work = progressiveWork else { return false }
        return work.capture.status == .failed && work.capture.capturedSeconds == 0
            && work.segments.isEmpty && work.blocks.isEmpty && (work.summary ?? .empty) == .empty
            && partialTranscript.isEmpty
            && (scopeURL.map { !hasUsefulAudio(at: $0) } ?? true)
    }

    @discardableResult
    func prepareRetryAfterEmptyCaptureFailure() -> Bool {
        guard canRetryEmptyCapture else { return false }
        endScopeAccess()
        microphone.reset()
        microphoneState = .idle
        telecallState = .idle
        telecallURL = nil
        progressiveWork = nil
        partialTranscript = ""
        startedAt = nil
        return true
    }

    @discardableResult
    func reset() -> Bool {
        guard canReset else {
            status = isBusy
                ? "Pare ou cancele a operação antes de iniciar outra transcrição."
                : "Guarde ou exporte o texto pendente antes de iniciar outra transcrição."
            return false
        }
        clearForNextSession()
        status = "Escolha um áudio sintético para transcrever neste Mac."
        return true
    }

    func shutdown() {
        generation &+= 1
        if workEditSaveTask != nil {
            workEditSaveTask?.cancel()
            workEditSaveTask = nil
            commitPendingSummaryEdit()
        }
        cancelLivePipeline(reason: "Sessão encerrada.")
        summaryTask?.cancel()
        summaryTask = nil
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        acceptsRecordedAudio = false
        cancelTranscriptionAndTrackCleanup()
        microphone.dismiss()
        if progressiveWork != nil, persistWork != nil {
            saveProgressiveWork()
        }
        persist = nil
        loadWork = nil
        persistWork = nil
        if telecallState == .requestingPermission || telecallState == .recording
            || telecallStartInFlight || telecallCleanupTask != nil {
            transcribeTelecallAfterCleanup = false
            telecallCleanupStatus = "Sessão encerrada."
            beginTelecallCleanup()
        } else if transcriptionCleanupTask != nil {
            scopeReleaseAfterTranscriptionCleanup = telecallURL != nil && hasUsefulTelecallAudio()
                ? .preserveURL
                : .clearURL
        } else if telecallURL != nil, hasUsefulTelecallAudio() {
            releaseScopeAccessPreservingURL()
        } else {
            telecallURL = nil
            endScopeAccess()
        }
        status = preservationStatus(prefix: "Sessão encerrada.")
        updateBusy()
    }

    private func beginTranscription(at url: URL) {
        guard let sessionBinding = binding,
              isPrepared,
              transcriptionTask == nil,
              transcript == nil,
              microphoneState != .requestingPermission,
              microphoneState != .recording,
              telecallState != .requestingPermission,
              telecallState != .recording,
              !telecallStartInFlight,
              telecallCleanupTask == nil,
              transcriptionCleanupTask == nil else { return }
        beginScopeAccess(to: url)
        generation &+= 1
        let taskGeneration = generation
        status = "Verificando áudio e transcrevendo localmente…"
        setProgressiveCaptureState(.transcribing, endedAt: Date())
        updateBusy(transcriptionActive: true)
        transcriptionTask = Task { [weak self, transcriptionService] in
            do {
                let originalHash = try await Task.detached {
                    try Self.audioHash(url)
                }.value
                let result = try await transcriptionService.transcribeImportedAudio(at: url)
                try Task.checkCancellation()
                let currentHash = try await Task.detached {
                    try Self.audioHash(url)
                }.value
                try Task.checkCancellation()
                guard currentHash == originalHash else { throw PatientAIIssue.changed }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LocalTranscriptionIssue.noAudioSamples
                }
                let timestamp = Date()
                let newIdentity = try RawAssetCreationIdentity.generate(at: timestamp)
                let input = EncounterTranscriptInput(
                    text: result.text,
                    audioSHA256: originalHash,
                    localeIdentifier: result.localeIdentifier,
                    operationID: UUID().uuidString.lowercased()
                )
                guard let self,
                      self.generation == taskGeneration,
                      self.binding == sessionBinding else { return }
                self.identity = newIdentity
                self.savedAt = timestamp
                self.transcript = input
                self.transcriptionTask = nil
                self.updateBusy()
                self.retryPersist()
                self.publishBatchTranscript(
                    result.text,
                    localeIdentifier: result.localeIdentifier,
                    audioURL: url,
                    capturedAt: timestamp
                )
            } catch is CancellationError {
                guard let self, self.generation == taskGeneration else { return }
                self.transcriptionTask = nil
                self.status = self.preservationStatus(prefix: "Transcrição cancelada.")
                self.updateBusy()
            } catch {
                guard let self,
                      self.generation == taskGeneration,
                      self.binding == sessionBinding else { return }
                self.transcriptionTask = nil
                self.status = error.localizedDescription
                if var work = self.progressiveWork {
                    work.status = .failed
                    work.capture.status = .failed
                    work.lastError = error.localizedDescription
                    work.updatedAt = Date()
                    self.progressiveWork = work
                    self.saveProgressiveWork()
                }
                self.updateBusy()
            }
        }
    }

    private func loadProgressiveWork() {
        guard let loadWork else { return }
        do {
            let loaded = try loadWork()
            progressiveWork = loaded?.0
            persistedWorkData = loaded?.1
            progressiveSaveStatus = loaded == nil ? "" : "Salvo neste Mac"
            if let work = loaded?.0 {
                nextAutomaticSummarySecond = Double(work.summaryIntervalSeconds)
            }
        } catch {
            progressiveWork = nil
            persistedWorkData = nil
            progressiveSaveStatus = "Não foi possível abrir o rascunho: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func beginProgressiveWorkIfNeeded(audioURL: URL) -> Bool {
        guard let binding, let configuration = progressiveConfiguration else { return true }
        var document: ProgressiveConsultationWork
        if let previous = progressiveWork, previous.summary?.acceptance == nil {
            document = previous
            captureTimeOffset = max(previous.capture.capturedSeconds,
                previous.segments.last?.range.endSeconds ?? 0)
            var filenames = previous.capture.audioFilenames ?? previous.capture.audioFilename.map { [$0] } ?? []
            if filenames.last != audioURL.lastPathComponent { filenames.append(audioURL.lastPathComponent) }
            document.capture.audioFilenames = filenames
            document.capture.endedAt = nil
            document.capture.source = configuration.source
            document.capture.status = .preparing
            document.capture.capturedSeconds = captureTimeOffset
            document.status = .preparing
            document.updatedAt = Date()
        } else {
            captureTimeOffset = 0
            document = ProgressiveConsultationWork(
                binding: binding, source: configuration.source,
                summaryIntervalSeconds: configuration.summaryIntervalSeconds,
                transcriptionEngine: configuration.transcriptionMode == .openAILive
                    ? "openai/realtime" : "apple/SpeechTranscriber",
                transcriptionModel: configuration.transcriptionMode == .openAILive
                    ? OpenAIRealtimeTranscription.model : LocalTranscriptionService.portugueseBrazil.identifier(.bcp47),
                summaryEngine: configuration.summaryProvider == .openAI ? "openai/responses" : ConsultationSummaryProvenance.engine,
                summaryModel: configuration.summaryProvider == .openAI ? configuration.summaryModel : nil)
        }
        document.capture.audioFilename = audioURL.lastPathComponent
        document.summaryIntervalSeconds = configuration.summaryIntervalSeconds
        document.summaryEngine = configuration.summaryProvider == .openAI
            ? "openai/responses" : ConsultationSummaryProvenance.engine
        document.summaryModel = configuration.summaryProvider == .openAI ? configuration.summaryModel : nil
        document.transcriptionEngine = configuration.transcriptionMode == .openAILive
            ? "openai/realtime" : "apple/SpeechTranscriber"
        document.transcriptionModel = configuration.transcriptionMode == .openAILive
            ? OpenAIRealtimeTranscription.model : LocalTranscriptionService.portugueseBrazil.identifier(.bcp47)
        do { try persistRequiredProgressiveWork(document) }
        catch { return false }
        latestCapturedSeconds = captureTimeOffset
        nextAutomaticSummarySecond = captureTimeOffset + Double(document.summaryIntervalSeconds)
        completedItems = []
        partialItems = [:]
        partialTranscript = ""
        return true
    }

    private func prepareForNewCapture() -> Bool {
        guard canResumeCapture else { return false }
        do { try validateCapture?() }
        catch { status = error.localizedDescription; return false }
        if pendingSummaryEditText != nil {
            workEditSaveTask?.cancel()
            workEditSaveTask = nil
            commitPendingSummaryEdit()
            guard pendingSummaryEditText == nil, !progressiveSaveStatus.hasPrefix("Não foi possível") else { return false }
        }
        // The batch transcript is already persisted; a new take gets its own asset.
        transcript = nil
        identity = nil
        savedAt = nil
        saved = false
        recovered = false
        microphone.reset()
        microphoneState = .idle
        telecallState = .idle
        startedAt = nil
        return true
    }

    private func saveProgressiveWork() {
        guard let work = progressiveWork, let persistWork else { return }
        progressiveSaveStatus = "Salvando…"
        do {
            persistedWorkData = try persistWork(work, persistedWorkData)
            progressiveSaveStatus = "Salvo neste Mac"
        } catch {
            progressiveSaveStatus = "Não foi possível salvar: \(error.localizedDescription)"
            status = "O acompanhamento permanece aberto, mas não foi possível salvar."
        }
    }

    private func startLiveMicrophoneRecording(at url: URL, consent: Bool, authorizationURL: URL? = nil) async {
        guard isPrepared, !isBusy, transcript == nil else { return }
        guard consent else {
            microphoneState = .failed(EncounterMicrophoneRecordingIssue.consentRequired.localizedDescription)
            status = EncounterMicrophoneRecordingIssue.consentRequired.localizedDescription
            return
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "wav",
              !FileManager.default.fileExists(atPath: url.path) else {
            microphoneState = .failed(EncounterMicrophoneRecordingIssue.invalidDestination.localizedDescription)
            status = EncounterMicrophoneRecordingIssue.invalidDestination.localizedDescription
            return
        }
        guard beginProgressiveWorkIfNeeded(audioURL: url) else { return }
        AssistantVoiceSession.observeClinical(self)
        AssistantVoiceSession.suspendForClinicalCapture()
        beginScopeAccess(to: url, authorizationURL: authorizationURL)
        generation &+= 1
        let operationGeneration = generation
        microphoneState = .requestingPermission
        status = progressiveConfiguration?.transcriptionMode == .appleLive
            ? "Preparando a transcrição Apple neste Mac…"
            : "Conectando a transcrição ao vivo…"
        updateBusy()
        do {
            try await startSelectedLiveTranscription(generation: operationGeneration)
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            guard await liveMicrophoneCapture.requestAccess() else {
                throw EncounterMicrophoneRecordingIssue.permissionDenied
            }
            try validateCapture?()
            liveCaptureActive = true
            try liveMicrophoneCapture.start(
                at: url,
                maximumDuration: EncounterMicrophoneRecordingModel.maximumDuration,
                chunkHandler: { [weak self] chunk in
                    Task { @MainActor in self?.receiveLiveAudio(chunk, generation: operationGeneration) }
                },
                eventHandler: { [weak self] event in
                    Task { @MainActor in self?.finishLiveCapture(event, generation: operationGeneration) }
                }
            )
            guard generation == operationGeneration else {
                liveMicrophoneCapture.stop()
                throw CancellationError()
            }
            isPaused = false
            isPauseTransitioning = false
            startedAt = Date()
            microphoneState = .recording
            setProgressiveCaptureState(.recording, startedAt: startedAt)
            status = "Gravando · aguardando fala"
            updateBusy()
        } catch is CancellationError {
            cancelLivePipeline(reason: "Operação cancelada.")
        } catch {
            failLiveStart(error, microphone: true)
        }
    }

    private func startLiveTelecallRecording(
        at url: URL,
        application: TeleconsultAudioApplication,
        consent: Bool,
        authorizationURL: URL? = nil
    ) async {
        guard isPrepared, !isBusy, transcript == nil else { return }
        guard consent else {
            failTelecall(EncounterTelecallSessionIssue.consentRequired)
            return
        }
        do { try validateNewTelecallDestination(url) } catch {
            failTelecall(error)
            return
        }
        guard let liveCapture = telecallCapture as? any EncounterTelecallLiveCapturing else {
            failTelecall(EncounterTelecallRecordingIssue.outputSetup)
            return
        }
        guard beginProgressiveWorkIfNeeded(audioURL: url) else { return }
        AssistantVoiceSession.observeClinical(self)
        AssistantVoiceSession.suspendForClinicalCapture()
        beginScopeAccess(to: url, authorizationURL: authorizationURL)
        generation &+= 1
        let operationGeneration = generation
        telecallURL = url
        telecallStartInFlight = true
        telecallState = .requestingPermission
        status = progressiveConfiguration?.transcriptionMode == .appleLive
            ? "Preparando a transcrição Apple neste Mac…"
            : "Conectando a transcrição ao vivo…"
        updateBusy()
        defer { telecallStartInFlight = false; updateBusy() }
        do {
            try await startSelectedLiveTranscription(generation: operationGeneration)
            try validateCapture?()
            liveCaptureActive = true
            try await liveCapture.startLive(
                at: url,
                application: application,
                maximumDuration: EncounterMicrophoneRecordingModel.maximumDuration,
                stableChunkHandler: { [weak self] chunk in
                    Task { @MainActor in self?.receiveLiveAudio(chunk, generation: operationGeneration) }
                },
                eventHandler: { [weak self] event in
                    Task { @MainActor in self?.finishLiveCapture(event, generation: operationGeneration) }
                }
            )
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            isPaused = false
            isPauseTransitioning = false
            startedAt = Date()
            telecallState = .recording
            setProgressiveCaptureState(.recording, startedAt: startedAt)
            status = "Gravando chamada · aguardando fala"
            updateBusy()
        } catch is CancellationError {
            cancelLivePipeline(reason: "Operação cancelada.")
        } catch {
            failLiveStart(error, microphone: false)
        }
    }

    private func makeRealtimeTranscription(generation operationGeneration: UInt) -> OpenAIRealtimeTranscription {
        realtimeFactory { [weak self] event in
            Task { @MainActor in
                self?.receiveRealtimeEvent(event, generation: operationGeneration)
            }
        }
    }

    private func startSelectedLiveTranscription(generation operationGeneration: UInt) async throws {
        switch progressiveConfiguration?.transcriptionMode {
        case .appleLive:
            let service = appleLiveFactory { [weak self] event in
                self?.receiveAppleLiveEvent(event, generation: operationGeneration)
            }
            appleLiveTranscription = service
            try await service.start(locale: LocalTranscriptionService.portugueseBrazil)
        case .openAILive:
            let configuration = try liveTranscriptionConfiguration()
            guard configuration.model == OpenAIRealtimeTranscription.model else {
                throw AITextSettingsIssue.changed
            }
            let service = makeRealtimeTranscription(generation: operationGeneration)
            liveTranscription = service
            try await service.connect(apiKey: configuration.apiKey)
            reconnectAttempts = 0
        case .appleAfterRecording, nil:
            throw LocalTranscriptionIssue.engineFailure
        }
    }

    private func receiveLiveAudio(_ chunk: EncounterAudioChunk, generation operationGeneration: UInt) {
        guard generation == operationGeneration, liveCaptureActive else { return }
        latestCapturedSeconds = max(
            latestCapturedSeconds,
            captureTimeOffset + Double(chunk.samplePosition + Int64(chunk.frameCount)) / Double(chunk.format.sampleRate)
        )
        if chunk.source == .microphone {
            microphoneLevel = chunk.level
        } else {
            callLevel = chunk.level
        }
        if var work = progressiveWork {
            work.capture.capturedSeconds = latestCapturedSeconds
            progressiveWork = work
        }
        if let appleLiveTranscription {
            if !appleLiveTranscription.enqueue(chunk) {
                markPendingRange("A transcrição Apple não acompanhou o áudio. A gravação local continua preservada.")
            }
        } else if let liveTranscription {
            do {
                try liveTranscription.enqueue(EncounterRealtimePCMConverter.convert(chunk))
            } catch {
                markPendingRange(error.localizedDescription)
            }
        }
        // Audio and stabilized transcription callbacks can arrive in either order.
        // Re-evaluate the boundary here as well as when publishing a segment.
        scheduleProgressiveSummary(force: false)
    }

    private func receiveAppleLiveEvent(
        _ event: AppleLiveTranscriptionEvent,
        generation operationGeneration: UInt
    ) {
        guard generation == operationGeneration else { return }
        switch event {
        case let .partial(text):
            partialTranscript = text
            lastTranscriptUpdate = Date()
            status = text.isEmpty ? "Gravando · aguardando fala" : "Gravando · transcrição Apple em andamento"
        case let .final(text, startSeconds, endSeconds):
            partialTranscript = ""
            publishAppleLiveSegment(text, startSeconds: startSeconds, endSeconds: endSeconds)
        case let .failed(issue):
            markPendingRange(issue.localizedDescription)
            let failedService = appleLiveTranscription
            appleLiveTranscription = nil
            Task { await failedService?.cancel() }
            status = "Gravando somente neste Mac · transcrição Apple interrompida"
        }
    }

    private func publishAppleLiveSegment(_ text: String, startSeconds: Double, endSeconds: Double) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, startSeconds.isFinite, endSeconds.isFinite,
              endSeconds > startSeconds, var work = progressiveWork else { return }
        let startSeconds = startSeconds + captureTimeOffset
        let endSeconds = endSeconds + captureTimeOffset
        latestCapturedSeconds = max(latestCapturedSeconds, endSeconds)
        let startMilliseconds = Int64((startSeconds * 1_000).rounded())
        let endMilliseconds = Int64((endSeconds * 1_000).rounded())
        let key = "apple:\(startMilliseconds):\(endMilliseconds)"
        guard completedItems.insert(key).inserted else { return }
        work.segments.append(ConsultationTranscriptSegment(
            id: "segment_\(UUID().uuidString.lowercased())",
            revision: 1,
            range: ConsultationTimeRange(
                startSeconds: max(0, startSeconds),
                endSeconds: max(0.001, endSeconds),
                isApproximate: false
            ),
            text: normalized,
            engine: "apple/SpeechTranscriber",
            model: LocalTranscriptionService.portugueseBrazil.identifier(.bcp47),
            attemptID: work.capture.attemptID
        ))
        work.segments.sort { $0.range.startSeconds < $1.range.startSeconds }
        work.updatedAt = Date()
        progressiveWork = work
        lastTranscriptUpdate = work.updatedAt
        saveProgressiveWork()
        scheduleProgressiveSummary(force: false)
    }

    private func receiveRealtimeEvent(_ event: OpenAIRealtimeEvent, generation operationGeneration: UInt) {
        guard generation == operationGeneration else { return }
        switch event {
        case .connectionReady:
            status = isRecording ? "Gravando · aguardando fala" : status
        case let .partial(itemID, contentIndex, text):
            let key = "\(itemID):\(contentIndex)"
            partialItems[key, default: ""] += text
            partialTranscript = partialItems[key] ?? text
            lastTranscriptUpdate = Date()
            status = "Gravando · transcrição em andamento"
        case let .final(itemID, contentIndex, text):
            let key = "\(itemID):\(contentIndex)"
            guard completedItems.insert(key).inserted else { return }
            partialItems[key] = nil
            partialTranscript = partialItems.values.first ?? ""
            publishLiveSegment(text, itemKey: key)
        case let .failed(issue):
            markPendingRange(issue.localizedDescription)
            liveTranscription = nil
            status = issue.localizedDescription + " A gravação local continua."
            scheduleRealtimeReconnect(generation: operationGeneration)
        case .closed:
            if isRecording { markPendingRange(OpenAIRealtimeIssue.connectionClosed.localizedDescription) }
        }
    }

    private func publishLiveSegment(_ text: String, itemKey: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, var work = progressiveWork else { return }
        let previousEnd = max(captureTimeOffset, work.segments.last?.range.endSeconds ?? 0)
        let end = max(previousEnd + 0.001, latestCapturedSeconds)
        work.segments.append(ConsultationTranscriptSegment(
            id: "segment_\(UUID().uuidString.lowercased())",
            revision: 1,
            range: ConsultationTimeRange(
                startSeconds: previousEnd,
                endSeconds: end,
                isApproximate: true
            ),
            text: normalized,
            engine: "openai/realtime",
            model: OpenAIRealtimeTranscription.model,
            attemptID: work.capture.attemptID
        ))
        work.updatedAt = Date()
        progressiveWork = work
        lastTranscriptUpdate = work.updatedAt
        saveProgressiveWork()
        scheduleProgressiveSummary(force: false)
    }

    private func publishBatchTranscript(
        _ text: String,
        localeIdentifier: String,
        audioURL: URL,
        capturedAt: Date
    ) {
        guard var work = progressiveWork else { return }
        let duration = audioDuration(at: audioURL)
        work.capture.status = .transcribing
        work.capture.startedAt = work.capture.startedAt ?? startedAt
        work.capture.endedAt = capturedAt
        work.capture.capturedSeconds = captureTimeOffset + duration
        work.segments.append(ConsultationTranscriptSegment(
            id: "segment_\(UUID().uuidString.lowercased())",
            revision: 1,
            range: ConsultationTimeRange(startSeconds: captureTimeOffset, endSeconds: captureTimeOffset + duration, isApproximate: true),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping,
            engine: "apple/SpeechTranscriber",
            model: localeIdentifier,
            attemptID: work.capture.attemptID
        ))
        work.status = .transcribing
        work.updatedAt = capturedAt
        progressiveWork = work
        latestCapturedSeconds = captureTimeOffset + duration
        lastTranscriptUpdate = capturedAt
        saveProgressiveWork()
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.completeProgressiveWorkAfterStop(ownsSummaryTask: true)
            self.summaryTask = nil
            self.updateBusy()
        }
        updateBusy()
    }

    private func stopLiveRecording() {
        guard liveStopTask == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        status = "Completando trecho final…"
        if liveTranscription == nil && appleLiveTranscription == nil {
            markPendingRange(
                progressiveWork?.lastError
                    ?? "A transcrição ao vivo foi interrompida; o áudio local precisa de processamento posterior."
            )
        }
        setProgressiveCaptureState(.draining, endedAt: Date())
        isPaused = false
        isPauseTransitioning = false
        if progressiveConfiguration?.source == .telecall {
            liveStopTask = Task { @MainActor [weak self, telecallCapture] in
                let event = await telecallCapture.stop()
                guard let self else { return }
                await self.acceptPendingCaptureCallbacksBeforeDrain()
                await self.drainLiveTranscription(event: event ?? .failed)
            }
        } else {
            liveMicrophoneCapture.stop()
            if liveStopTask == nil {
                liveStopTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.acceptPendingCaptureCallbacksBeforeDrain()
                    await self.drainLiveTranscription(event: .finished)
                }
            }
        }
        updateBusy()
    }

    private func finishLiveCapture(_ event: EncounterLiveCaptureEvent, generation operationGeneration: UInt) {
        let mapped: EncounterMicrophoneCaptureEvent = event == .finished ? .finished : .failed
        finishLiveCapture(mapped, generation: operationGeneration)
    }

    private func finishLiveCapture(_ event: EncounterMicrophoneCaptureEvent, generation operationGeneration: UInt) {
        guard generation == operationGeneration, liveCaptureActive, liveStopTask == nil else { return }
        isPaused = false
        isPauseTransitioning = false
        liveStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.acceptPendingCaptureCallbacksBeforeDrain()
            await self.drainLiveTranscription(event: event)
        }
        updateBusy()
    }

    private func acceptPendingCaptureCallbacksBeforeDrain() async {
        // Audio callbacks copy PCM before hopping to the main actor. Yield after
        // stopping capture so copied chunks reach the transcriber before close.
        await Task.yield()
        await Task.yield()
        liveCaptureActive = false
    }

    private func drainLiveTranscription(event: EncounterMicrophoneCaptureEvent) async {
        defer { liveStopTask = nil; updateBusy() }
        if event == .failed {
            markPendingRange("A captura terminou antes de confirmar o último trecho.")
        }
        do {
            if let appleLiveTranscription {
                try await appleLiveTranscription.finish()
            } else {
                try await liveTranscription?.drainAndCommit()
                try await liveTranscription?.waitForFinalTranscripts(timeout: liveDrainDelay)
            }
        } catch is CancellationError {
            return
        } catch {
            markPendingRange(error.localizedDescription)
        }
        liveTranscription?.cancel()
        liveTranscription = nil
        if let appleLiveTranscription { await appleLiveTranscription.cancel() }
        appleLiveTranscription = nil
        microphoneState = progressiveConfiguration?.source == .microphone ? .recorded : microphoneState
        telecallState = progressiveConfiguration?.source == .telecall ? .recorded : telecallState
        microphoneLevel = 0
        callLevel = 0
        await completeProgressiveWorkAfterStop()
    }

    private func completeProgressiveWorkAfterStop(ownsSummaryTask: Bool = false) async {
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        summaryRetryNotBefore = nil
        if !ownsSummaryTask, let activeSummaryTask = summaryTask {
            activeSummaryTask.cancel()
            await activeSummaryTask.value
            summaryTask = nil
        }
        if pendingSummaryEditText != nil {
            workEditSaveTask?.cancel()
            workEditSaveTask = nil
            commitPendingSummaryEdit()
        }
        setProgressiveCaptureState(.draining, endedAt: Date())
        var summarySucceeded = true
        if let segments = progressiveWork?.segments, !segments.isEmpty {
            let covered = Set(progressiveWork?.summary?.coveredSegmentReferences ?? [])
            let sources = progressiveWork?.summaryEngine == "openai/responses" ? segments : segments.filter {
                !covered.contains(.init(segmentID: $0.id, revision: $0.revision))
            }
            for chunk in finalReviewChunks(sources) {
                guard await generateProgressiveSummary(
                    force: true,
                    finalReview: true,
                    reviewSegments: chunk
                ) else {
                    summarySucceeded = false
                    break
                }
            }
        }
        guard var work = progressiveWork else { return }
        let covered = Set(work.summary?.coveredSegmentReferences ?? [])
        let summaryComplete = work.segments.allSatisfy {
            covered.contains(.init(segmentID: $0.id, revision: $0.revision))
        }
        let complete = work.pendingRanges.isEmpty && summaryComplete && summarySucceeded
        work.capture.status = complete ? .ready : .incomplete
        work.status = complete ? .ready : .incomplete
        work.capture.endedAt = work.capture.endedAt ?? Date()
        work.updatedAt = Date()
        progressiveWork = work
        saveProgressiveWork()
        if complete {
            status = "Gravação encerrada · resumo pronto para revisão"
        } else if work.pendingRanges.isEmpty {
            status = "Transcrição salva · não foi possível concluir o resumo"
        } else {
            status = "Gravação encerrada · há trechos pendentes para revisão"
        }
    }

    private func scheduleProgressiveSummary(force: Bool) {
        guard progressiveWork?.summaryEngine == "openai/responses" else { return }
        guard summaryTask == nil, pendingSummaryEditText == nil,
              force || progressiveSummaryIntervalIsReady else { return }
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateProgressiveSummary(force: force)
            self.summaryTask = nil
            self.updateBusy()
            if self.isRecording, self.progressiveSummaryIntervalIsReady {
                self.scheduleProgressiveSummary(force: false)
            }
        }
        updateBusy()
    }

    private var progressiveSummaryIntervalIsReady: Bool {
        guard let work = progressiveWork, work.summaryEngine == "openai/responses" else { return false }
        if let summaryRetryNotBefore, Date() < summaryRetryNotBefore { return false }
        guard work.capture.capturedSeconds >= nextAutomaticSummarySecond,
              let summary = work.summary else { return false }
        let covered = Set(summary.coveredSegmentReferences)
        return work.segments.contains {
            !covered.contains(.init(segmentID: $0.id, revision: $0.revision))
        }
    }

    @discardableResult
    private func generateProgressiveSummary(
        force: Bool,
        finalReview: Bool = false,
        reviewSegments: [ConsultationTranscriptSegment]? = nil
    ) async -> Bool {
        guard var work = progressiveWork, !work.segments.isEmpty,
              let summary = work.summary, summary.acceptance == nil else { return false }
        let covered = Set(summary.coveredSegmentReferences)
        let candidates = reviewSegments ?? work.segments.filter {
            !covered.contains(.init(segmentID: $0.id, revision: $0.revision))
        }
        guard !candidates.isEmpty else { return true }
        let newSegments: [ConsultationTranscriptSegment]
        if finalReview || force {
            newSegments = candidates
        } else {
            guard work.capture.capturedSeconds >= nextAutomaticSummarySecond else { return true }
            // Advance past silent minutes instead of waiting forever at an empty boundary.
            if let first = candidates.first, first.range.startSeconds >= nextAutomaticSummarySecond {
                let interval = Double(work.summaryIntervalSeconds)
                nextAutomaticSummarySecond = (floor(first.range.startSeconds / interval) + 1) * interval
            }
            guard work.capture.capturedSeconds >= nextAutomaticSummarySecond else { return true }
            newSegments = candidates.filter { $0.range.startSeconds < nextAutomaticSummarySecond }
            guard !newSegments.isEmpty else { return true }
        }
        let newReferences = Set(newSegments.map {
            ConsultationTranscriptSegmentReference(segmentID: $0.id, revision: $0.revision)
        })
        let firstStart = newSegments.map(\.range.startSeconds).min() ?? 0
        let adjacentSegments = Array(work.segments.filter {
            !newReferences.contains(.init(segmentID: $0.id, revision: $0.revision))
                && $0.range.endSeconds <= firstStart
        }.suffix(2))
        let historicalReferences = Set(summary.items.flatMap(\.segmentReferences))
        let historicalSegments = work.segments.filter {
            historicalReferences.contains(.init(segmentID: $0.id, revision: $0.revision))
        }
        summaryIsUpdating = true
        status = "Resumo em atualização…"
        defer { summaryIsUpdating = false }
        do {
            let provider: ProgressiveSummaryProvider = work.summaryEngine == "openai/responses"
                ? .openAI : .apple
            let service = summaryServiceFactory(provider, work.summaryModel)
            let update = try await service.generateUpdate(for: ProgressiveSummaryRequest(
                baseRevision: summary.revision,
                currentItems: summary.items,
                newSegments: newSegments,
                verificationSegments: adjacentSegments,
                historicalSegments: historicalSegments,
                isFinalReview: finalReview
            ))
            guard !Task.isCancelled else { return false }
            guard let current = progressiveWork, current.sessionID == work.sessionID,
                  current.summary?.revision == summary.revision,
                  pendingSummaryEditText == nil else { return false }
            work = current
            guard var currentSummary = work.summary else { return false }
            currentSummary.items = update.items
            currentSummary.revision = update.revision.sequence
            currentSummary.revisions.append(update.revision)
            currentSummary.coveredSegmentReferences = uniqueReferences(
                currentSummary.coveredSegmentReferences + update.revision.segmentReferences
            )
            work.summary = currentSummary
            work.summaryEngine = update.revision.generation?.engine ?? work.summaryEngine
            work.updatedAt = Date()
            if work.pendingRanges.isEmpty { work.lastError = nil }
            progressiveWork = work
            saveProgressiveWork()
            status = update.revision.kind == .noChange
                ? "Nenhuma informação essencial nova neste intervalo"
                : "Resumo atualizado para revisão"
            summaryRetryWakeTask?.cancel()
            summaryRetryWakeTask = nil
            summaryRetryNotBefore = nil
            summaryRetryCount = 0
            if !finalReview {
                if force {
                    let interval = Double(work.summaryIntervalSeconds)
                    let position = max(work.capture.capturedSeconds,
                                       newSegments.map(\.range.endSeconds).max() ?? 0)
                    nextAutomaticSummarySecond = (floor(position / interval) + 1) * interval
                } else {
                    nextAutomaticSummarySecond += Double(work.summaryIntervalSeconds)
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard var current = progressiveWork else { return false }
            current.lastError = error.localizedDescription
            current.updatedAt = Date()
            progressiveWork = current
            saveProgressiveWork()
            status = error.localizedDescription
            if isRecording, !force, !finalReview {
                scheduleSummaryRetry()
            }
            return false
        }
    }

    private func scheduleSummaryRetry() {
        summaryRetryCount += 1
        guard summaryRetryCount <= 2 else {
            summaryRetryNotBefore = .distantFuture
            return
        }
        guard summaryRetryWakeTask == nil else { return }
        summaryRetryNotBefore = Date().addingTimeInterval(15)
        summaryRetryWakeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self else { return }
            self.summaryRetryWakeTask = nil
            self.summaryRetryNotBefore = nil
            if self.isRecording, self.progressiveSummaryIntervalIsReady {
                self.scheduleProgressiveSummary(force: false)
            }
        }
    }

    private func finalReviewChunks(
        _ segments: [ConsultationTranscriptSegment]
    ) -> [[ConsultationTranscriptSegment]] {
        var result: [[ConsultationTranscriptSegment]] = []
        var chunk: [ConsultationTranscriptSegment] = []
        var bytes = 0
        for segment in segments {
            let wouldExceedDuration = chunk.first.map {
                segment.range.endSeconds - $0.range.startSeconds > 180
            } ?? false
            let segmentBytes = segment.text.utf8.count
            if !chunk.isEmpty, wouldExceedDuration || bytes + segmentBytes > 8_000 {
                result.append(chunk)
                chunk = []
                bytes = 0
            }
            chunk.append(segment)
            bytes += segmentBytes
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private func setProgressiveCaptureState(
        _ state: ConsultationWorkStatus,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        guard var work = progressiveWork else { return }
        work.capture.status = state
        work.status = state
        if let startedAt { work.capture.startedAt = startedAt }
        if let endedAt { work.capture.endedAt = endedAt }
        work.capture.capturedSeconds = max(work.capture.capturedSeconds, latestCapturedSeconds)
        work.updatedAt = Date()
        progressiveWork = work
        saveProgressiveWork()
    }

    private func markPendingRange(_ message: String) {
        guard var work = progressiveWork else { return }
        let start = work.segments.last?.range.endSeconds ?? 0
        let end = max(start + 0.001, latestCapturedSeconds)
        let pending = ConsultationTimeRange(startSeconds: start, endSeconds: end, isApproximate: true)
        if let last = work.pendingRanges.indices.last,
           work.pendingRanges[last].endSeconds >= pending.startSeconds {
            work.pendingRanges[last].endSeconds = max(work.pendingRanges[last].endSeconds, pending.endSeconds)
        } else if work.pendingRanges.count < 10_000 {
            work.pendingRanges.append(pending)
        }
        work.capture.status = .incomplete
        work.status = .incomplete
        work.lastError = message
        work.updatedAt = Date()
        progressiveWork = work
        saveProgressiveWork()
    }

    private func failLiveStart(_ error: any Error, microphone: Bool) {
        liveTranscription?.cancel()
        liveTranscription = nil
        if let appleLiveTranscription {
            Task { await appleLiveTranscription.cancel() }
        }
        appleLiveTranscription = nil
        liveCaptureActive = false
        isPaused = false
        isPauseTransitioning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if microphone {
            microphoneState = .failed(error.localizedDescription)
        } else {
            telecallState = .failed(error.localizedDescription)
        }
        status = error.localizedDescription
        setProgressiveCaptureState(.failed, endedAt: Date())
        if let scopeURL, !hasUsefulAudio(at: scopeURL) { endScopeAccess() }
        updateBusy()
    }

    private func cancelLivePipeline(reason: String) {
        guard liveCaptureActive || liveTranscription != nil
            || appleLiveTranscription != nil || liveStopTask != nil else { return }
        liveCaptureActive = false
        isPaused = false
        isPauseTransitioning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        liveTranscription?.cancel()
        liveTranscription = nil
        if let appleLiveTranscription {
            Task { await appleLiveTranscription.cancel() }
        }
        appleLiveTranscription = nil
        liveMicrophoneCapture.stop()
        if progressiveConfiguration?.source == .telecall, liveStopTask == nil {
            liveStopTask = Task { @MainActor [weak self, telecallCapture] in
                _ = await telecallCapture.stop()
                guard let self else { return }
                self.liveStopTask = nil
                self.updateBusy()
            }
        }
        summaryTask?.cancel()
        summaryTask = nil
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        summaryRetryNotBefore = nil
        microphoneLevel = 0
        callLevel = 0
        microphoneState = .idle
        telecallState = .idle
        setProgressiveCaptureState(.incomplete, endedAt: Date())
        status = preservationStatus(prefix: reason)
    }

    func applyRemotePermissionChanges(liveTranscriptionAllowed: Bool) {
        lastObservedLiveTranscriptionAllowed = liveTranscriptionAllowed
        guard liveCaptureActive,
              progressiveConfiguration?.transcriptionMode == .openAILive,
              !liveTranscriptionAllowed else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        liveTranscription?.cancel()
        liveTranscription = nil
        markPendingRange(
            "O envio de áudio foi desativado. A gravação local continua e este trecho precisa de processamento posterior."
        )
        status = "Gravando somente neste Mac · envio de áudio desativado"
    }

    private func scheduleRealtimeReconnect(generation operationGeneration: UInt) {
        guard liveCaptureActive, reconnectTask == nil, reconnectAttempts < 3 else {
            if liveCaptureActive, reconnectAttempts >= 3 {
                status = "Gravando somente neste Mac · transcrição ao vivo indisponível"
            }
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let delay = realtimeReconnectDelay(attempt)
        status = "Gravando neste Mac · tentando reconectar a transcrição (\(attempt)/3)"
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard self.generation == operationGeneration, self.liveCaptureActive else { return }
                let configuration = try self.liveTranscriptionConfiguration()
                guard configuration.model == OpenAIRealtimeTranscription.model else {
                    throw AITextSettingsIssue.changed
                }
                let service = self.makeRealtimeTranscription(generation: operationGeneration)
                try await service.connect(apiKey: configuration.apiKey)
                try Task.checkCancellation()
                guard self.generation == operationGeneration, self.liveCaptureActive else {
                    service.cancel()
                    return
                }
                self.liveTranscription = service
                self.reconnectTask = nil
                self.status = "Gravando · transcrição reconectada"
            } catch is CancellationError {
                self.reconnectTask = nil
            } catch {
                guard self.generation == operationGeneration, self.liveCaptureActive else {
                    self.reconnectTask = nil
                    return
                }
                self.reconnectTask = nil
                self.markPendingRange(error.localizedDescription)
                self.scheduleRealtimeReconnect(generation: operationGeneration)
            }
        }
    }

    private func audioDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return max(1, startedAt.map { Date().timeIntervalSince($0) } ?? 1)
        }
        return max(0.001, Double(file.length) / file.fileFormat.sampleRate)
    }

    private func updateBusy(transcriptionActive: Bool? = nil) {
        let activeTranscription = transcriptionActive ?? (transcriptionTask != nil)
        isBusy = activeTranscription
            || transcriptionCleanupTask != nil
            || microphoneState == .requestingPermission
            || microphoneState == .recording
            || telecallState == .requestingPermission
            || telecallState == .recording
            || telecallStartInFlight
            || telecallCleanupTask != nil
            || liveStopTask != nil
            || summaryTask != nil
    }

    private func beginScopeAccess(to url: URL, authorizationURL: URL? = nil) {
        if scopeURL?.standardizedFileURL == url.standardizedFileURL {
            if !scopeAccessGranted {
                scopeAccessGranted = (scopeAccessURL ?? url).startAccessingSecurityScopedResource()
            }
            return
        }
        endScopeAccess()
        scopeURL = url
        scopeAccessURL = authorizationURL ?? url
        scopeAccessGranted = (scopeAccessURL ?? url).startAccessingSecurityScopedResource()
    }

    private func endScopeAccess() {
        if scopeAccessGranted, let scopeAccessURL {
            scopeAccessURL.stopAccessingSecurityScopedResource()
        }
        scopeAccessGranted = false
        scopeURL = nil
        scopeAccessURL = nil
    }

    private func clearForNextSession() {
        generation &+= 1
        workEditSaveTask?.cancel()
        workEditSaveTask = nil
        pendingSummaryEditText = nil
        pendingSummaryEditBaseText = nil
        pendingSummaryEditBaseRevision = nil
        cancelLivePipeline(reason: "Sessão encerrada.")
        acceptsRecordedAudio = false
        cancelTranscriptionAndTrackCleanup()
        microphone.reset()
        telecallURL = nil
        telecallState = .idle
        pendingTelecallEvent = nil
        endScopeAccess()
        binding = nil
        transcript = nil
        identity = nil
        savedAt = nil
        saved = false
        recovered = false
        startedAt = nil
        persist = nil
        loadWork = nil
        persistWork = nil
        persistedWorkData = nil
        progressiveConfiguration = nil
        progressiveWork = nil
        liveCaptureActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        partialTranscript = ""
        partialItems = [:]
        completedItems = []
        microphoneLevel = 0
        callLevel = 0
        lastTranscriptUpdate = nil
        progressiveSaveStatus = ""
        summaryIsUpdating = false
        summaryRetryWakeTask?.cancel()
        summaryRetryWakeTask = nil
        summaryRetryNotBefore = nil
        summaryRetryCount = 0
        nextAutomaticSummarySecond = 60
        latestCapturedSeconds = 0
        captureTimeOffset = 0
        validateCapture = nil
        microphoneState = microphone.state
        updateBusy()
    }

    private func preservationStatus(prefix: String) -> String {
        if hasUnsavedText {
            return prefix + " O texto permanece disponível para recuperação."
        }
        if microphone.recordedURL != nil || telecallURL != nil || scopeURL != nil {
            return prefix + " O áudio permanece no destino escolhido."
        }
        return prefix
    }

    private func cancelTranscriptionAndTrackCleanup() {
        guard transcriptionCleanupTask == nil, let activeTask = transcriptionTask else { return }
        activeTask.cancel()
        transcriptionTask = nil
        transcriptionCleanupTask = Task { [weak self] in
            await activeTask.value
            guard let self else { return }
            self.transcriptionCleanupTask = nil
            switch self.scopeReleaseAfterTranscriptionCleanup {
            case .clearURL:
                self.scopeReleaseAfterTranscriptionCleanup = nil
                self.endScopeAccess()
            case .preserveURL:
                self.scopeReleaseAfterTranscriptionCleanup = nil
                self.releaseScopeAccessPreservingURL()
            case nil:
                break
            }
            self.updateBusy()
        }
        updateBusy()
    }

    nonisolated private static func audioHash(_ url: URL) throws -> String {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 128 * 1_024 * 1_024 else {
            throw LocalTranscriptionIssue.invalidAudioFile
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cancelTelecallStart(generation operationGeneration: UInt) {
        guard generation == operationGeneration else { return }
        generation &+= 1
        transcribeTelecallAfterCleanup = false
        telecallCleanupStatus = "Operação cancelada."
        status = preservationStatus(prefix: "Operação cancelada.")
        beginTelecallCleanup()
    }

    private func resolvePendingTelecallEvent(
        generation operationGeneration: UInt,
        at url: URL
    ) async -> Bool {
        guard generation == operationGeneration, let pendingTelecallEvent else { return false }
        self.pendingTelecallEvent = nil
        switch pendingTelecallEvent {
        case .finished:
            telecallStartInFlight = false
            telecallState = .recorded
            status = "Gravação encerrada. O áudio foi preservado no destino escolhido."
            updateBusy()
            beginTranscription(at: url)
        case .failed:
            _ = await telecallCapture.stop()
            guard generation == operationGeneration else { return true }
            let message = "A gravação da telechamada foi interrompida. O áudio disponível foi preservado no destino escolhido."
            telecallState = .failed(message)
            status = message
            finishTelecallScopeAfterFailure()
            updateBusy()
        }
        return true
    }

    private func beginTelecallCleanup() {
        guard telecallCleanupTask == nil else {
            updateBusy()
            return
        }
        telecallCleanupTask = Task { [weak self, telecallCapture] in
            let event = await telecallCapture.stop()
            guard let self else { return }
            self.finishTelecallCleanup(event: event)
        }
        updateBusy()
    }

    private func finishTelecallCleanup(event: EncounterMicrophoneCaptureEvent?) {
        telecallCleanupTask = nil
        let shouldTranscribe = transcribeTelecallAfterCleanup
        transcribeTelecallAfterCleanup = false
        if shouldTranscribe, event == .finished {
            telecallState = .recorded
            status = preservationStatus(prefix: telecallCleanupStatus)
        } else if shouldTranscribe {
            let message = "A gravação da telechamada foi interrompida. O áudio disponível foi preservado no destino escolhido."
            telecallState = .failed(message)
            status = message
        } else {
            telecallState = .idle
            status = preservationStatus(prefix: telecallCleanupStatus)
        }
        if !hasUsefulTelecallAudio() {
            telecallURL = nil
            endScopeAccess()
        } else {
            releaseScopeAccessPreservingURL()
        }
        updateBusy()
        if shouldTranscribe, event == .finished, let telecallURL {
            beginTranscription(at: telecallURL)
        }
    }

    private func receiveTelecall(
        _ event: EncounterMicrophoneCaptureEvent,
        at url: URL,
        generation operationGeneration: UInt
    ) {
        guard generation == operationGeneration,
              telecallState == .recording || telecallState == .requestingPermission,
              telecallURL?.standardizedFileURL == url.standardizedFileURL else { return }
        if telecallStartInFlight {
            pendingTelecallEvent = event
            return
        }
        switch event {
        case .finished:
            telecallState = .recorded
            status = "Gravação encerrada. O áudio foi preservado no destino escolhido."
            updateBusy()
            if telecallCleanupTask == nil, !telecallStartInFlight {
                beginTranscription(at: url)
            }
        case .failed:
            let message = "A gravação da telechamada foi interrompida. O áudio disponível foi preservado no destino escolhido."
            telecallState = .failed(message)
            status = message
            if telecallCleanupTask == nil {
                finishTelecallScopeAfterFailure()
            }
            updateBusy()
        }
    }

    private func validateNewTelecallDestination(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "wav" else {
            throw EncounterTelecallSessionIssue.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EncounterTelecallSessionIssue.destinationExists
        }
    }

    private func failTelecall(_ error: any Error) {
        let message = error.localizedDescription
        telecallState = .failed(message)
        status = message
        updateBusy()
    }

    private func hasUsefulTelecallAudio() -> Bool {
        guard let telecallURL else { return false }
        return hasUsefulAudio(at: telecallURL, minimumSize: 44)
    }

    private func hasUsefulAudio(at url: URL, minimumSize: Int = 0) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return false }
        return size > minimumSize
    }

    private func finishTelecallScopeAfterFailure() {
        if hasUsefulTelecallAudio() {
            releaseScopeAccessPreservingURL()
        } else {
            telecallURL = nil
            endScopeAccess()
        }
    }

    private func releaseScopeAccessPreservingURL() {
        if scopeAccessGranted, let scopeAccessURL {
            scopeAccessURL.stopAccessingSecurityScopedResource()
        }
        scopeAccessGranted = false
    }
}
