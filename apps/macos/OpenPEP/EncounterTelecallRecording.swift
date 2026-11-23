// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

enum EncounterTelecallRecordingIssue: Error, LocalizedError, Equatable, Sendable {
    case destinationExists
    case microphonePermissionDenied
    case selectedApplicationUnavailable
    case noDisplay
    case synchronizationClockUnavailable
    case outputSetup
    case startFailed
    case invalidAudio
    case invalidTimestamp
    case timestampRegression
    case durationExceeded
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .destinationExists:
            "Já existe um arquivo nesse destino. Escolha outro nome para não substituir o conteúdo existente."
        case .microphonePermissionDenied:
            "O acesso ao microfone não foi autorizado. A gravação não começou."
        case .selectedApplicationUnavailable:
            "O aplicativo escolhido não está mais disponível. Atualize a lista e tente novamente."
        case .noDisplay:
            "Nenhuma tela disponível foi encontrada para limitar a captura ao aplicativo escolhido."
        case .synchronizationClockUnavailable:
            "O macOS não forneceu o relógio necessário para alinhar os dois lados da chamada."
        case .outputSetup:
            "O macOS não preparou as duas fontes de áudio. A gravação foi interrompida."
        case .startFailed:
            "O macOS não iniciou a gravação da chamada. Qualquer áudio criado foi preservado."
        case .invalidAudio:
            "Uma fonte entregou áudio em formato inválido. A gravação foi interrompida."
        case .invalidTimestamp, .timestampRegression:
            "Uma fonte entregou áudio fora da ordem temporal. A gravação foi interrompida."
        case .durationExceeded:
            "A gravação atingiu o limite de 60 minutos."
        case .fileWriteFailed:
            "Não foi possível concluir o arquivo de áudio. O conteúdo já gravado foi preservado."
        }
    }
}

@MainActor
protocol EncounterTelecallCapturing: AnyObject {
    func availableApplications() async throws -> [TeleconsultAudioApplication]
    func start(
        at: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws
    func stop() async -> EncounterMicrophoneCaptureEvent?
}

@MainActor
protocol EncounterTelecallLiveCapturing: EncounterTelecallCapturing {
    func startLive(
        at: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        stableChunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws
}

@MainActor
final class AppleEncounterTelecallCapture: EncounterTelecallLiveCapturing {
    private var stream: SCStream?
    private var output: EncounterTelecallStreamOutput?
    private var activeSessionID: UUID?
    private var activeEventHandler: (@Sendable (EncounterMicrophoneCaptureEvent) -> Void)?
    private var generation: UInt = 0
    private var cleanupTask: Task<EncounterMicrophoneCaptureEvent, Never>?

    func availableApplications() async throws -> [TeleconsultAudioApplication] {
        let content = try await shareableContent(issue: TeleconsultAudioProbeIssue.contentUnavailable)
        return content.applications
            .filter(TeleconsultAudioCaptureSupport.isSupported)
            .map(TeleconsultAudioCaptureSupport.application)
            .sorted(by: TeleconsultAudioCaptureSupport.sortApplications)
    }

    func start(
        at url: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws {
        try await startCapture(
            at: url,
            application: application,
            maximumDuration: maximumDuration,
            stableChunkHandler: nil,
            eventHandler: eventHandler
        )
    }

    func startLive(
        at url: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        stableChunkHandler: @escaping @Sendable (EncounterAudioChunk) -> Void,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws {
        try await startCapture(
            at: url,
            application: application,
            maximumDuration: maximumDuration,
            stableChunkHandler: stableChunkHandler,
            eventHandler: eventHandler
        )
    }

    private func startCapture(
        at url: URL,
        application: TeleconsultAudioApplication,
        maximumDuration: TimeInterval,
        stableChunkHandler: (@Sendable (EncounterAudioChunk) -> Void)?,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) async throws {
        _ = await stop()
        generation &+= 1
        let operationGeneration = generation
        try Task.checkCancellation()

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == operationGeneration else { throw CancellationError() }
        guard microphoneAllowed else {
            throw EncounterTelecallRecordingIssue.microphonePermissionDenied
        }
        try Task.checkCancellation()

        let content = try await shareableContent(issue: EncounterTelecallRecordingIssue.startFailed)
        guard generation == operationGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        let filter: SCContentFilter
        if application.capturesAllSystemAudio {
            guard let display = content.displays.first else { throw EncounterTelecallRecordingIssue.noDisplay }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        } else {
            guard let selected = content.applications.first(where: {
                $0.processID == application.processIdentifier
                    && $0.bundleIdentifier == application.bundleIdentifier
                    && TeleconsultAudioCaptureSupport.isSupported($0)
            }) else { throw EncounterTelecallRecordingIssue.selectedApplicationUnavailable }
            guard let display = TeleconsultAudioCaptureSupport.display(for: selected, in: content) else {
                throw EncounterTelecallRecordingIssue.noDisplay
            }
            filter = SCContentFilter(display: display, including: [selected], exceptingWindows: [])
        }
        let configuration = TeleconsultAudioCaptureSupport.configuration(
            streamName: "OpenPEP — gravação sintética da teleconsulta"
        )
        let sessionID = UUID()
        let writer = try EncounterTelecallWAVWriter(
            url: url,
            maximumDuration: min(maximumDuration, 60 * 60)
        )
        let output = EncounterTelecallStreamOutput(
            writer: writer,
            maximumDuration: min(maximumDuration, 60 * 60),
            stableChunkHandler: stableChunkHandler
        ) { [weak self] event in
            Task { @MainActor in
                guard self?.activeSessionID == sessionID else { return }
                await self?.complete(sessionID: sessionID, event: event)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        guard let clock = stream.synchronizationClock else {
            try? writer.finish()
            throw EncounterTelecallRecordingIssue.synchronizationClockUnavailable
        }
        output.setOrigin(CMClockGetTime(clock))

        activeSessionID = sessionID
        activeEventHandler = eventHandler
        self.output = output
        self.stream = stream
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        } catch {
            await abandon(stream: stream, output: output, sessionID: sessionID)
            throw EncounterTelecallRecordingIssue.outputSetup
        }

        do {
            try Task.checkCancellation()
            try await stream.startCapture()
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard activeSessionID == sessionID else {
                return
            }
            output.startDurationLimit()
        } catch is CancellationError {
            if let cleanupTask {
                _ = await cleanupTask.value
            } else {
                await abandon(stream: stream, output: output, sessionID: sessionID)
            }
            throw CancellationError()
        } catch {
            if generation != operationGeneration, let cleanupTask {
                _ = await cleanupTask.value
                throw CancellationError()
            }
            await abandon(stream: stream, output: output, sessionID: sessionID)
            throw EncounterTelecallRecordingIssue.startFailed
        }
    }

    func stop() async -> EncounterMicrophoneCaptureEvent? {
        generation &+= 1
        return await finishActive(requestedEvent: .finished)
    }

    private func complete(
        sessionID: UUID,
        event: EncounterMicrophoneCaptureEvent
    ) async {
        guard activeSessionID == sessionID else { return }
        _ = await finishActive(requestedEvent: event)
    }

    private func finishActive(
        requestedEvent: EncounterMicrophoneCaptureEvent
    ) async -> EncounterMicrophoneCaptureEvent? {
        if let cleanupTask { return await cleanupTask.value }
        guard let stream, let output else { return nil }
        let handler = activeEventHandler
        let task = Task { @MainActor in
            let stopEvent: EncounterMicrophoneCaptureEvent
            do {
                try await stream.stopCapture()
                stopEvent = requestedEvent
            } catch {
                stopEvent = .failed
            }
            let outputEvent = await output.finish(event: stopEvent, notify: false)
            let event: EncounterMicrophoneCaptureEvent = stopEvent == .failed ? .failed : outputEvent
            self.cleanupTask = nil
            self.activeSessionID = nil
            self.activeEventHandler = nil
            self.stream = nil
            self.output = nil
            handler?(event)
            return event
        }
        cleanupTask = task
        return await task.value
    }

    private func abandon(
        stream: SCStream,
        output: EncounterTelecallStreamOutput,
        sessionID: UUID
    ) async {
        if activeSessionID == sessionID {
            activeSessionID = nil
            activeEventHandler = nil
            self.stream = nil
            self.output = nil
        }
        try? await stream.stopCapture()
        _ = await output.finish(event: .failed, notify: false)
    }

    private func shareableContent(issue: any Error) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw issue
        }
    }
}

enum EncounterTelecallAudioSource: Sendable {
    case application
    case microphone
}

final class EncounterTelecallWAVWriter: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let headerByteCount: UInt64 = 44
    static let maximumFileByteCount: UInt64 = 116_000_000

    private let file: FileHandle
    private let maximumFrames: Int64
    private let maximumDuration: TimeInterval
    private var frameCount: Int64 = 0
    private var sourceEndTime: [EncounterTelecallAudioSource: CMTime] = [:]
    private var isClosed = false

    convenience init(url: URL, maximumDuration: TimeInterval) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw EncounterTelecallRecordingIssue.destinationExists }
            throw EncounterTelecallRecordingIssue.fileWriteFailed
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try self.init(file: file, maximumDuration: maximumDuration)
        } catch {
            try? file.close()
            throw error
        }
    }

    init(file: FileHandle, maximumDuration: TimeInterval) throws {
        let duration = min(maximumDuration, 60 * 60)
        guard duration.isFinite, duration > 0 else {
            throw EncounterTelecallRecordingIssue.durationExceeded
        }
        do {
            self.file = file
            self.maximumDuration = duration
            maximumFrames = Int64((duration * Self.sampleRate).rounded(.down))
            try file.write(contentsOf: Self.header(dataByteCount: 0))
        } catch {
            throw EncounterTelecallRecordingIssue.fileWriteFailed
        }
    }

    func write(
        _ input: AVAudioPCMBuffer,
        timestamp: CMTime,
        origin: CMTime,
        source: EncounterTelecallAudioSource
    ) throws {
        guard !isClosed else { throw EncounterTelecallRecordingIssue.fileWriteFailed }
        guard timestamp.isValid, timestamp.isNumeric, origin.isValid, origin.isNumeric else {
            throw EncounterTelecallRecordingIssue.invalidTimestamp
        }
        if let previousEnd = sourceEndTime[source], CMTimeCompare(timestamp, previousEnd) < 0 {
            throw EncounterTelecallRecordingIssue.timestampRegression
        }
        let relative = CMTimeSubtract(timestamp, origin)
        guard relative.isValid, relative.isNumeric, CMTimeCompare(relative, .zero) >= 0 else {
            throw EncounterTelecallRecordingIssue.invalidTimestamp
        }
        let seconds = CMTimeGetSeconds(relative)
        guard seconds.isFinite, seconds <= maximumDuration else {
            throw EncounterTelecallRecordingIssue.durationExceeded
        }
        let startFrame = Int64((seconds * Self.sampleRate).rounded())
        let inputDuration = Double(input.frameLength) / input.format.sampleRate
        let sourceEndFrame = Int64(((seconds + inputDuration) * Self.sampleRate).rounded())
        let convertedFrameCount = sourceEndFrame - startFrame
        guard convertedFrameCount > 0, convertedFrameCount <= Int64(UInt32.max) else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        let converted = try Self.convert(input, frameCount: AVAudioFrameCount(convertedFrameCount))
        let requestedEndFrame = startFrame + Int64(converted.frameLength)
        guard startFrame < maximumFrames else {
            throw EncounterTelecallRecordingIssue.durationExceeded
        }
        let endFrame = min(requestedEndFrame, maximumFrames)
        let framesToWrite = Int(endFrame - startFrame)
        guard Self.headerByteCount + UInt64(endFrame) * 2 <= Self.maximumFileByteCount else {
            throw EncounterTelecallRecordingIssue.durationExceeded
        }

        do {
            try mix(converted, frameCount: framesToWrite, at: startFrame)
            frameCount = max(frameCount, endFrame)
            sourceEndTime[source] = CMTimeAdd(
                timestamp,
                CMTime(value: Int64(input.frameLength), timescale: CMTimeScale(input.format.sampleRate))
            )
            try updateHeader()
        } catch let issue as EncounterTelecallRecordingIssue {
            throw issue
        } catch {
            throw EncounterTelecallRecordingIssue.fileWriteFailed
        }
        if requestedEndFrame > maximumFrames {
            throw EncounterTelecallRecordingIssue.durationExceeded
        }
    }

    func finish() throws {
        guard !isClosed else { return }
        do {
            try updateHeader()
            try file.synchronize()
            try file.close()
            isClosed = true
        } catch {
            isClosed = true
            try? file.close()
            throw EncounterTelecallRecordingIssue.fileWriteFailed
        }
    }

    private func mix(_ buffer: AVAudioPCMBuffer, frameCount sampleCount: Int, at startFrame: Int64) throws {
        guard let samples = buffer.floatChannelData?[0] else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        let byteOffset = Self.headerByteCount + UInt64(startFrame) * 2
        try file.seek(toOffset: byteOffset)
        let existing = try file.read(upToCount: sampleCount * 2) ?? Data()
        var mixed = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let old: Int16
            let offset = index * 2
            if offset + 1 < existing.count {
                old = Int16(bitPattern: UInt16(existing[offset]) | UInt16(existing[offset + 1]) << 8)
            } else {
                old = 0
            }
            guard samples[index].isFinite else {
                throw EncounterTelecallRecordingIssue.invalidAudio
            }
            let addition = Int32((max(-1, min(1, samples[index])) * 0.5 * 32_767).rounded())
            let value = Int16(clamping: Int32(old) + addition)
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { mixed.append(contentsOf: $0) }
        }
        try file.seek(toOffset: byteOffset)
        try file.write(contentsOf: mixed)
    }

    private func updateHeader() throws {
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(dataByteCount: UInt32(frameCount * 2)))
    }

    static func convert(
        _ input: AVAudioPCMBuffer,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard input.frameLength > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        converter.primeMethod = .none
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        let provider = EncounterTelecallConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provider.wasSupplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            provider.wasSupplied = true
            inputStatus.pointee = .haveData
            return provider.buffer
        }
        guard conversionError == nil, status != .error, output.frameLength == frameCount else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        return output
    }

    private static func header(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(36 &+ dataByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

final class EncounterTelecallStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "org.openpep.encounter-telecall-audio")

    private let writer: EncounterTelecallWAVWriter
    private let eventHandler: @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    private let stableChunkHandler: (@Sendable (EncounterAudioChunk) -> Void)?
    private var liveMixer: EncounterStabilizedAudioMixer?
    private var origin: CMTime?
    private var timer: DispatchSourceTimer?
    private var isFinished = false
    private var sourcesSeen: Set<EncounterTelecallAudioSource> = []
    private let maximumDuration: TimeInterval
    private var finalEvent: EncounterMicrophoneCaptureEvent?

    init(
        writer: EncounterTelecallWAVWriter,
        maximumDuration: TimeInterval,
        stableChunkHandler: (@Sendable (EncounterAudioChunk) -> Void)? = nil,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) {
        self.writer = writer
        self.maximumDuration = maximumDuration
        self.stableChunkHandler = stableChunkHandler
        if stableChunkHandler != nil {
            let format = try! EncounterAudioFormat(
                sampleRate: Int(EncounterTelecallWAVWriter.sampleRate), channelCount: 1
            )
            liveMixer = try? EncounterStabilizedAudioMixer(format: format)
        }
        self.eventHandler = eventHandler
    }

    func setOrigin(_ origin: CMTime) {
        queue.sync { self.origin = origin }
    }

    func startDurationLimit() {
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.maximumDuration)
            timer.setEventHandler { [weak self] in self?.finishOnQueue(event: .finished, notify: true) }
            self.timer = timer
            timer.resume()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        receive(sampleBuffer, of: type)
    }

    /// Called on the capture queue; separate from SCStream ownership for replay tests.
    func receive(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isFinished, let origin else { return }
        let source: EncounterTelecallAudioSource
        switch type {
        case .audio: source = .application
        case .microphone: source = .microphone
        default: return
        }
        do {
            let buffer = try Self.audioBuffer(from: sampleBuffer)
            let converted = try EncounterTelecallWAVWriter.convert(
                buffer,
                frameCount: AVAudioFrameCount((Double(buffer.frameLength) / buffer.format.sampleRate
                    * EncounterTelecallWAVWriter.sampleRate).rounded())
            )
            try writer.write(
                converted,
                timestamp: sampleBuffer.presentationTimeStamp,
                origin: origin,
                source: source
            )
            try emitStableChunk(
                converted,
                timestamp: sampleBuffer.presentationTimeStamp,
                origin: origin,
                source: source
            )
            sourcesSeen.insert(source)
        } catch EncounterTelecallRecordingIssue.durationExceeded {
            sourcesSeen.insert(source)
            finishOnQueue(event: .finished, notify: true)
        } catch {
            finishOnQueue(event: .failed, notify: true)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in self?.finishOnQueue(event: .failed, notify: true) }
    }

    func finish(event: EncounterMicrophoneCaptureEvent, notify: Bool) async -> EncounterMicrophoneCaptureEvent {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.finishOnQueue(event: event, notify: notify)
                continuation.resume(returning: self?.finalEvent ?? .failed)
            }
        }
    }

    private func finishOnQueue(event: EncounterMicrophoneCaptureEvent, notify: Bool) {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        timer = nil
        let resolvedEvent: EncounterMicrophoneCaptureEvent
        do {
            if let stable = try liveMixer?.finish(monotonicTime: ProcessInfo.processInfo.systemUptime) {
                stableChunkHandler?(stable)
            }
            try writer.finish()
            resolvedEvent = event == .finished && sourcesSeen.isEmpty ? .failed : event
        } catch {
            resolvedEvent = .failed
        }
        finalEvent = resolvedEvent
        if notify { eventHandler(resolvedEvent) }
    }

    private static func audioBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let description = sampleBuffer.formatDescription else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        buffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        ) == noErr else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        return buffer
    }

    private func emitStableChunk(
        _ buffer: AVAudioPCMBuffer,
        timestamp: CMTime,
        origin: CMTime,
        source: EncounterTelecallAudioSource
    ) throws {
        guard var liveMixer, let stableChunkHandler else { return }
        let relative = CMTimeSubtract(timestamp, origin)
        let seconds = CMTimeGetSeconds(relative)
        guard seconds.isFinite, seconds >= 0,
              let samples = buffer.floatChannelData?.pointee else {
            throw EncounterTelecallRecordingIssue.invalidAudio
        }
        var pcm16 = Data(capacity: Int(buffer.frameLength) * 2)
        var totalSquare = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let sample = max(-1, min(1, samples[index]))
            totalSquare += Double(sample * sample)
            var value = Int16((sample * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm16.append(contentsOf: $0) }
        }
        let mappedSource: EncounterAudioSource = source == .microphone ? .microphone : .application
        let chunk = try EncounterAudioChunk(
            pcm16: pcm16,
            samplePosition: Int64((seconds * EncounterTelecallWAVWriter.sampleRate).rounded()),
            monotonicTime: ProcessInfo.processInfo.systemUptime,
            format: try EncounterAudioFormat(
                sampleRate: Int(EncounterTelecallWAVWriter.sampleRate), channelCount: 1
            ),
            source: mappedSource,
            level: min(1, sqrt(totalSquare / Double(max(1, buffer.frameLength))))
        )
        try liveMixer.append(chunk)
        if let stable = try liveMixer.drainStable(monotonicTime: ProcessInfo.processInfo.systemUptime) {
            stableChunkHandler(stable)
        }
        self.liveMixer = liveMixer
    }
}

private final class EncounterTelecallConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
