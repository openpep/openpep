// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor
@Suite("TELECALL-AUDIO-001 encounter session integration")
struct EncounterTelecallSessionTests {
    private let application = TeleconsultAudioApplication(
        name: "FaceTime sintético",
        bundleIdentifier: "com.apple.FaceTime",
        processIdentifier: 42
    )

    @Test("lists applications and validates consent and a new WAV destination")
    func validatesPreparation() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        let session = makeSession(capture: capture)
        #expect(try await session.availableTelecallApplications() == [application])
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))

        await session.startTelecallRecording(
            at: destination(extension: "wav"),
            application: application,
            consent: false
        )
        #expect(capture.startCount == 0)
        #expect(session.telecallState == .failed(
            EncounterTelecallSessionIssue.consentRequired.localizedDescription
        ))

        await session.startTelecallRecording(
            at: destination(extension: "m4a"),
            application: application,
            consent: true
        )
        #expect(capture.startCount == 0)
        #expect(session.telecallState == .failed(
            EncounterTelecallSessionIssue.invalidDestination.localizedDescription
        ))

        let existingURL = destination(extension: "wav")
        try Data("conteúdo existente".utf8).write(to: existingURL, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: existingURL) }
        await session.startTelecallRecording(
            at: existingURL,
            application: application,
            consent: true
        )
        #expect(capture.startCount == 0)
        #expect(session.telecallState == .failed(
            EncounterTelecallSessionIssue.destinationExists.localizedDescription
        ))
    }

    @Test("backend selection failure clears an unusable destination and permits retry")
    func backendFailurePermitsRetry() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.startError = EncounterTelecallRecordingIssue.selectedApplicationUnavailable
        let session = makeSession(capture: capture)
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        let failedURL = destination(extension: "wav")

        await session.startTelecallRecording(
            at: failedURL,
            application: application,
            consent: true
        )

        #expect(session.scopeURL == nil)
        #expect(!session.isBusy)
        #expect(session.status.contains("não está mais disponível"))

        capture.startError = nil
        let retryURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: retryURL) }
        await session.startTelecallRecording(
            at: retryURL,
            application: application,
            consent: true
        )
        #expect(session.telecallState == .recording)
        session.cancel()
        await waitUntil { !session.isBusy }
    }

    @Test("normal stop waits for finalization and persists against the original encounter")
    func stopFinalizesBeforeTranscriptionAndKeepsOrigin() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.suspendStop = true
        let engine = SessionTelecallTranscriptionEngine(transcript: "Relato sintético da chamada.")
        let session = makeSession(capture: capture, engine: engine)
        let original = binding()
        let another = binding(encounterID: "enc_0198f5c2-9999-7333-8444-999999999999")
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persisted: EncounterTranscriptInput?
        #expect(session.prepare(binding: original, onPersist: { input, _, _ in persisted = input }))
        await session.startTelecallRecording(at: audioURL, application: application, consent: true)

        #expect(session.isRecording)
        session.stop()
        session.stop()
        await waitUntil { capture.stopCount == 1 }
        #expect(session.isBusy)
        #expect(await engine.transcriptionCount == 0)
        #expect(!session.prepare(binding: another, onPersist: { _, _, _ in }))
        #expect(session.binding == original)

        capture.finishStop(with: .finished)
        await waitUntil { session.saved }
        #expect(persisted?.text == "Relato sintético da chamada.")
        #expect(session.binding == original)
        #expect(session.scopeURL == audioURL)
    }

    @Test("live telecall does not expose the microphone pause operation")
    func liveTelecallCannotPause() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        let apple = SessionAppleLiveTranscription()
        let session = EncounterTranscriptionSession(
            telecallCapture: capture,
            appleLiveFactory: { handler in
                apple.eventHandler = handler
                return apple
            }
        )
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        session.configureProgressive(.init(
            source: .telecall,
            transcriptionMode: .appleLive,
            summaryIntervalSeconds: 60,
            summaryProvider: .apple,
            summaryModel: nil
        ))

        await session.startTelecallRecording(at: audioURL, application: application, consent: true)

        #expect(session.isRecording)
        #expect(!session.canPauseLiveCapture)
        session.togglePause()
        await Task.yield()
        #expect(!session.isPaused)
        #expect(!session.isPauseTransitioning)

        session.stop()
        await waitUntil { !session.isBusy }
    }

    @Test("a failed stop preserves partial audio and never transcribes")
    func failedStopPreservesRecoveryAudio() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.stopResult = .failed
        let engine = SessionTelecallTranscriptionEngine(transcript: "Não deve ser usado.")
        let session = makeSession(capture: capture, engine: engine)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persistenceCount = 0
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in persistenceCount += 1 }))
        await session.startTelecallRecording(at: audioURL, application: application, consent: true)

        session.stop()
        await waitUntil { !session.isBusy }

        #expect(session.scopeURL == audioURL)
        #expect(session.telecallState == .failed(session.status))
        #expect(await engine.transcriptionCount == 0)
        #expect(persistenceCount == 0)
    }

    @Test(
        "a terminal callback during startup is resolved after startup exits",
        arguments: [EncounterMicrophoneCaptureEvent.finished, .failed]
    )
    func terminalCallbackDuringStartup(event: EncounterMicrophoneCaptureEvent) async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.eventDuringStart = event
        let engine = SessionTelecallTranscriptionEngine(transcript: "Relato terminal sintético.")
        let session = makeSession(capture: capture, engine: engine)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persistenceCount = 0
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in persistenceCount += 1 }))

        await session.startTelecallRecording(at: audioURL, application: application, consent: true)
        if event == .finished {
            await waitUntil { session.saved }
            #expect(persistenceCount == 1)
        } else {
            await waitUntil { !session.isBusy }
            #expect(session.telecallState == .failed(session.status))
            #expect(session.scopeURL == audioURL)
            #expect(await engine.transcriptionCount == 0)
            #expect(persistenceCount == 0)
        }
    }

    @Test(
        "cancellation during startup stops a capture that appears after the first cleanup",
        arguments: [true, false]
    )
    func cancellationDuringStartupStopsLateCapture(cancelStartTask: Bool) async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.suspendStart = true
        let session = makeSession(capture: capture)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        let startTask = Task {
            await session.startTelecallRecording(at: audioURL, application: application, consent: true)
        }
        await waitUntil { session.isStartingRecording }

        if cancelStartTask {
            startTask.cancel()
        } else {
            session.cancel()
        }
        await startTask.value
        await waitUntil { !session.isBusy }

        #expect(capture.stopCount >= 2)
        #expect(!capture.isActive)
        #expect(session.transcript == nil)
    }

    @Test("cancel and shutdown keep the session busy until recording cleanup completes")
    func recordingCleanupBlocksAnotherSession() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.suspendStop = true
        let session = makeSession(capture: capture)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        await session.startTelecallRecording(at: audioURL, application: application, consent: true)

        session.cancel()
        await waitUntil { capture.stopCount == 1 }
        #expect(session.isBusy)
        #expect(!session.reset())
        session.shutdown()
        #expect(session.isBusy)

        capture.finishStop(with: .finished)
        await waitUntil { !session.isBusy }
        #expect(session.transcript == nil)
        #expect(session.binding != nil)
        #expect(session.scopeURL == audioURL)

        capture.emit(.finished)
        await Task.yield()
        #expect(session.transcript == nil)
    }

    @Test("cancel after stop suppresses automatic transcription")
    func cancelDuringStopSuppressesTranscription() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        capture.suspendStop = true
        let engine = SessionTelecallTranscriptionEngine(transcript: "Não deve aparecer.")
        let session = makeSession(capture: capture, engine: engine)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        await session.startTelecallRecording(at: audioURL, application: application, consent: true)

        session.stop()
        await waitUntil { capture.stopCount == 1 }
        session.cancel()
        capture.finishStop(with: .finished)
        await waitUntil { !session.isBusy }

        #expect(await engine.transcriptionCount == 0)
        #expect(session.transcript == nil)
        #expect(session.scopeURL == audioURL)
    }

    @Test("cancelled transcription remains busy until its engine has cleaned up")
    func cancellationDuringProcessingBlocksNewCapture() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        let engine = SessionTelecallTranscriptionEngine(
            transcript: "Não deve persistir.",
            suspendCancellationCleanup: true
        )
        let session = makeSession(capture: capture, engine: engine)
        let audioURL = destination(extension: "wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persistenceCount = 0
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in persistenceCount += 1 }))
        await session.startTelecallRecording(at: audioURL, application: application, consent: true)
        session.stop()
        await waitUntilAsync { await engine.transcriptionCount == 1 }

        session.cancel()
        #expect(session.isBusy)
        let otherURL = destination(extension: "wav")
        await session.startTelecallRecording(at: otherURL, application: application, consent: true)
        #expect(capture.startCount == 1)

        await waitUntilAsync { await engine.cancellationCleanupStarted }
        await engine.finishCancellationCleanup()
        await waitUntil { !session.isBusy }
        #expect(persistenceCount == 0)
        #expect(session.transcript == nil)
    }

    @Test("shutdown keeps an imported audio scope until transcription cleanup completes")
    func shutdownWaitsBeforeReleasingImportedAudio() async throws {
        let capture = SessionTelecallCapture(applications: [application])
        let engine = SessionTelecallTranscriptionEngine(
            transcript: "Não deve persistir.",
            suspendCancellationCleanup: true
        )
        let session = makeSession(capture: capture, engine: engine)
        let audioURL = destination(extension: "wav")
        try Data(repeating: 1, count: 128).write(to: audioURL, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in }))
        session.transcribe(url: audioURL)
        await waitUntilAsync { await engine.transcriptionCount == 1 }

        session.shutdown()
        #expect(session.isBusy)
        #expect(session.scopeURL == audioURL)

        await waitUntilAsync { await engine.cancellationCleanupStarted }
        await engine.finishCancellationCleanup()
        await waitUntil { !session.isBusy }
        #expect(session.scopeURL == nil)
        #expect(session.transcript == nil)
    }

    private func makeSession(
        capture: SessionTelecallCapture,
        engine: SessionTelecallTranscriptionEngine = SessionTelecallTranscriptionEngine()
    ) -> EncounterTranscriptionSession {
        EncounterTranscriptionSession(
            telecallCapture: capture,
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
    }

    private func binding(
        encounterID: String = "enc_0198f5c2-0d8f-7333-8444-0e4390d41a22"
    ) -> EncounterTranscriptionBinding {
        EncounterTranscriptionBinding(
            vaultURL: URL(fileURLWithPath: "/tmp/openpep-synthetic-vault"),
            vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
            patientID: "pat_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22",
            encounterID: encounterID,
            patientName: "Paciente Sintético"
        )
    }

    private func destination(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "openpep-telecall-session-\(UUID().uuidString.lowercased()).\(pathExtension)"
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<4_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("A condição sintética não foi alcançada no limite do teste")
    }

    private func waitUntilAsync(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<4_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("A condição assíncrona não foi alcançada no limite do teste")
    }
}

@MainActor
private final class SessionTelecallCapture: EncounterTelecallLiveCapturing {
    let applications: [TeleconsultAudioApplication]
    var startError: (any Error)?
    var suspendStart = false
    var suspendStop = false
    var eventDuringStart: EncounterMicrophoneCaptureEvent?
    var stopResult: EncounterMicrophoneCaptureEvent? = .finished
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false

    private var eventHandler: (@Sendable (EncounterMicrophoneCaptureEvent) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<EncounterMicrophoneCaptureEvent?, Never>?

    init(applications: [TeleconsultAudioApplication]) {
        self.applications = applications
    }

    func availableApplications() async throws -> [TeleconsultAudioApplication] { applications }

    func start(
        at url: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws {
        startCount += 1
        if let startError { throw startError }
        self.eventHandler = eventHandler
        try Data(repeating: 1, count: 128).write(to: url, options: .withoutOverwriting)
        if let eventDuringStart {
            eventHandler(eventDuringStart)
            await Task.yield()
            throw CancellationError()
        }
        if suspendStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        isActive = true
    }

    func stop() async -> EncounterMicrophoneCaptureEvent? {
        stopCount += 1
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume()
            return nil
        }
        if suspendStop {
            return await withCheckedContinuation { stopContinuation = $0 }
        }
        isActive = false
        return stopResult
    }

    func startLive(
        at url: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        stableChunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws {
        try await start(
            at: url,
            application: application,
            maximumDuration: maximumDuration,
            eventHandler: eventHandler
        )
    }

    func finishStop(with event: EncounterMicrophoneCaptureEvent?) {
        isActive = false
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(returning: event)
    }

    func emit(_ event: EncounterMicrophoneCaptureEvent) {
        eventHandler?(event)
    }
}

@MainActor
private final class SessionAppleLiveTranscription: AppleLiveTranscribing {
    var eventHandler: (@MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void)?

    func start(locale: Locale) async throws {}
    func enqueue(_ chunk: EncounterAudioChunk) -> Bool { true }
    func finish() async throws {}
    func cancel() async {}
}

private actor SessionTelecallTranscriptionEngine: LocalTranscriptionEngine {
    let transcript: String
    let suspendCancellationCleanup: Bool
    private(set) var transcriptionCount = 0
    private(set) var cancellationCleanupStarted = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    init(transcript: String = "Texto sintético.", suspendCancellationCleanup: Bool = false) {
        self.transcript = transcript
        self.suspendCancellationCleanup = suspendCancellationCleanup
    }

    func availability(for locale: Locale) async -> LocalTranscriptionAvailability {
        .ready(localeIdentifier: "pt-BR")
    }

    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String {
        transcriptionCount += 1
        guard suspendCancellationCleanup else { return transcript }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancellationCleanupStarted = true
            await withCheckedContinuation { cancellationContinuation = $0 }
            throw CancellationError()
        }
        return transcript
    }

    func cancel(operationID: UUID) {}

    func finishCancellationCleanup() {
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        continuation?.resume()
    }
}
