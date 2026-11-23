// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import AVFoundation
import Observation
import SwiftUI

enum AssistantVoiceIssue: LocalizedError {
    case permission, occupied, failed, tooLong
    var errorDescription: String? {
        switch self {
        case .permission: "Prepare a voz em Assistência de IA. Se o microfone estiver bloqueado, libere o OpenPEP em Ajustes do Sistema > Privacidade e Segurança > Microfone."
        case .occupied: "A captura da consulta está em uso. Escreva o pedido no assistente."
        case .failed: "Não foi possível concluir o comando por voz. Nenhum pedido foi enviado."
        case .tooLong: "O comando ultrapassou 4.000 caracteres. Reduza o pedido antes de interpretar."
        }
    }
}

@MainActor protocol AssistantMicrophoneCapturing: AnyObject {
    var isAuthorized: Bool { get }
    func start() throws -> AsyncThrowingStream<EncounterAudioChunk, any Error>
    func stop()
}

/// PCM exists only in bounded memory. This capture has no file destination.
@MainActor final class AssistantMicrophoneCapture: AssistantMicrophoneCapturing {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<EncounterAudioChunk, any Error>.Continuation?
    var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() throws -> AsyncThrowingStream<EncounterAudioChunk, any Error> {
        guard engine == nil, isAuthorized else { throw AssistantVoiceIssue.permission }
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.channelCount > 0, !format.isInterleaved else {
            throw EncounterLiveAudioIssue.invalidAudioFormat
        }
        let (stream, continuation) = AsyncThrowingStream<EncounterAudioChunk, any Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        input.installTap(onBus: 0, bufferSize: 2_400, format: format) { @Sendable buffer, _ in
            do {
                let pcm = try AppleEncounterLiveMicrophoneCapture.monoPCM16(from: buffer)
                let chunk = try EncounterAudioChunk(pcm16: pcm, samplePosition: 0,
                    monotonicTime: ProcessInfo.processInfo.systemUptime,
                    format: EncounterAudioFormat(sampleRate: Int(buffer.format.sampleRate.rounded()), channelCount: 1),
                    source: .microphone, level: 0)
                switch continuation.yield(chunk) {
                case .enqueued: break
                case .dropped: continuation.finish(throwing: AssistantVoiceIssue.failed)
                case .terminated: break
                @unknown default: continuation.finish(throwing: AssistantVoiceIssue.failed)
                }
            } catch { continuation.finish(throwing: AssistantVoiceIssue.failed) }
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); continuation.finish(); throw AssistantVoiceIssue.failed
        }
        self.engine = engine; self.continuation = continuation
        return stream
    }
    func stop() {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        engine = nil; continuation?.finish(); continuation = nil
    }
}

@MainActor @Observable final class AssistantVoiceSession {
    enum State { case idle, preparing, listening, finishing }
    private(set) var state: State = .idle
    private(set) var preview = ""
    private(set) var message: String?
    var isActive: Bool { state != .idle }
    static let maximumDuration: Duration = .seconds(60)
    private static weak var activeSession: AssistantVoiceSession?
    private static let clinicalSessions = NSHashTable<EncounterTranscriptionSession>.weakObjects()
    static func observeClinical(_ session: EncounterTranscriptionSession) { clinicalSessions.add(session) }
    static func suspendForClinicalCapture() {
        guard let activeSession else { return }
        activeSession.cancel()
        activeSession.message = AssistantVoiceIssue.occupied.localizedDescription
    }
    static var clinicalCaptureActive: Bool {
        clinicalSessions.allObjects.contains { $0.isRecording || $0.isStartingRecording || $0.isPaused }
    }

    typealias RecognizerFactory = (@escaping @MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void) -> any AppleLiveTranscribing
    private let capture: any AssistantMicrophoneCapturing
    private let factory: RecognizerFactory
    private let duration: Duration
    private var recognizer: (any AppleLiveTranscribing)?
    private var operation: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var basePrompt = ""
    private var finalParts: [String] = []
    private var onReady: ((String, Bool) -> Void)?
    private var permitted: (() -> Bool)?

    init(capture: any AssistantMicrophoneCapturing = AssistantMicrophoneCapture(),
         maximumDuration: Duration = AssistantVoiceSession.maximumDuration,
         factory: @escaping RecognizerFactory = { AppleLiveTranscription(eventHandler: $0) }) {
        self.capture = capture; self.factory = factory; duration = maximumDuration
    }

    func start(basePrompt: String, permitted: @escaping () -> Bool, onReady: @escaping (String, Bool) -> Void) {
        guard !isActive else { return }
        guard Self.activeSession == nil, permitted() else { message = AssistantVoiceIssue.occupied.localizedDescription; return }
        guard capture.isAuthorized else { message = AssistantVoiceIssue.permission.localizedDescription; return }
        cancel()
        Self.activeSession = self
        let id = generation
        self.basePrompt = basePrompt; self.preview = basePrompt
        self.permitted = permitted; self.onReady = onReady
        state = .preparing; message = nil
        let recognizer = factory { [weak self] event in self?.receive(event, id: id) }
        self.recognizer = recognizer
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.start(locale: LocalTranscriptionService.portugueseBrazil)
                guard self.generation == id, !Task.isCancelled else { await recognizer.cancel(); return }
                guard permitted() else { throw AssistantVoiceIssue.occupied }
                let stream = try self.capture.start()
                self.state = .listening
                self.audioTask = Task { [weak self] in
                    var position: Int64 = 0
                    do {
                        for try await chunk in stream {
                            guard let self, self.generation == id, !Task.isCancelled else { return }
                            guard permitted() else { throw AssistantVoiceIssue.occupied }
                            let timed = try EncounterAudioChunk(pcm16: chunk.pcm16, samplePosition: position,
                                monotonicTime: chunk.monotonicTime, format: chunk.format, source: .microphone, level: chunk.level)
                            position += Int64(timed.frameCount)
                            guard recognizer.enqueue(timed) else { throw AssistantVoiceIssue.failed }
                        }
                    } catch { self?.fail(error, id: id) }
                }
                self.timer = Task { [weak self] in
                    do { try await Task.sleep(for: self?.duration ?? .seconds(60)) } catch { return }
                    guard let self, self.generation == id else { return }
                    self.finish(interpret: false)
                }
            } catch { self.fail(error, id: id) }
        }
    }

    func finish(interpret: Bool) {
        guard state == .listening, let recognizer else { return }
        let id = generation
        state = .finishing; timer?.cancel(); timer = nil
        capture.stop()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await self.audioTask?.value
                guard self.generation == id, !Task.isCancelled else { return }
                try await recognizer.finish()
                guard self.generation == id, !Task.isCancelled else { return }
                guard self.permitted?() == true else { throw AssistantVoiceIssue.occupied }
                let spoken = self.finalParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else { throw AssistantVoiceIssue.failed }
                let text = self.combine(spoken)
                guard text.count <= 4_000 else { throw AssistantVoiceIssue.tooLong }
                let ready = self.onReady
                self.cancel()
                if !interpret { self.message = "Limite de um minuto atingido. Revise o pedido e clique em Interpretar." }
                ready?(text, interpret)
            } catch { self.fail(error, id: id) }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil; timer?.cancel(); timer = nil
        capture.stop(); audioTask?.cancel(); audioTask = nil
        let old = recognizer; recognizer = nil
        Task { await old?.cancel() }
        if Self.activeSession === self { Self.activeSession = nil }
        state = .idle; preview = ""; finalParts = []; basePrompt = ""; onReady = nil; permitted = nil; message = nil
    }

    private func receive(_ event: AppleLiveTranscriptionEvent, id: UUID) {
        guard generation == id, isActive else { return }
        switch event {
        case let .final(text, _, _): finalParts.append(text)
        case let .partial(text): preview = combine((finalParts + [text]).joined(separator: " "))
        case let .failed(issue): fail(issue, id: id); return
        }
        if case .final = event { preview = combine(finalParts.joined(separator: " ")) }
        if preview.count > 4_000 { fail(AssistantVoiceIssue.tooLong, id: id) }
    }
    private func combine(_ text: String) -> String {
        [basePrompt, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func fail(_ error: any Error, id: UUID) {
        guard generation == id else { return }
        cancel(); message = error.localizedDescription
    }
}

struct AssistantVoiceSettingsView: View {
    @AppStorage(AITextSettings.assistantVoiceEnabledKey) private var enabled = false
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Voz no assistente · reconhecimento Apple", isOn: $enabled)
            Text("O áudio do comando é processado neste Mac, sem arquivo de gravação. Ao concluir e interpretar, o texto reconhecido é enviado à OpenAI. Silêncio não dispara comandos.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preparar voz e autorizar microfone") { prepare() }.disabled(task != nil)
                if task != nil { ProgressView().controlSize(.small); Button("Cancelar") { task?.cancel() } }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear { task?.cancel() }
        .onChange(of: enabled) { _, allowed in if !allowed { task?.cancel() } }
    }
    private func prepare() {
        guard task == nil else { return }
        message = "Preparando reconhecimento em português…"
        task = Task { @MainActor in
            defer { task = nil }
            let recognizer = AppleLiveTranscription { _ in }
            do {
                guard !AssistantVoiceSession.clinicalCaptureActive else { throw AssistantVoiceIssue.occupied }
                let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    ? true : await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard granted else { throw AssistantVoiceIssue.permission }
                try await recognizer.start(locale: LocalTranscriptionService.portugueseBrazil)
                await recognizer.cancel()
                try Task.checkCancellation()
                enabled = true; message = "Voz preparada. Abra o assistente para falar um comando."
            } catch {
                await recognizer.cancel()
                message = error is CancellationError ? "Preparação cancelada." : error.localizedDescription
            }
        }
    }
}
