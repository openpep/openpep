// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

private final class AppleAudioInputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer?
    private var supplied = false

    init(buffer: AVAudioPCMBuffer?) { self.buffer = buffer }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = buffer == nil ? .endOfStream : .noDataNow
            return nil
        }
        supplied = true
        guard let buffer else {
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}

/// AVAudioConverter is stateful. One instance is retained for the complete
/// capture so resampling cannot lose priming or trailing frames between chunks.
private final class AppleLiveAudioConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var nextOutputTime: CMTime?

    init(targetFormat: AVAudioFormat) { self.targetFormat = targetFormat }

    func convert(_ chunk: EncounterAudioChunk) throws -> [AnalyzerInput] {
        let source = try sourceBuffer(from: chunk)
        if converter == nil {
            sourceFormat = source.format
            converter = AVAudioConverter(from: source.format, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard sourceFormat == source.format else { throw LocalTranscriptionIssue.engineFailure }
        if nextOutputTime == nil {
            nextOutputTime = CMTime(value: chunk.samplePosition, timescale: CMTimeScale(chunk.format.sampleRate))
        }
        return try convert(provider: AppleAudioInputProvider(buffer: source), expectedInputFrames: source.frameLength)
    }

    func flush() throws -> [AnalyzerInput] {
        guard converter != nil else { return [] }
        return try convert(provider: AppleAudioInputProvider(buffer: nil), expectedInputFrames: 0)
    }

    private func convert(
        provider: AppleAudioInputProvider,
        expectedInputFrames: AVAudioFrameCount
    ) throws -> [AnalyzerInput] {
        guard let converter else { throw LocalTranscriptionIssue.engineFailure }
        let ratio = targetFormat.sampleRate / max(1, sourceFormat?.sampleRate ?? targetFormat.sampleRate)
        let capacity = max(256, AVAudioFrameCount(ceil(Double(expectedInputFrames) * ratio) + 64))
        var inputs: [AnalyzerInput] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw LocalTranscriptionIssue.engineFailure
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                provider.next(status: status)
            }
            guard conversionError == nil, status != .error else {
                throw LocalTranscriptionIssue.engineFailure
            }
            if output.frameLength > 0 {
                let start = nextOutputTime ?? .zero
                inputs.append(AnalyzerInput(buffer: output, bufferStartTime: start))
                nextOutputTime = CMTimeAdd(
                    start,
                    CMTime(value: CMTimeValue(output.frameLength), timescale: CMTimeScale(targetFormat.sampleRate))
                )
            }
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { break }
        }
        return inputs
    }

    private func sourceBuffer(from chunk: EncounterAudioChunk) throws -> AVAudioPCMBuffer {
        guard chunk.format.channelCount == 1,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(chunk.format.sampleRate),
                channels: 1,
                interleaved: false
              ), let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunk.frameCount)
              ), let channels = buffer.int16ChannelData else {
            throw LocalTranscriptionIssue.engineFailure
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channels[0], base, raw.count)
        }
        return buffer
    }
}

enum AppleLiveTranscriptionEvent: Equatable, Sendable {
    case partial(text: String)
    case final(text: String, startSeconds: Double, endSeconds: Double)
    case failed(LocalTranscriptionIssue)
}

struct AppleLiveResultSnapshot: Equatable, Sendable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

struct AppleLiveResultStabilizer: Sendable {
    private(set) var volatile: [AppleLiveResultSnapshot] = []

    mutating func receive(
        _ result: AppleLiveResultSnapshot,
        finalizedThrough seconds: Double
    ) -> [AppleLiveResultSnapshot] {
        volatile.removeAll {
            $0.startSeconds < result.endSeconds && result.startSeconds < $0.endSeconds
        }
        volatile.append(result)
        volatile.sort { $0.startSeconds < $1.startSeconds }
        guard seconds.isFinite else { return [] }
        let stabilized = volatile.filter { $0.endSeconds <= seconds }
        volatile.removeAll { $0.endSeconds <= seconds }
        return stabilized
    }

    mutating func finish() -> [AppleLiveResultSnapshot] {
        defer { volatile.removeAll() }
        return volatile
    }

    var provisionalText: String {
        volatile.map(\.text).joined(separator: " ")
    }
}

@MainActor
protocol AppleLiveTranscribing: AnyObject {
    func start(locale: Locale) async throws
    func enqueue(_ chunk: EncounterAudioChunk) -> Bool
    func finish() async throws
    func cancel() async
}

/// Feeds the already-copied local PCM timeline to SpeechAnalyzer. It never owns
/// the microphone or the WAV, so recognition failure cannot stop local capture.
@MainActor
final class AppleLiveTranscription: AppleLiveTranscribing {
    static let maximumQueuedChunks = 256
    static let finishTimeout: TimeInterval = 15

    private let eventHandler: @MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void
    private var inputContinuation: AsyncStream<EncounterAudioChunk>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var generation: UInt = 0
    private var acceptsAudio = false
    private var reportedFailure = false
    private var analysisFinished = false
    private var resultsFinished = false

    init(eventHandler: @escaping @MainActor @Sendable (AppleLiveTranscriptionEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func start(locale: Locale = LocalTranscriptionService.portugueseBrazil) async throws {
        guard analyzer == nil else { throw LocalTranscriptionIssue.alreadyTranscribing }
        guard SpeechTranscriber.isAvailable else { throw LocalTranscriptionIssue.speechUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LocalTranscriptionIssue.localeUnsupported(locale.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
        try await prepareAssets(for: transcriber, locale: supported)
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LocalTranscriptionIssue.engineFailure
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: targetFormat)

        generation &+= 1
        let operationGeneration = generation
        let (stream, continuation) = AsyncStream.makeStream(
            of: EncounterAudioChunk.self,
            bufferingPolicy: .bufferingOldest(Self.maximumQueuedChunks)
        )
        self.analyzer = analyzer
        inputContinuation = continuation
        acceptsAudio = true
        reportedFailure = false
        analysisFinished = false
        resultsFinished = false

        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let inputs = AsyncThrowingStream<AnalyzerInput, any Error> { analyzerContinuation in
                    let conversionTask = Task.detached(priority: .userInitiated) {
                        do {
                            let converter = AppleLiveAudioConverter(targetFormat: targetFormat)
                            for await chunk in stream {
                                try Task.checkCancellation()
                                for input in try converter.convert(chunk) { analyzerContinuation.yield(input) }
                            }
                            for input in try converter.flush() { analyzerContinuation.yield(input) }
                            analyzerContinuation.finish()
                        } catch {
                            analyzerContinuation.finish(throwing: error)
                        }
                    }
                    analyzerContinuation.onTermination = { _ in conversionTask.cancel() }
                }
                if let lastAudioTime = try await analyzer.analyzeSequence(inputs) {
                    try await analyzer.finalizeAndFinish(through: lastAudioTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                await self?.taskFinished(.analysis, generation: operationGeneration, failed: false)
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
                await self?.taskFinished(.analysis, generation: operationGeneration, failed: false)
            } catch {
                await analyzer.cancelAndFinishNow()
                await self?.taskFinished(.analysis, generation: operationGeneration, failed: true)
            }
        }
        resultsTask = Task.detached(priority: .userInitiated) { [weak self] in
            var stabilizer = AppleLiveResultStabilizer()
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let snapshot = AppleLiveResultSnapshot(
                        text: String(result.text.characters),
                        startSeconds: CMTimeGetSeconds(result.range.start),
                        endSeconds: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    )
                    guard snapshot.startSeconds.isFinite, snapshot.endSeconds.isFinite,
                          snapshot.endSeconds > snapshot.startSeconds else { continue }
                    let stabilized = stabilizer.receive(
                        snapshot,
                        finalizedThrough: CMTimeGetSeconds(result.resultsFinalizationTime)
                    )
                    await self?.emit(
                        stabilized: stabilized,
                        provisional: stabilizer.provisionalText,
                        generation: operationGeneration
                    )
                }
                await self?.emit(
                    stabilized: stabilizer.finish(),
                    provisional: "",
                    generation: operationGeneration
                )
                await self?.taskFinished(.results, generation: operationGeneration, failed: false)
            } catch is CancellationError {
                await self?.taskFinished(.results, generation: operationGeneration, failed: false)
            } catch {
                await self?.taskFinished(.results, generation: operationGeneration, failed: true)
            }
        }
    }

    func enqueue(_ chunk: EncounterAudioChunk) -> Bool {
        guard acceptsAudio, let inputContinuation else { return false }
        switch inputContinuation.yield(chunk) {
        case .enqueued: return true
        case .dropped, .terminated: return false
        @unknown default: return false
        }
    }

    func finish() async throws {
        acceptsAudio = false
        inputContinuation?.finish()
        inputContinuation = nil
        let deadline = Date().addingTimeInterval(Self.finishTimeout)
        while !(analysisFinished && resultsFinished), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard analysisFinished && resultsFinished else {
            generation &+= 1
            analysisTask?.cancel()
            resultsTask?.cancel()
            let stalledAnalyzer = analyzer
            clear()
            Task.detached { await stalledAnalyzer?.cancelAndFinishNow() }
            throw LocalTranscriptionIssue.engineFailure
        }
        let failed = reportedFailure
        clear()
        if failed { throw LocalTranscriptionIssue.engineFailure }
    }

    func cancel() async {
        generation &+= 1
        acceptsAudio = false
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        resultsTask?.cancel()
        let cancelledAnalyzer = analyzer
        clear()
        Task.detached { await cancelledAnalyzer?.cancelAndFinishNow() }
    }

    private enum TaskKind { case analysis, results }

    private func prepareAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await request.downloadAndInstall()
                }
                guard await AssetInventory.status(forModules: modules) == .installed else {
                    throw LocalTranscriptionIssue.assetInstallationFailed(locale.identifier(.bcp47))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let issue as LocalTranscriptionIssue {
                throw issue
            } catch {
                throw LocalTranscriptionIssue.assetInstallationFailed(locale.identifier(.bcp47))
            }
        case .unsupported:
            throw LocalTranscriptionIssue.localeUnsupported(locale.identifier(.bcp47))
        @unknown default:
            throw LocalTranscriptionIssue.assetInstallationFailed(locale.identifier(.bcp47))
        }
    }

    private func taskFinished(_ kind: TaskKind, generation operationGeneration: UInt, failed: Bool) {
        guard generation == operationGeneration else { return }
        if failed, !reportedFailure {
            reportedFailure = true
            acceptsAudio = false
            eventHandler(.failed(.engineFailure))
        }
        switch kind {
        case .analysis: analysisFinished = true
        case .results: resultsFinished = true
        }
    }

    private func emit(
        stabilized: [AppleLiveResultSnapshot],
        provisional: String,
        generation operationGeneration: UInt
    ) {
        guard generation == operationGeneration, !reportedFailure else { return }
        for result in stabilized {
            eventHandler(.final(
                text: result.text,
                startSeconds: result.startSeconds,
                endSeconds: result.endSeconds
            ))
        }
        eventHandler(.partial(text: provisional))
    }

    private func clear() {
        acceptsAudio = false
        inputContinuation = nil
        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        analysisFinished = false
        resultsFinished = false
    }

    nonisolated static func makeInput(
        from chunk: EncounterAudioChunk,
        targetFormat: AVAudioFormat
    ) throws -> AnalyzerInput {
        guard let input = try AppleLiveAudioConverter(targetFormat: targetFormat).convert(chunk).first else {
            throw LocalTranscriptionIssue.engineFailure
        }
        return input
    }
}
