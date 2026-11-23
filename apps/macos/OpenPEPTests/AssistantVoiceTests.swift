// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

// Run in the assistant host: clinical capture suites intentionally preempt the
// process-wide microphone owner, so they must not run alongside these scenarios.
@Suite("ASSISTANT-002 ephemeral command voice", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OPENPEP_ASSISTANT_UI_TESTS"] == "1"))
@MainActor struct AssistantVoiceTests {
    @Test func finalWordsOnlySubmitAfterExplicitFinish() async throws {
        let mic = SyntheticAssistantMicrophone(), recognizer = SyntheticAssistantRecognizer()
        let voice = make(mic, recognizer)
        var ready: [(String, Bool)] = []
        voice.start(basePrompt: "Busque", permitted: { true }) { ready.append(($0, $1)) }
        try await until { voice.state == .listening }
        recognizer.emit?(.partial(text: "Ana"))
        #expect(voice.preview == "Busque Ana" && ready.isEmpty)
        recognizer.emit?(.final(text: "Ana", startSeconds: 0, endSeconds: 1))
        recognizer.finalOnFinish = "Fictícia"
        mic.continuation?.yield(try chunk())
        voice.finish(interpret: true)
        try await until { !voice.isActive }
        #expect(ready.count == 1 && ready.first?.0 == "Busque Ana Fictícia" && ready.first?.1 == true)
        #expect(mic.stops > 0 && recognizer.chunks.count == 1)
        #expect(recognizer.chunks.first?.samplePosition == 0)
    }

    @Test func limitOnlyPreparesText() async throws {
        let mic = SyntheticAssistantMicrophone(), recognizer = SyntheticAssistantRecognizer()
        let voice = make(mic, recognizer, duration: .milliseconds(40))
        var ready: [(String, Bool)] = []
        voice.start(basePrompt: "", permitted: { true }) { ready.append(($0, $1)) }
        try await until { voice.state == .listening }
        recognizer.finalOnFinish = "Abra Ana Fictícia"
        try await until { !voice.isActive }
        #expect(ready.count == 1 && ready.first?.1 == false)
        #expect(voice.message?.contains("Limite") == true)
    }

    @Test func cancelDuringPreparationNeverStartsMicrophone() async throws {
        let mic = SyntheticAssistantMicrophone(), recognizer = SyntheticAssistantRecognizer()
        recognizer.holdStart = true
        let voice = make(mic, recognizer)
        var sent = false
        voice.start(basePrompt: "Texto anterior", permitted: { true }) { _, _ in sent = true }
        try await until { recognizer.startContinuation != nil }
        voice.cancel()
        recognizer.startContinuation?.resume(); recognizer.startContinuation = nil
        try await until { recognizer.startReturned }
        #expect(!voice.isActive && voice.preview.isEmpty && mic.starts == 0 && !sent)
        recognizer.emit?(.final(text: "retorno tardio", startSeconds: 0, endSeconds: 1))
        #expect(voice.preview.isEmpty && !sent)
    }

    @Test func rejectsPermissionAndOccupationAndRechecksAfterPreparation() async throws {
        let mic = SyntheticAssistantMicrophone(), recognizer = SyntheticAssistantRecognizer()
        let voice = make(mic, recognizer)
        mic.isAuthorized = false
        voice.start(basePrompt: "", permitted: { true }) { _, _ in Issue.record("must not submit") }
        #expect(voice.message == AssistantVoiceIssue.permission.localizedDescription && mic.starts == 0)
        mic.isAuthorized = true
        voice.start(basePrompt: "", permitted: { false }) { _, _ in Issue.record("must not submit") }
        #expect(voice.message == AssistantVoiceIssue.occupied.localizedDescription && mic.starts == 0)
        recognizer.holdStart = true
        var allowed = true
        voice.start(basePrompt: "", permitted: { allowed }) { _, _ in Issue.record("must not submit") }
        try await until { recognizer.startContinuation != nil }
        allowed = false
        recognizer.startContinuation?.resume(); recognizer.startContinuation = nil
        try await until { !voice.isActive }
        #expect(mic.starts == 0 && voice.message == AssistantVoiceIssue.occupied.localizedDescription)
    }

    @Test func recognitionAndQueueFailureStopCaptureWithoutSubmitting() async throws {
        for queueFailure in [false, true] {
            let mic = SyntheticAssistantMicrophone(), recognizer = SyntheticAssistantRecognizer()
            let voice = make(mic, recognizer)
            voice.start(basePrompt: "", permitted: { true }) { _, _ in Issue.record("must not submit") }
            try await until { voice.state == .listening }
            if queueFailure {
                recognizer.acceptsChunks = false
                mic.continuation?.yield(try chunk())
            } else { recognizer.emit?(.failed(.engineFailure)) }
            try await until { !voice.isActive }
            #expect(mic.stops > 0 && voice.message != nil)
        }
    }

    @Test func otherWindowCannotStartUntilCancellationReleasesCapture() async throws {
        let firstMic = SyntheticAssistantMicrophone(), otherMic = SyntheticAssistantMicrophone()
        let first = make(firstMic, SyntheticAssistantRecognizer()), other = make(otherMic, SyntheticAssistantRecognizer())
        first.start(basePrompt: "", permitted: { true }) { _, _ in }
        try await until { first.state == .listening }
        other.start(basePrompt: "", permitted: { true }) { _, _ in }
        #expect(otherMic.starts == 0 && other.message != nil)
        first.cancel()
        other.start(basePrompt: "", permitted: { true }) { _, _ in }
        try await until { other.state == .listening }
        other.cancel()
        #expect(otherMic.starts == 1 && firstMic.stops > 0)
    }

    @Test func clinicalCaptureReleasesAssistantBeforeRequestingMicrophone() async throws {
        let mic = SyntheticAssistantMicrophone()
        let voice = make(mic, SyntheticAssistantRecognizer())
        voice.start(basePrompt: "", permitted: { true }) { _, _ in Issue.record("must not submit") }
        try await until { voice.state == .listening }
        let clinical = PriorityClinicalMicrophone {
            #expect(!voice.isActive && mic.continuation == nil)
            #expect(AssistantVoiceSession.clinicalCaptureActive)
        }
        let session = EncounterTranscriptionSession(microphone: EncounterMicrophoneRecordingModel(capture: clinical))
        defer { session.shutdown(); voice.cancel() }
        let url = FileManager.default.temporaryDirectory.appending(path: "assistant-priority-\(UUID().uuidString).m4a")
        #expect(session.prepare(binding: .init(vaultURL: url.deletingLastPathComponent(),
            vaultID: "vlt_synthetic", patientID: "pt_synthetic", encounterID: "enc_synthetic",
            patientName: "Paciente Sintético"), onPersist: { _, _, _ in }))
        await session.startRecording(at: url, consent: true)
        #expect(clinical.requested)
        #expect(voice.message == AssistantVoiceIssue.occupied.localizedDescription)
    }

    private func make(_ mic: SyntheticAssistantMicrophone, _ recognizer: SyntheticAssistantRecognizer,
                      duration: Duration = .seconds(60)) -> AssistantVoiceSession {
        AssistantVoiceSession(capture: mic, maximumDuration: duration) {
            recognizer.emit = $0; return recognizer
        }
    }
    private func chunk() throws -> EncounterAudioChunk {
        try EncounterAudioChunk(pcm16: Data([0, 0, 1, 0]), samplePosition: 0, monotonicTime: 1,
                                format: .pcm16Mono24k, source: .microphone, level: 0)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

@MainActor private final class SyntheticAssistantMicrophone: AssistantMicrophoneCapturing {
    var isAuthorized = true
    var starts = 0, stops = 0
    var continuation: AsyncThrowingStream<EncounterAudioChunk, any Error>.Continuation?
    func start() throws -> AsyncThrowingStream<EncounterAudioChunk, any Error> {
        starts += 1
        let pair = AsyncThrowingStream<EncounterAudioChunk, any Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}
@MainActor private final class SyntheticAssistantRecognizer: AppleLiveTranscribing {
    var emit: (@MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void)?
    var chunks: [EncounterAudioChunk] = []
    var acceptsChunks = true
    var holdStart = false, startReturned = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var finalOnFinish: String?
    func start(locale: Locale) async throws {
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        startReturned = true
    }
    func enqueue(_ chunk: EncounterAudioChunk) -> Bool { chunks.append(chunk); return acceptsChunks }
    func finish() async throws {
        if let finalOnFinish { emit?(.final(text: finalOnFinish, startSeconds: 1, endSeconds: 2)) }
    }
    func cancel() async {}
}

@MainActor private final class PriorityClinicalMicrophone: EncounterMicrophoneCapturing {
    var requested = false
    let onRequest: () -> Void
    init(onRequest: @escaping () -> Void) { self.onRequest = onRequest }
    func requestAccess() async -> Bool { requested = true; onRequest(); return false }
    func startRecording(at url: URL, maximumDuration: TimeInterval,
                        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void) throws {
        Issue.record("Synthetic permission was denied; capture must not start")
    }
    func stopRecording() {}
}
