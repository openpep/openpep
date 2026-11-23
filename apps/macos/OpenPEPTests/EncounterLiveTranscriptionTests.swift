// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor
struct EncounterLiveTranscriptionTests {
    @Test("resamples PCM16 audio to the provider format without relabeling its timeline")
    func convertsTo24kPCM() throws {
        let source = try chunk(samples: [100, 200, 300, 400], sampleRate: 8_000)

        let converted = try EncounterRealtimePCMConverter.convert(source)

        #expect(converted.format == .pcm16Mono24k)
        #expect(converted.samplePosition == 0)
        #expect(converted.frameCount == 12)
        #expect(samples(converted.pcm16) == [100, 100, 100, 200, 200, 200, 300, 300, 300, 400, 400, 400])
    }

    @Test("telecall mixer emits only finalized mixed frames")
    func mixesStableFrames() throws {
        let format = try EncounterAudioFormat(sampleRate: 16_000, channelCount: 1)
        var mixer = try EncounterStabilizedAudioMixer(format: format, holdback: 0)
        try mixer.append(chunk(samples: [100, 200, 300], sampleRate: 16_000, source: .microphone))
        try mixer.append(chunk(samples: [400, 500, 600], sampleRate: 16_000, source: .application))

        let stable = try #require(try mixer.drainStable(monotonicTime: 1.25))

        #expect(stable.source == .mixed)
        #expect(stable.samplePosition == 0)
        #expect(samples(stable.pcm16) == [500, 700, 900])
        #expect(try mixer.drainStable(monotonicTime: 1.5) == nil)
    }

    @Test("telecall mixer keeps a silent side continuous and rejects audio that arrives after its holdback")
    func handlesSilenceAndLateAudio() throws {
        let format = try EncounterAudioFormat(sampleRate: 8_000, channelCount: 1)
        var mixer = try EncounterStabilizedAudioMixer(format: format, holdback: 5.0 / 8_000.0)
        try mixer.append(chunk(samples: [100, 200, 300, 400, 500, 600, 700, 800, 900, 1_000], sampleRate: 8_000,
                               source: .microphone))

        let stable = try #require(try mixer.drainStable(monotonicTime: 2))
        #expect(stable.frameCount == 5)
        #expect(samples(stable.pcm16) == [100, 200, 300, 400, 500])

        #expect(throws: EncounterLiveAudioIssue.invalidAudioChunk) {
            try mixer.append(chunk(samples: [1, 2], sampleRate: 8_000, source: .application, samplePosition: 0))
        }
    }

    @Test("realtime session configures transcription, sends queued audio before commit, and matches item events")
    func configuresAndDrainsRealtimeAudio() async throws {
        let socket = RecordingRealtimeSocket(events: [
            #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"event_delta_1","item_id":"item_2","content_index":0,"delta":"texto "}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"event_delta_1","item_id":"item_2","content_index":0,"delta":"texto "}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"event_delta_2","item_id":"item_2","content_index":0,"delta":"texto "}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_2","content_index":0,"transcript":"texto final"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","content_index":0,"transcript":"primeiro por intervalo"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_2","content_index":0,"transcript":"texto final"}"#,
        ])
        let sink = RealtimeEventSink()
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket),
            eventHandler: { event in sink.events.append(event) }
        )

        try await service.connect(apiKey: "sk-synthetic-key-never-sent")
        try service.enqueue(try chunk(samples: Array(repeating: 1, count: 2_400), sampleRate: 24_000))
        await waitUntil { socket.sent.count >= 2 }
        try await service.drainAndCommit()
        await waitUntil { sink.events.contains(.final(itemID: "item_2", contentIndex: 0, text: "texto final")) }

        let messages = try socket.sent.map(json)
        #expect(messages[0]["type"] as? String == "session.update")
        let session = try #require(messages[0]["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["rate"] as? Int == 24_000)
        #expect(input["turn_detection"] is NSNull)
        #expect(messages[1]["type"] as? String == "input_audio_buffer.append")
        #expect(messages[2]["type"] as? String == "input_audio_buffer.commit")
        #expect(sink.events.contains(.partial(itemID: "item_2", contentIndex: 0, text: "texto ")))
        #expect(sink.events.filter {
            $0 == .partial(itemID: "item_2", contentIndex: 0, text: "texto ")
        }.count == 2)
        #expect(sink.events.filter {
            $0 == .final(itemID: "item_2", contentIndex: 0, text: "texto final")
        }.count == 1)
        #expect(sink.events.contains(.final(itemID: "item_1", contentIndex: 0, text: "primeiro por intervalo")))
        service.cancel()
    }

    @Test("a late commit acknowledgement does not discard the last audio buffer")
    func skipsEmptyFinalCommitAfterVAD() async throws {
        let socket = RecordingRealtimeSocket(events: [])
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket), eventHandler: { _ in }
        )
        try await service.connect(apiKey: "sk-synthetic-key-never-sent")
        try service.enqueue(try chunk(samples: [1, 2, 3], sampleRate: 24_000))
        await waitUntil { socket.sent.count >= 2 }
        socket.emit(#"{"type":"input_audio_buffer.committed","item_id":"item_vad"}"#)
        await waitUntil { socket.receiveCount >= 3 }

        try await service.drainAndCommit()

        let types = try socket.sent.map { try json($0)["type"] as? String }
        #expect(types.last == "input_audio_buffer.commit")
        service.cancel()
    }

    @Test("audio starts only after server acknowledgement")
    func waitsForSessionAcknowledgement() async throws {
        let socket = RecordingRealtimeSocket(events: [], acknowledgesSession: false)
        let sink = RealtimeEventSink()
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket),
            eventHandler: { sink.events.append($0) }
        )
        let connecting = Task { try await service.connect(apiKey: "sk-synthetic-never-sent") }
        await waitUntil { socket.sent.count == 1 }
        #expect(!sink.events.contains(.connectionReady))
        #expect(throws: OpenAIRealtimeIssue.notConnected) {
            try service.enqueue(try chunk(samples: [1, 2, 3], sampleRate: 24_000))
        }
        socket.emit(#"{"type":"session.updated","session":{"type":"transcription"}}"#)
        try await connecting.value
        #expect(sink.events.contains(.connectionReady))
        service.cancel()
    }

    @Test("commits during capture and waits for the last turn")
    func commitsDuringCaptureAndWaitsForLastTurn() async throws {
        let socket = RecordingRealtimeSocket(events: [])
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket), eventHandler: { _ in }
        )
        try await service.connect(apiKey: "sk-synthetic-never-sent")
        try service.enqueue(try chunk(samples: Array(repeating: 1, count: 15 * 24_000), sampleRate: 24_000))
        await waitUntil { socket.sent.count == 3 }
        #expect(try json(socket.sent[2])["type"] as? String == "input_audio_buffer.commit")
        try service.enqueue(try chunk(samples: [1, 2, 3], sampleRate: 24_000))
        socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"first","content_index":0,"transcript":"primeiro"}"#)
        try await service.drainAndCommit()
        var finished = false
        let finishing = Task {
            try await service.waitForFinalTranscripts(timeout: .seconds(30))
            finished = true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished)
        socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"last","content_index":0,"transcript":"último"}"#)
        try await finishing.value
        #expect(finished)
        service.cancel()
    }

    @Test("session rejection is reported before capture without echoing provider text")
    func rejectsSessionConfiguration() async throws {
        let socket = RecordingRealtimeSocket(events: [
            #"{"type":"error","error":{"code":"model_not_found","message":"private synthetic text"}}"#
        ], acknowledgesSession: false)
        let sink = RealtimeEventSink()
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket),
            eventHandler: { sink.events.append($0) }
        )
        await #expect(throws: OpenAIRealtimeIssue.modelUnavailable) {
            try await service.connect(apiKey: "sk-synthetic-never-sent")
        }
        #expect(socket.closed)
        #expect(!sink.events.contains(.connectionReady))
    }

    @Test("bounded queue reports backlog without blocking the capture caller")
    func rejectsQueueOverflow() async throws {
        let socket = RecordingRealtimeSocket(events: [])
        socket.suspendAppendSends = true
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket), eventHandler: { _ in }
        )
        try await service.connect(apiKey: "sk-synthetic-key-never-sent")
        let large = try chunk(samples: [Int16](repeating: 1, count: 450_000), sampleRate: 24_000)
        try service.enqueue(large)
        await waitUntil { socket.appendSendCount == 1 }
        #expect(throws: OpenAIRealtimeIssue.queueFull) { try service.enqueue(large) }

        service.cancel()
        #expect(socket.closed)
    }

    @Test("invalid credentials and a rejected connection expose only sanitized errors")
    func sanitizesCredentialAndConnectionFailures() async {
        let factory = RecordingRealtimeSocketFactory(socket: RecordingRealtimeSocket(events: []))
        let service = OpenAIRealtimeTranscription(socketFactory: factory, eventHandler: { _ in })
        await #expect(throws: OpenAIRealtimeIssue.invalidCredential) {
            try await service.connect(apiKey: "not-a-key")
        }
        #expect(factory.connectionCount == 0)

        let rejectedSocket = RecordingRealtimeSocket(events: [])
        rejectedSocket.sendError = NSError(domain: "remote-secret-never-expose", code: 1)
        let rejected = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: rejectedSocket), eventHandler: { _ in }
        )
        await #expect(throws: OpenAIRealtimeIssue.connectionFailed) {
            try await rejected.connect(apiKey: "sk-synthetic-key-never-sent")
        }
    }

    @Test("cancel clears buffered audio and ignores a late socket event")
    func cancellationInvalidatesEvents() async throws {
        let socket = RecordingRealtimeSocket(events: [])
        let sink = RealtimeEventSink()
        let service = OpenAIRealtimeTranscription(
            socketFactory: RecordingRealtimeSocketFactory(socket: socket),
            eventHandler: { event in sink.events.append(event) }
        )
        try await service.connect(apiKey: "sk-synthetic-key-never-sent")
        try service.enqueue(try chunk(samples: [1, 2, 3], sampleRate: 24_000))
        service.cancel()
        socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"late","content_index":0,"transcript":"não publicar"}"#)
        await Task.yield()

        #expect(socket.closed)
        #expect(!sink.events.contains(.final(itemID: "late", contentIndex: 0, text: "não publicar")))
    }

    private func chunk(
        samples values: [Int16],
        sampleRate: Int,
        source: EncounterAudioSource = .microphone,
        samplePosition: Int64 = 0
    ) throws -> EncounterAudioChunk {
        var data = Data(capacity: values.count * 2)
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return try EncounterAudioChunk(
            pcm16: data,
            samplePosition: samplePosition,
            monotonicTime: 1,
            format: EncounterAudioFormat(sampleRate: sampleRate, channelCount: 1),
            source: source,
            level: 0.1
        )
    }

    private func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:)) }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("A condição sintética não foi alcançada no limite do teste")
    }
}

@MainActor
private final class RealtimeEventSink {
    var events: [OpenAIRealtimeEvent] = []
}

@MainActor
private final class RecordingRealtimeSocketFactory: OpenAIRealtimeSocketFactory {
    let socket: RecordingRealtimeSocket
    private(set) var connectionCount = 0

    init(socket: RecordingRealtimeSocket) { self.socket = socket }

    func connect(apiKey: String) throws -> any OpenAIRealtimeSocket {
        connectionCount += 1
        return socket
    }
}

@MainActor
private final class RecordingRealtimeSocket: OpenAIRealtimeSocket {
    private var incoming: [Data]
    private var continuation: CheckedContinuation<Data, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private(set) var sent: [Data] = []
    private(set) var closed = false
    private(set) var receiveCount = 0
    private(set) var appendSendCount = 0
    var suspendAppendSends = false
    var sendError: Error?

    init(events: [String], acknowledgesSession: Bool = true) {
        let acknowledgement = #"{"type":"session.updated","session":{"type":"transcription"}}"#
        incoming = ((acknowledgesSession ? [acknowledgement] : []) + events).map { Data($0.utf8) }
    }

    func send(_ data: Data) async throws {
        if let sendError { throw sendError }
        sent.append(data)
        let type = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
        if type == "input_audio_buffer.append" {
            appendSendCount += 1
            if suspendAppendSends {
                try await withCheckedThrowingContinuation { sendContinuation = $0 }
            }
        }
    }

    func receive() async throws -> Data {
        receiveCount += 1
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func close() {
        closed = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
        let sendContinuation = sendContinuation
        self.sendContinuation = nil
        sendContinuation?.resume(throwing: CancellationError())
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
