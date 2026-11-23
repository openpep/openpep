// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor
@Suite("TRANSCRIPTION-004 durable encounter transcription session")
struct EncounterTranscriptionSessionTests {
    @Test("closing the sheet keeps recording and automatically persists after stop")
    func dismissalKeepsRecordingAndAutomaticallyTranscribes() async throws {
        let capture = SessionMicrophoneCapture()
        let microphone = EncounterMicrophoneRecordingModel(capture: capture)
        let engine = SessionTranscriptionEngine(transcript: "Relato sintético contínuo.")
        let session = EncounterTranscriptionSession(
            microphone: microphone,
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
        let audioURL = destination()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persisted: EncounterTranscriptInput?

        #expect(session.prepare(binding: binding(), onPersist: { input, _, _ in persisted = input }))
        await session.startRecording(at: audioURL, consent: true)
        #expect(session.microphoneState == .recording)
        #expect(session.isBusy)
        #expect(session.startedAt != nil)
        #expect(session.status.contains("Gravando"))
        #expect(session.dismiss())
        #expect(capture.stopCount == 0)

        session.stop()
        capture.finish(.finished)
        await waitUntil { session.saved }

        #expect(session.transcript?.text == "Relato sintético contínuo.")
        #expect(persisted == session.transcript)
        #expect(!session.isBusy)
        #expect(try Data(contentsOf: audioURL) == Data("áudio sintético".utf8))
    }

    @Test("Apple after-recording mode appends another take without replacing saved transcript")
    func resumesAfterRecordingMode() async throws {
        let capture = SessionMicrophoneCapture()
        let microphone = EncounterMicrophoneRecordingModel(capture: capture)
        let engine = SessionTranscriptionEngine(transcript: "Refere sono melhor.")
        let session = EncounterTranscriptionSession(microphone: microphone,
            transcriptionService: LocalTranscriptionService(engine: engine),
            summaryServiceFactory: { _, _ in
                ProgressiveConsultationSummaryService(generator: SessionSummaryGenerator())
            })
        let firstURL = destination()
        let secondURL = destination()
        defer {
            session.shutdown()
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        var inputs: [EncounterTranscriptInput] = []
        #expect(session.prepare(binding: binding(), onPersist: { input, _, _ in inputs.append(input) }))
        session.configureProgressive(.init(source: .microphone, transcriptionMode: .appleAfterRecording,
            summaryIntervalSeconds: 60, summaryProvider: .apple, summaryModel: nil))
        await session.startRecording(at: firstURL, consent: true)
        session.stop()
        capture.finish(.finished)
        await waitUntil { session.saved && !session.isBusy }
        let first = try #require(session.progressiveWork?.segments.first)
        #expect(inputs.count == 1)
        await session.startRecording(at: secondURL, consent: true)
        #expect(session.isRecording)
        session.stop()
        capture.finish(.finished)
        await waitUntil { session.saved && !session.isBusy }
        #expect(inputs.count == 2)
        #expect(session.progressiveWork?.segments.count == 2)
        #expect(session.progressiveWork?.segments.first == first)
        #expect(session.progressiveWork?.segments.last?.range.startSeconds == first.range.endSeconds)
        #expect(session.progressiveWork?.capture.audioFilenames == [firstURL.lastPathComponent, secondURL.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @Test("unsaved text keeps its original binding until a recovery copy is marked")
    func pendingTextGuardsBindingUntilRecovered() async throws {
        let engine = SessionTranscriptionEngine(transcript: "Texto sintético recuperável.")
        let session = EncounterTranscriptionSession(
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
        let firstBinding = binding(encounterID: "enc_0198f5c2-1111-7333-8444-111111111111")
        let secondBinding = binding(encounterID: "enc_0198f5c2-2222-7333-8444-222222222222")
        let audioURL = try audioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        #expect(session.prepare(binding: firstBinding, onPersist: { _, _, _ in throw SyntheticFailure() }))
        session.transcribe(url: audioURL)
        await waitUntil { session.transcript != nil && !session.isBusy }

        #expect(session.hasUnsavedText)
        #expect(!session.canReset)
        #expect(!session.prepare(binding: secondBinding, onPersist: { _, _, _ in }))
        #expect(session.binding == firstBinding)

        session.markRecovered()
        #expect(session.canReset)
        #expect(session.prepare(binding: secondBinding, onPersist: { _, _, _ in }))
        #expect(session.binding == secondBinding)
        #expect(session.transcript == nil)
    }

    @Test("retry uses the same operation identity and timestamp")
    func persistenceRetryIsIdempotent() async throws {
        let engine = SessionTranscriptionEngine(transcript: "Texto sintético para repetição.")
        let session = EncounterTranscriptionSession(
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
        let audioURL = try audioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var attempts: [(EncounterTranscriptInput, RawAssetCreationIdentity, Date)] = []

        #expect(session.prepare(binding: binding(), onPersist: { input, identity, date in
            attempts.append((input, identity, date))
            if attempts.count == 1 { throw SyntheticFailure() }
        }))
        session.transcribe(url: audioURL)
        await waitUntil { attempts.count == 1 && !session.isBusy }
        #expect(!session.saved)

        session.retryPersist()

        #expect(session.saved)
        #expect(attempts.count == 2)
        #expect(attempts[0].0 == attempts[1].0)
        #expect(attempts[0].1.assetID == attempts[1].1.assetID)
        #expect(attempts[0].2 == attempts[1].2)
    }

    @Test("shutdown preserves context and audio while invalidating late callbacks")
    func shutdownInvalidatesLateCallbacks() async throws {
        let engine = SessionTranscriptionEngine(
            transcript: "Não deve reaparecer.",
            delay: .seconds(30)
        )
        let session = EncounterTranscriptionSession(
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
        let originalBinding = binding()
        let audioURL = try audioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var persistenceCount = 0

        #expect(session.prepare(binding: originalBinding, onPersist: { _, _, _ in persistenceCount += 1 }))
        session.transcribe(url: audioURL)
        await waitUntilAsync { await engine.transcriptionCount == 1 }

        session.shutdown()
        await waitUntil { !session.isBusy }

        #expect(session.binding == originalBinding)
        #expect(!session.isPrepared)
        #expect(session.transcript == nil)
        #expect(session.scopeURL == nil)
        #expect(!session.isBusy)
        #expect(persistenceCount == 0)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        session.transcribe(url: audioURL)
        await Task.yield()
        #expect(await engine.transcriptionCount == 1)
    }

    @Test("a changed audio file is rejected before persistence")
    func detectsAudioMutation() async throws {
        let audioURL = try audioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let engine = SessionTranscriptionEngine(
            transcript: "Texto inválido após mutação.",
            replacementAudio: Data("áudio sintético alterado".utf8)
        )
        let session = EncounterTranscriptionSession(
            transcriptionService: LocalTranscriptionService(engine: engine)
        )
        var persistenceCount = 0

        #expect(session.prepare(binding: binding(), onPersist: { _, _, _ in persistenceCount += 1 }))
        session.transcribe(url: audioURL)
        await waitUntil { !session.isBusy }

        #expect(session.transcript == nil)
        #expect(persistenceCount == 0)
        #expect(!session.status.isEmpty)
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

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "openpep-session-recording-\(UUID().uuidString.lowercased()).m4a"
        )
    }

    private func audioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "openpep-session-audio-\(UUID().uuidString.lowercased()).wav"
        )
        try Data("áudio sintético original".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("A condição sintética não foi alcançada no limite do teste")
    }

    private func waitUntilAsync(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("A condição assíncrona sintética não foi alcançada no limite do teste")
    }
}

private struct SyntheticFailure: Error, LocalizedError {
    var errorDescription: String? { "Falha sintética de persistência." }
}

@MainActor
private final class SessionMicrophoneCapture: EncounterMicrophoneCapturing {
    private(set) var stopCount = 0
    private var eventHandler: (@Sendable (EncounterMicrophoneCaptureEvent) -> Void)?

    func requestAccess() async -> Bool { true }

    func startRecording(
        at url: URL,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) throws {
        try Data("áudio sintético".utf8).write(to: url, options: .withoutOverwriting)
        self.eventHandler = eventHandler
    }

    func stopRecording() {
        stopCount += 1
    }

    func finish(_ event: EncounterMicrophoneCaptureEvent) {
        eventHandler?(event)
        eventHandler = nil
    }
}

private actor SessionTranscriptionEngine: LocalTranscriptionEngine {
    let transcript: String
    let delay: Duration?
    let replacementAudio: Data?
    private(set) var transcriptionCount = 0

    init(transcript: String, delay: Duration? = nil, replacementAudio: Data? = nil) {
        self.transcript = transcript
        self.delay = delay
        self.replacementAudio = replacementAudio
    }

    func availability(for locale: Locale) async -> LocalTranscriptionAvailability {
        .ready(localeIdentifier: "pt-BR")
    }

    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String {
        transcriptionCount += 1
        if let replacementAudio {
            try replacementAudio.write(to: url, options: .atomic)
        }
        if let delay { try await Task.sleep(for: delay) }
        return transcript
    }

    func cancel(operationID: UUID) {}
}

private struct SessionSummaryGenerator: ProgressiveSummaryGenerating {
    func generate(_ request: ProgressiveSummaryRequest) async throws -> ProgressiveSummaryEngineOutput {
        .init(operations: [.init(action: .add, targetItemID: nil, text: "Refere sono melhor.",
                               references: request.newReferences)],
              engine: ConsultationSummaryProvenance.engine, model: nil, responseID: nil)
    }
}
