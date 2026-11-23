// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFAudio
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

struct TeleconsultAudioApplication: Identifiable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let processIdentifier: Int32

    static let allSystemAudio = Self(name: "Áudio do Mac", bundleIdentifier: "org.openpep.all-system-audio", processIdentifier: 0)
    var capturesAllSystemAudio: Bool { self == Self.allSystemAudio }

    var id: String { "\(bundleIdentifier):\(processIdentifier)" }

    var isBrowser: Bool {
        bundleIdentifier == "com.apple.Safari" || bundleIdentifier.hasPrefix("com.google.Chrome")
    }
}

struct TeleconsultAudioLevels: Equatable, Sendable {
    var application = 0.0
    var microphone = 0.0
}

enum TeleconsultAudioProbeState: Equatable, Sendable {
    case idle
    case loadingApplications
    case ready
    case starting
    case capturing
    case stopping
    case failed(String)
}

enum TeleconsultAudioProbeIssue: Error, LocalizedError, Equatable, Sendable {
    case noSupportedApplication
    case selectedApplicationUnavailable
    case contentUnavailable
    case noDisplay
    case outputSetup
    case startFailed
    case stoppedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .noSupportedApplication:
            "Abra o FaceTime, Safari ou Google Chrome e atualize a lista."
        case .selectedApplicationUnavailable:
            "O aplicativo escolhido não está mais disponível. Atualize a lista e tente novamente."
        case .contentUnavailable:
            "O macOS não forneceu a lista de aplicativos. Confira a permissão de Gravação da Tela e tente novamente."
        case .noDisplay:
            "Nenhuma tela disponível foi encontrada para limitar a captura ao aplicativo escolhido."
        case .outputSetup:
            "O macOS não preparou os medidores de áudio. A captura foi interrompida."
        case .startFailed:
            "O macOS não iniciou a captura. Confira as permissões de Gravação da Tela e Microfone."
        case .stoppedUnexpectedly:
            "A captura foi interrompida pelo macOS. Nenhum áudio foi salvo."
        }
    }
}

@MainActor
protocol TeleconsultAudioCapturing: AnyObject {
    func availableApplications() async throws -> [TeleconsultAudioApplication]
    func start(
        application: TeleconsultAudioApplication,
        levelHandler: @escaping @Sendable (TeleconsultAudioLevels) -> Void,
        stopHandler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async
}

@MainActor
final class TeleconsultAudioProbeModel: ObservableObject {
    @Published private(set) var applications: [TeleconsultAudioApplication] = []
    @Published var selectedApplicationID: String?
    @Published var confirmsSyntheticConsent = false
    @Published private(set) var levels = TeleconsultAudioLevels()
    @Published private(set) var state: TeleconsultAudioProbeState = .idle

    private let capture: any TeleconsultAudioCapturing
    private var generation: UInt = 0

    init(capture: any TeleconsultAudioCapturing) {
        self.capture = capture
    }

    convenience init() {
        self.init(capture: AppleTeleconsultAudioCapture())
    }

    var selectedApplication: TeleconsultAudioApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    var canStart: Bool {
        state == .ready && selectedApplication != nil && confirmsSyntheticConsent
    }

    func loadApplications() async {
        guard state != .capturing && state != .starting && state != .stopping else { return }
        state = .loadingApplications
        do {
            applications = try await capture.availableApplications()
            if !applications.contains(where: { $0.id == selectedApplicationID }) {
                selectedApplicationID = applications.first?.id
                confirmsSyntheticConsent = false
            }
            state = applications.isEmpty
                ? .failed(TeleconsultAudioProbeIssue.noSupportedApplication.localizedDescription)
                : .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func start() async {
        guard canStart, let application = selectedApplication else { return }
        generation &+= 1
        let operationGeneration = generation
        levels = TeleconsultAudioLevels()
        state = .starting

        do {
            try await withTaskCancellationHandler {
                try await capture.start(
                    application: application,
                    levelHandler: { [weak self] levels in
                        Task { @MainActor in
                            guard let self,
                                  self.generation == operationGeneration,
                                  self.state == .starting || self.state == .capturing else { return }
                            self.levels = levels
                        }
                    },
                    stopHandler: { [weak self] in
                        Task { @MainActor in
                            guard let self,
                                  self.generation == operationGeneration,
                                  self.state == .starting || self.state == .capturing else { return }
                            await self.capture.stop()
                            self.levels = TeleconsultAudioLevels()
                            self.state = .failed(
                                TeleconsultAudioProbeIssue.stoppedUnexpectedly.localizedDescription
                            )
                        }
                    }
                )
                try Task.checkCancellation()
            } onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == operationGeneration else { return }
                    await self.capture.stop()
                }
            }
            guard generation == operationGeneration else {
                return
            }
            state = .capturing
        } catch is CancellationError {
            guard generation == operationGeneration else { return }
            await capture.stop()
            levels = TeleconsultAudioLevels()
            state = applications.isEmpty ? .idle : .ready
        } catch {
            guard generation == operationGeneration else { return }
            await capture.stop()
            levels = TeleconsultAudioLevels()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard state == .capturing || state == .starting || state == .stopping else { return }
        generation &+= 1
        state = .stopping
        await capture.stop()
        levels = TeleconsultAudioLevels()
        confirmsSyntheticConsent = false
        state = applications.isEmpty ? .idle : .ready
    }

    func dismiss() async {
        generation &+= 1
        await capture.stop()
        levels = TeleconsultAudioLevels()
        confirmsSyntheticConsent = false
        state = .idle
    }
}

@MainActor
final class AppleTeleconsultAudioCapture: TeleconsultAudioCapturing {
    private var stream: SCStream?
    private var output: TeleconsultAudioStreamOutput?
    private var activeSessionID: UUID?

    func availableApplications() async throws -> [TeleconsultAudioApplication] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TeleconsultAudioProbeIssue.contentUnavailable
        }
        return content.applications
            .filter(TeleconsultAudioCaptureSupport.isSupported)
            .map(TeleconsultAudioCaptureSupport.application)
            .sorted(by: TeleconsultAudioCaptureSupport.sortApplications)
    }

    func start(
        application: TeleconsultAudioApplication,
        levelHandler: @escaping @Sendable (TeleconsultAudioLevels) -> Void,
        stopHandler: @escaping @Sendable () -> Void
    ) async throws {
        await stop()
        try Task.checkCancellation()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TeleconsultAudioProbeIssue.startFailed
        }
        try Task.checkCancellation()
        guard let selected = content.applications.first(where: {
            $0.processID == application.processIdentifier
                && $0.bundleIdentifier == application.bundleIdentifier
                && TeleconsultAudioCaptureSupport.isSupported($0)
        }) else {
            throw TeleconsultAudioProbeIssue.selectedApplicationUnavailable
        }
        guard let display = TeleconsultAudioCaptureSupport.display(for: selected, in: content) else {
            throw TeleconsultAudioProbeIssue.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            including: [selected],
            exceptingWindows: []
        )
        let configuration = TeleconsultAudioCaptureSupport.configuration(
            streamName: "OpenPEP — diagnóstico sintético de áudio"
        )

        let sessionID = UUID()
        let output = TeleconsultAudioStreamOutput(
            levelHandler: { [weak self] levels in
                Task { @MainActor in
                    guard self?.activeSessionID == sessionID else { return }
                    levelHandler(levels)
                }
            },
            stopHandler: { [weak self] in
                Task { @MainActor in
                    guard self?.activeSessionID == sessionID else { return }
                    stopHandler()
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        activeSessionID = sessionID
        self.output = output
        self.stream = stream

        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        } catch {
            await stop(stream, sessionID: sessionID)
            throw TeleconsultAudioProbeIssue.outputSetup
        }

        do {
            try Task.checkCancellation()
            try await stream.startCapture()
            try Task.checkCancellation()
            guard activeSessionID == sessionID else {
                await stop(stream, sessionID: sessionID)
                throw CancellationError()
            }
        } catch is CancellationError {
            await stop(stream, sessionID: sessionID)
            throw CancellationError()
        } catch {
            await stop(stream, sessionID: sessionID)
            if error is TeleconsultAudioProbeIssue { throw error }
            throw TeleconsultAudioProbeIssue.startFailed
        }
    }

    func stop() async {
        guard let stream, let sessionID = activeSessionID else {
            output = nil
            return
        }
        activeSessionID = nil
        self.stream = nil
        self.output = nil
        await stop(stream, sessionID: sessionID)
    }

    private func stop(_ stream: SCStream, sessionID: UUID) async {
        try? await stream.stopCapture()
        if activeSessionID == sessionID {
            activeSessionID = nil
            self.stream = nil
            output = nil
        }
    }

}

enum TeleconsultAudioCaptureSupport {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
    ]

    static func isSupported(_ application: SCRunningApplication) -> Bool {
        supportedBundleIdentifiers.contains(application.bundleIdentifier)
    }

    static func application(_ application: SCRunningApplication) -> TeleconsultAudioApplication {
        TeleconsultAudioApplication(
            name: application.applicationName,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processID
        )
    }

    static func sortApplications(
        _ left: TeleconsultAudioApplication,
        _ right: TeleconsultAudioApplication
    ) -> Bool {
        left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }

    static func display(
        for application: SCRunningApplication,
        in content: SCShareableContent
    ) -> SCDisplay? {
        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == application.processID
        }
        if let window = appWindows.first,
           let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
            return display
        }
        return content.displays.first
    }

    static func configuration(streamName: String) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.streamName = streamName
        return configuration
    }
}

final class TeleconsultAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "org.openpep.teleconsult-audio-probe")

    private let levelHandler: @Sendable (TeleconsultAudioLevels) -> Void
    private let stopHandler: @Sendable () -> Void
    private var levels = TeleconsultAudioLevels()
    private var lastApplicationDelivery = 0.0
    private var lastMicrophoneDelivery = 0.0

    init(
        levelHandler: @escaping @Sendable (TeleconsultAudioLevels) -> Void,
        stopHandler: @escaping @Sendable () -> Void
    ) {
        self.levelHandler = levelHandler
        self.stopHandler = stopHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard let level = Self.normalizedRMS(in: sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .audio where now - lastApplicationDelivery >= 0.1:
            levels.application = level
            lastApplicationDelivery = now
            levelHandler(levels)
        case .microphone where now - lastMicrophoneDelivery >= 0.1:
            levels.microphone = level
            lastMicrophoneDelivery = now
            levelHandler(levels)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stopHandler()
    }

    static func normalizedRMS(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        } / Double(samples.count)
        return min(max(sqrt(meanSquare), 0), 1)
    }

    private static func normalizedRMS(in sampleBuffer: CMSampleBuffer) -> Double? {
        guard sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let description = sampleBuffer.formatDescription else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        ) == noErr else {
            return nil
        }

        var sumSquares = 0.0
        var sampleCount = 0
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in audioBuffers {
                guard let rawData = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride
                let data = rawData.assumingMemoryBound(to: Float.self)
                for index in 0..<count { sumSquares += Double(data[index] * data[index]) }
                sampleCount += count
            }
        case .pcmFormatInt16:
            for audioBuffer in audioBuffers {
                guard let rawData = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.stride
                let data = rawData.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let sample = Double(data[index]) / Double(Int16.max)
                    sumSquares += sample * sample
                }
                sampleCount += count
            }
        case .pcmFormatInt32:
            for audioBuffer in audioBuffers {
                guard let rawData = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.stride
                let data = rawData.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let sample = Double(data[index]) / Double(Int32.max)
                    sumSquares += sample * sample
                }
                sampleCount += count
            }
        case .pcmFormatFloat64:
            for audioBuffer in audioBuffers {
                guard let rawData = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.stride
                let data = rawData.assumingMemoryBound(to: Double.self)
                for index in 0..<count { sumSquares += data[index] * data[index] }
                sampleCount += count
            }
        default:
            return nil
        }
        guard sampleCount > 0 else { return nil }
        return min(max(sqrt(sumSquares / Double(sampleCount)), 0), 1)
    }
}
