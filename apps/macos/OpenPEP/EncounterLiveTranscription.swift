// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation

/// A bounded, immutable fragment of the local audio timeline.
///
/// `samplePosition` is expressed in frames of `format`, while `monotonicTime`
/// identifies when capture observed the first frame. Neither field is a wall-clock
/// value and neither identifies a speaker.
struct EncounterAudioFormat: Equatable, Sendable {
    let sampleRate: Int
    let channelCount: Int

    init(sampleRate: Int, channelCount: Int) throws {
        guard (8_000...96_000).contains(sampleRate), (1...2).contains(channelCount) else {
            throw EncounterLiveAudioIssue.invalidAudioFormat
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    static let pcm16Mono24k = try! EncounterAudioFormat(sampleRate: 24_000, channelCount: 1)
}

enum EncounterAudioSource: String, Equatable, Sendable {
    case microphone
    case application
    case mixed
}

struct EncounterAudioChunk: Equatable, Sendable {
    let pcm16: Data
    let samplePosition: Int64
    let monotonicTime: TimeInterval
    let format: EncounterAudioFormat
    let source: EncounterAudioSource
    let level: Double

    init(
        pcm16: Data,
        samplePosition: Int64,
        monotonicTime: TimeInterval,
        format: EncounterAudioFormat,
        source: EncounterAudioSource,
        level: Double
    ) throws {
        guard samplePosition >= 0, monotonicTime.isFinite,
              pcm16.count > 0, pcm16.count.isMultiple(of: 2 * format.channelCount),
              level.isFinite, (0...1).contains(level) else {
            throw EncounterLiveAudioIssue.invalidAudioChunk
        }
        self.pcm16 = pcm16
        self.samplePosition = samplePosition
        self.monotonicTime = monotonicTime
        self.format = format
        self.source = source
        self.level = level
    }

    var frameCount: Int { pcm16.count / (2 * format.channelCount) }
}

/// Converts captured PCM16 into the exact stream format required by the
/// transcription provider. It creates output positions from the input timeline,
/// never by relabeling a 16 kHz chunk as 24 kHz.
enum EncounterRealtimePCMConverter {
    static func convert(_ chunk: EncounterAudioChunk) throws -> EncounterAudioChunk {
        guard chunk.format.channelCount == 1 else { throw OpenAIRealtimeIssue.invalidAudioFormat }
        guard chunk.format != .pcm16Mono24k else { return chunk }
        let input = chunk.pcm16.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
        guard !input.isEmpty else { throw OpenAIRealtimeIssue.invalidAudioFormat }
        let sourceRate = Int64(chunk.format.sampleRate)
        let targetRate = Int64(EncounterAudioFormat.pcm16Mono24k.sampleRate)
        let sourceStart = chunk.samplePosition
        let sourceEnd = sourceStart + Int64(input.count)
        let targetStart = sourceStart * targetRate / sourceRate
        let targetEnd = sourceEnd * targetRate / sourceRate
        guard targetEnd > targetStart else { throw OpenAIRealtimeIssue.invalidAudioFormat }
        var output = Data(capacity: Int(targetEnd - targetStart) * 2)
        for targetFrame in targetStart..<targetEnd {
            let sourceFrame = targetFrame * sourceRate / targetRate
            let index = min(input.count - 1, max(0, Int(sourceFrame - sourceStart)))
            var littleEndian = input[index].littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
        }
        return try EncounterAudioChunk(
            pcm16: output,
            samplePosition: targetStart,
            monotonicTime: chunk.monotonicTime,
            format: .pcm16Mono24k,
            source: chunk.source,
            level: chunk.level
        )
    }
}

enum EncounterLiveAudioIssue: Error, LocalizedError, Equatable, Sendable {
    case invalidAudioFormat
    case invalidAudioChunk
    case unsupportedAudioBuffer
    case recordingAlreadyStarted
    case recordingNotStarted
    case fileWriteFailed
    case fileCreationFailed(domain: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat: "O formato de áudio da captura não é compatível."
        case .invalidAudioChunk: "Um trecho de áudio da captura é inválido."
        case .unsupportedAudioBuffer: "O macOS entregou áudio em um formato não suportado."
        case .recordingAlreadyStarted: "A captura de áudio já está em andamento."
        case .recordingNotStarted: "A captura de áudio não está em andamento."
        case let .fileCreationFailed(domain, code): "Não foi possível criar o áudio local (\(domain), \(code)). Verifique a pasta em Configurações → Gravações."
        case .fileWriteFailed: "Não foi possível criar o áudio na pasta configurada. Verifique o acesso à pasta em Configurações → Gravações."
        }
    }
}

enum EncounterLiveCaptureEvent: Equatable, Sendable {
    case finished
    case failed
}

/// The continuous microphone path is deliberately separate from the legacy
/// file-only recorder. Callers choose it only after the session has explicitly
/// opted in to live recognition.
@MainActor
protocol EncounterLiveMicrophoneCapturing: AnyObject {
    func requestAccess() async -> Bool
    func start(
        at url: URL,
        maximumDuration: TimeInterval,
        chunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterLiveCaptureEvent) -> Void
    ) throws
    func pause() async throws
    func resume() async throws
    func stop()
}

extension EncounterLiveMicrophoneCapturing {
    func pause() async throws {}
    func resume() async throws {}
}

/// AVAudioEngine capture that writes a supported local WAV and publishes copied
/// PCM16 chunks. The consumer must move networking work off the tap callback.
@MainActor
final class AppleEncounterLiveMicrophoneCapture: NSObject, EncounterLiveMicrophoneCapturing {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var chunkHandler: (@Sendable (EncounterAudioChunk) -> Void)?
    private var eventHandler: (@Sendable (EncounterLiveCaptureEvent) -> Void)?
    private var nextSamplePosition: Int64 = 0
    private var durationTimer: Timer?
    private var maximumDuration: TimeInterval = 0
    private var sampleRate: Double = 0
    private var isPaused = false

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    func start(
        at url: URL,
        maximumDuration: TimeInterval,
        chunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterLiveCaptureEvent) -> Void
    ) throws {
        guard file == nil else { throw EncounterLiveAudioIssue.recordingAlreadyStarted }
        guard url.isFileURL, url.pathExtension.lowercased() == "wav",
              !FileManager.default.fileExists(atPath: url.path),
              maximumDuration.isFinite, maximumDuration > 0 else {
            throw EncounterLiveAudioIssue.fileWriteFailed
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate >= 8_000,
              inputFormat.channelCount > 0 else { throw EncounterLiveAudioIssue.invalidAudioFormat }
        let localFile: AVAudioFile
        do {
            localFile = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        } catch {
            let failure = error as NSError
            throw EncounterLiveAudioIssue.fileCreationFailed(domain: failure.domain, code: failure.code)
        }

        self.file = localFile
        self.chunkHandler = chunkHandler
        self.eventHandler = eventHandler
        nextSamplePosition = 0
        self.maximumDuration = maximumDuration
        sampleRate = inputFormat.sampleRate
        isPaused = false
        input.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { @Sendable [weak self, localFile] buffer, _ in
            // The engine owns `buffer` after this callback returns. Copy the PCM
            // before hopping to MainActor. `@Sendable` also prevents this block
            // from inheriting MainActor isolation: AVAudioEngine invokes it on
            // its realtime service queue.
            do {
                try localFile.write(from: buffer)
                let format = try EncounterAudioFormat(
                    sampleRate: Int(buffer.format.sampleRate.rounded()), channelCount: 1
                )
                let pcm16 = try Self.monoPCM16(from: buffer)
                let chunk = try EncounterAudioChunk(
                    pcm16: pcm16,
                    samplePosition: 0,
                    monotonicTime: ProcessInfo.processInfo.systemUptime,
                    format: format,
                    source: .microphone,
                    level: Self.level(pcm16: pcm16)
                )
                Task { @MainActor in self?.consume(chunk) }
            } catch {
                Task { @MainActor in self?.finish(event: .failed) }
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            clear()
            throw EncounterMicrophoneRecordingIssue.startFailed
        }
        scheduleDurationTimer()
    }

    func pause() async throws {
        guard file != nil, !isPaused else { return }
        engine.pause()
        isPaused = true
        durationTimer?.invalidate()
        durationTimer = nil
    }

    func resume() async throws {
        guard file != nil, isPaused else { return }
        do { try engine.start() }
        catch { throw EncounterMicrophoneRecordingIssue.startFailed }
        isPaused = false
        scheduleDurationTimer()
    }

    func stop() {
        guard file != nil else { return }
        finish(event: .finished)
    }

    private func consume(_ captured: EncounterAudioChunk) {
        guard file != nil else { return }
        do {
            let chunk = try EncounterAudioChunk(
                pcm16: captured.pcm16,
                samplePosition: nextSamplePosition,
                monotonicTime: captured.monotonicTime,
                format: captured.format,
                source: captured.source,
                level: captured.level
            )
            nextSamplePosition += Int64(chunk.frameCount)
            chunkHandler?(chunk)
        } catch {
            finish(event: .failed)
        }
    }

    private func finish(event: EncounterLiveCaptureEvent) {
        guard file != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let handler = eventHandler
        clear()
        handler?(event)
    }

    private func clear() {
        durationTimer?.invalidate()
        durationTimer = nil
        file = nil
        chunkHandler = nil
        eventHandler = nil
        nextSamplePosition = 0
        maximumDuration = 0
        sampleRate = 0
        isPaused = false
    }

    private func scheduleDurationTimer() {
        guard sampleRate > 0 else { return }
        let captured = Double(nextSamplePosition) / sampleRate
        let remaining = max(0.001, maximumDuration - captured)
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(event: .finished) }
        }
    }

    nonisolated static func monoPCM16(from buffer: AVAudioPCMBuffer) throws -> Data {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { throw EncounterLiveAudioIssue.unsupportedAudioBuffer }
        var result = Data(capacity: frames * 2)
        for frame in 0..<frames {
            var sample = 0.0
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                guard let data = buffer.floatChannelData else { throw EncounterLiveAudioIssue.unsupportedAudioBuffer }
                for channel in 0..<channels { sample += Double(data[channel][frame]) }
            case .pcmFormatFloat64:
                // AVAudioPCMBuffer has no typed Float64 channel accessor.
                throw EncounterLiveAudioIssue.unsupportedAudioBuffer
            case .pcmFormatInt16:
                guard let data = buffer.int16ChannelData else { throw EncounterLiveAudioIssue.unsupportedAudioBuffer }
                for channel in 0..<channels { sample += Double(data[channel][frame]) / Double(Int16.max) }
            case .pcmFormatInt32:
                guard let data = buffer.int32ChannelData else { throw EncounterLiveAudioIssue.unsupportedAudioBuffer }
                for channel in 0..<channels { sample += Double(data[channel][frame]) / Double(Int32.max) }
            case .otherFormat:
                throw EncounterLiveAudioIssue.unsupportedAudioBuffer
            @unknown default:
                throw EncounterLiveAudioIssue.unsupportedAudioBuffer
            }
            let value = Int16((max(-1, min(1, sample / Double(channels))) * Double(Int16.max)).rounded())
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    nonisolated private static func level(pcm16: Data) -> Double {
        guard !pcm16.isEmpty else { return 0 }
        let samples = pcm16.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0.0) { partial, sample in
            let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
            return partial + normalized * normalized
        } / Double(samples.count)
        return min(1, max(0, sqrt(mean)))
    }
}

/// Finalizes mixed telecall audio only after both inputs are safely behind a
/// bounded holdback. Nothing returned by `drainStable()` can be changed by a
/// later application or microphone callback.
struct EncounterStabilizedAudioMixer: Sendable {
    private let format: EncounterAudioFormat
    private let holdbackFrames: Int64
    private var pending: [EncounterAudioSource: [Int64: Int16]] = [:]
    private var highestEnd: [EncounterAudioSource: Int64] = [:]
    private var nextOutputFrame: Int64 = 0

    init(format: EncounterAudioFormat, holdback: TimeInterval = 0.5) throws {
        guard holdback.isFinite, holdback >= 0 else { throw EncounterLiveAudioIssue.invalidAudioFormat }
        self.format = format
        holdbackFrames = Int64((holdback * Double(format.sampleRate)).rounded(.up))
    }

    mutating func append(_ chunk: EncounterAudioChunk) throws {
        guard chunk.format == format, chunk.source == .microphone || chunk.source == .application else {
            throw EncounterLiveAudioIssue.invalidAudioChunk
        }
        let samples = chunk.pcm16.withUnsafeBytes { raw -> [Int16] in Array(raw.bindMemory(to: Int16.self)) }
        var sourcePending = pending[chunk.source, default: [:]]
        guard chunk.samplePosition >= nextOutputFrame else { throw EncounterLiveAudioIssue.invalidAudioChunk }
        for (offset, littleEndian) in samples.enumerated() {
            let frame = chunk.samplePosition + Int64(offset)
            guard sourcePending[frame] == nil else { throw EncounterLiveAudioIssue.invalidAudioChunk }
            sourcePending[frame] = Int16(littleEndian: littleEndian)
        }
        pending[chunk.source] = sourcePending
        highestEnd[chunk.source] = max(highestEnd[chunk.source] ?? 0, chunk.samplePosition + Int64(samples.count))
    }

    mutating func drainStable(monotonicTime: TimeInterval) throws -> EncounterAudioChunk? {
        // A silent source has no watermark. After the holdback it is intentionally
        // mixed as silence, which keeps the captured timeline continuous.
        guard let latestEnd = highestEnd.values.max() else { return nil }
        let stableEnd = latestEnd - holdbackFrames
        return try emit(through: stableEnd, monotonicTime: monotonicTime)
    }

    mutating func finish(monotonicTime: TimeInterval) throws -> EncounterAudioChunk? {
        let finalEnd = highestEnd.values.max() ?? nextOutputFrame
        return try emit(through: finalEnd, monotonicTime: monotonicTime)
    }

    private mutating func emit(through end: Int64, monotonicTime: TimeInterval) throws -> EncounterAudioChunk? {
        guard end > nextOutputFrame else { return nil }
        var bytes = Data(capacity: Int(end - nextOutputFrame) * 2)
        var totalSquare = 0.0
        for frame in nextOutputFrame..<end {
            let microphone = pending[.microphone]?[frame] ?? 0
            let application = pending[.application]?[frame] ?? 0
            let mixed = Int16(clamping: Int32(microphone) + Int32(application))
            let normalized = Double(mixed) / Double(Int16.max)
            totalSquare += normalized * normalized
            var littleEndian = mixed.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            pending[.microphone]?[frame] = nil
            pending[.application]?[frame] = nil
        }
        let start = nextOutputFrame
        nextOutputFrame = end
        return try EncounterAudioChunk(
            pcm16: bytes,
            samplePosition: start,
            monotonicTime: monotonicTime,
            format: format,
            source: .mixed,
            level: min(1, sqrt(totalSquare / Double(max(1, end - start))))
        )
    }
}

enum OpenAIRealtimeIssue: Error, LocalizedError, Equatable, Sendable {
    case invalidCredential
    case invalidAudioFormat
    case queueFull
    case notConnected
    case connectionFailed
    case connectionClosed
    case requestRejected
    case modelUnavailable
    case quotaExceeded
    case invalidSessionConfiguration
    case invalidEvent

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "A chave da OpenAI não está disponível ou é inválida."
        case .invalidAudioFormat: "A transcrição ao vivo requer áudio PCM mono a 24 kHz."
        case .queueFull: "A transcrição ao vivo está atrasada. O trecho permanece pendente no áudio local."
        case .notConnected: "A transcrição ao vivo não está conectada."
        case .connectionFailed: "Não foi possível conectar à transcrição ao vivo da OpenAI."
        case .connectionClosed: "A conexão de transcrição ao vivo foi encerrada."
        case .requestRejected: "A OpenAI recusou a transcrição ao vivo configurada."
        case .modelUnavailable: "O modelo de transcrição não está disponível para esta conta OpenAI."
        case .quotaExceeded: "A OpenAI informou limite de uso ou saldo insuficiente para transcrever."
        case .invalidSessionConfiguration: "A OpenAI recusou a configuração da sessão de transcrição."
        case .invalidEvent: "A OpenAI devolveu um evento de transcrição não reconhecido."
        }
    }
}

enum OpenAIRealtimeEvent: Equatable, Sendable {
    case connectionReady
    case partial(itemID: String, contentIndex: Int, text: String)
    case final(itemID: String, contentIndex: Int, text: String)
    case failed(OpenAIRealtimeIssue)
    case closed
}

private struct OpenAIRealtimeTranscriptItem: Hashable, Sendable {
    let itemID: String
    let contentIndex: Int
}

@MainActor
protocol OpenAIRealtimeSocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor
protocol OpenAIRealtimeSocketFactory: AnyObject {
    func connect(apiKey: String) throws -> any OpenAIRealtimeSocket
}

@MainActor
final class OpenAIRealtimeTranscription {
    static let model = "gpt-live-transcribe"
    static let maximumQueuedBytes = 2 * 1_024 * 1_024

    private let socketFactory: any OpenAIRealtimeSocketFactory
    private let eventHandler: @MainActor @Sendable (OpenAIRealtimeEvent) -> Void
    private var socket: (any OpenAIRealtimeSocket)?
    private var pendingAudio: [(payload: Data, frames: Int)] = []
    private var pendingByteCount = 0
    private var inFlightByteCount = 0
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var acceptsAudio = false
    private var framesSinceCommit = 0
    private var pendingCommitCount = 0
    private var partialEventIDs = Set<String>()
    private var completedItems: Set<OpenAIRealtimeTranscriptItem> = []
    private var generation: UInt = 0

    init(
        socketFactory: any OpenAIRealtimeSocketFactory = URLSessionOpenAIRealtimeSocketFactory(),
        eventHandler: @escaping @MainActor @Sendable (OpenAIRealtimeEvent) -> Void
    ) {
        self.socketFactory = socketFactory
        self.eventHandler = eventHandler
    }

    func connect(apiKey: String) async throws {
        guard socket == nil else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpenAIRealtimeIssue.invalidCredential
        }
        let connected: any OpenAIRealtimeSocket
        do {
            connected = try socketFactory.connect(apiKey: key)
        } catch {
            throw OpenAIRealtimeIssue.connectionFailed
        }
        generation &+= 1
        let currentGeneration = generation
        socket = connected
        framesSinceCommit = 0
        pendingCommitCount = 0
        partialEventIDs = []
        completedItems = []
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            connected.close()
        }
        defer { timeout.cancel() }
        do {
            try await connected.send(try Self.sessionUpdate())
            // A successful WebSocket write does not mean the server accepted
            // the transcription session. Do not start capture before its ACK.
            while true {
                let data = try await connected.receive()
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { throw OpenAIRealtimeIssue.invalidEvent }
                if type == "error" { throw Self.providerIssue(event) }
                if type == "session.updated" {
                    guard let session = event["session"] as? [String: Any],
                          session["type"] as? String == "transcription" else {
                        throw OpenAIRealtimeIssue.invalidSessionConfiguration
                    }
                    break
                }
            }
        } catch is CancellationError {
            connected.close()
            socket = nil
            throw CancellationError()
        } catch let issue as OpenAIRealtimeIssue {
            connected.close()
            socket = nil
            throw issue
        } catch {
            connected.close()
            socket = nil
            throw OpenAIRealtimeIssue.connectionFailed
        }
        acceptsAudio = true
        receiverTask = Task { @MainActor [weak self] in
            await self?.receiveEvents(generation: currentGeneration, socket: connected)
        }
        eventHandler(.connectionReady)
    }

    func enqueue(_ chunk: EncounterAudioChunk) throws {
        guard acceptsAudio, socket != nil else { throw OpenAIRealtimeIssue.notConnected }
        guard chunk.format == .pcm16Mono24k, chunk.source == .microphone || chunk.source == .mixed else {
            throw OpenAIRealtimeIssue.invalidAudioFormat
        }
        let payload = try Self.message(type: "input_audio_buffer.append", fields: [
            "audio": chunk.pcm16.base64EncodedString(),
        ])
        guard pendingByteCount + inFlightByteCount + payload.count <= Self.maximumQueuedBytes else {
            throw OpenAIRealtimeIssue.queueFull
        }
        pendingAudio.append((payload, chunk.frameCount))
        pendingByteCount += payload.count
        if senderTask == nil {
            senderTask = Task { @MainActor [weak self] in await self?.drain() }
        }
    }

    /// Stops accepting chunks, sends every queued append, and then commits the
    /// last input turn. Final transcript events remain observable afterwards.
    func drainAndCommit() async throws {
        guard socket != nil else { throw OpenAIRealtimeIssue.notConnected }
        acceptsAudio = false
        if let senderTask { await senderTask.value }
        guard framesSinceCommit > 0, let socket else { return }
        do {
            // Realtime requires at least 100 ms in a committed buffer.
            if framesSinceCommit < 2_400 {
                try await socket.send(try Self.message(type: "input_audio_buffer.append", fields: [
                    "audio": Data(repeating: 0, count: (2_400 - framesSinceCommit) * 2).base64EncodedString()
                ]))
            }
            pendingCommitCount += 1
            try await socket.send(try Self.message(type: "input_audio_buffer.commit", fields: [:]))
            framesSinceCommit = 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAIRealtimeIssue.connectionClosed
        }
    }

    func cancel() {
        generation &+= 1
        acceptsAudio = false
        pendingAudio = []
        pendingByteCount = 0
        inFlightByteCount = 0
        framesSinceCommit = 0
        pendingCommitCount = 0
        partialEventIDs = []
        completedItems = []
        senderTask?.cancel()
        senderTask = nil
        receiverTask?.cancel()
        receiverTask = nil
        socket?.close()
        socket = nil
    }

    private func drain() async {
        defer { senderTask = nil }
        while !pendingAudio.isEmpty, let socket, !Task.isCancelled {
            let queued = pendingAudio.removeFirst()
            let payload = queued.payload
            pendingByteCount -= payload.count
            inFlightByteCount += payload.count
            do {
                try await socket.send(payload)
                framesSinceCommit += queued.frames
                if framesSinceCommit >= 15 * 24_000 {
                    pendingCommitCount += 1
                    try await socket.send(try Self.message(type: "input_audio_buffer.commit", fields: [:]))
                    framesSinceCommit = 0
                }
                inFlightByteCount -= payload.count
            } catch is CancellationError {
                inFlightByteCount -= payload.count
                return
            } catch let issue as OpenAIRealtimeIssue {
                inFlightByteCount -= payload.count
                fail(issue)
                return
            } catch {
                inFlightByteCount -= payload.count
                fail(.connectionClosed)
                return
            }
        }
    }

    private func receiveEvents(generation currentGeneration: UInt, socket: any OpenAIRealtimeSocket) async {
        while !Task.isCancelled, generation == currentGeneration {
            do {
                let event = try await socket.receive()
                guard generation == currentGeneration else { return }
                try publish(event)
            } catch is CancellationError {
                return
            } catch let issue as OpenAIRealtimeIssue {
                guard generation == currentGeneration else { return }
                fail(issue)
                return
            } catch {
                guard generation == currentGeneration else { return }
                fail(.connectionClosed)
                return
            }
        }
    }

    private func publish(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw OpenAIRealtimeIssue.invalidEvent }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = object["item_id"] as? String,
                  let contentIndex = object["content_index"] as? Int,
                  let text = object["delta"] as? String else { throw OpenAIRealtimeIssue.invalidEvent }
            if let eventID = object["event_id"] as? String,
               !partialEventIDs.insert(eventID).inserted {
                return
            }
            eventHandler(.partial(itemID: itemID, contentIndex: contentIndex, text: text))
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = object["item_id"] as? String,
                  let contentIndex = object["content_index"] as? Int,
                  let text = object["transcript"] as? String else { throw OpenAIRealtimeIssue.invalidEvent }
            let item = OpenAIRealtimeTranscriptItem(itemID: itemID, contentIndex: contentIndex)
            guard completedItems.insert(item).inserted else { return }
            pendingCommitCount = max(0, pendingCommitCount - 1)
            eventHandler(.final(itemID: itemID, contentIndex: contentIndex, text: text))
        case "conversation.item.input_audio_transcription.failed":
            fail(.requestRejected)
        case "input_audio_buffer.committed":
            guard object["item_id"] as? String != nil else { throw OpenAIRealtimeIssue.invalidEvent }
            // ACKs can arrive after audio for the next turn. They must not
            // clear the client's count of audio still waiting to be committed.
        case "error":
            fail(Self.providerIssue(object))
        default:
            break
        }
    }

    private func fail(_ issue: OpenAIRealtimeIssue) {
        guard socket != nil else { return }
        generation &+= 1
        acceptsAudio = false
        pendingAudio = []
        pendingByteCount = 0
        inFlightByteCount = 0
        framesSinceCommit = 0
        senderTask?.cancel()
        socket?.close()
        socket = nil
        eventHandler(.failed(issue))
    }

    func waitForFinalTranscripts(timeout: Duration) async throws {
        // Zero is an explicit test seam for callers with pre-delivered events.
        guard timeout > .zero else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while pendingCommitCount > 0 {
            try Task.checkCancellation()
            guard socket != nil, ContinuousClock.now < deadline else {
                throw OpenAIRealtimeIssue.connectionClosed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func providerIssue(_ event: [String: Any]) -> OpenAIRealtimeIssue {
        let error = event["error"] as? [String: Any]
        // Never publish the provider message: it can echo submitted content.
        switch error?["code"] as? String {
        case "invalid_api_key", "invalid_authentication": return .invalidCredential
        case "model_not_found", "model_not_available": return .modelUnavailable
        case "insufficient_quota", "rate_limit_exceeded": return .quotaExceeded
        case "invalid_value", "invalid_parameter", "unknown_parameter", "missing_required_parameter":
            return .invalidSessionConfiguration
        default: return .requestRejected
        }
    }

    private static func message(type: String, fields: [String: String]) throws -> Data {
        var body: [String: String] = fields
        body["type"] = type
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private static func sessionUpdate() throws -> Data {
        let body: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": Self.model],
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }
}

@MainActor
final class URLSessionOpenAIRealtimeSocketFactory: OpenAIRealtimeSocketFactory {
    func connect(apiKey: String) throws -> any OpenAIRealtimeSocket {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw OpenAIRealtimeIssue.connectionFailed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let task = URLSession(configuration: configuration).webSocketTask(with: request)
        task.resume()
        return URLSessionOpenAIRealtimeSocket(task: task)
    }
}

@MainActor
final class URLSessionOpenAIRealtimeSocket: OpenAIRealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ data: Data) async throws {
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeIssue.invalidEvent
        }
        try await task.send(.string(json))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data): return data
        case let .string(string): return Data(string.utf8)
        @unknown default: throw OpenAIRealtimeIssue.connectionClosed
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
