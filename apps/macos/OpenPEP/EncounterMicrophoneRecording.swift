// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Combine
import Foundation

enum EncounterMicrophoneRecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case recorded
    case failed(String)
}

enum EncounterMicrophoneCaptureEvent: Equatable, Sendable {
    case finished
    case failed
}

enum EncounterMicrophoneRecordingIssue: Error, LocalizedError, Equatable, Sendable {
    case consentRequired
    case invalidDestination
    case destinationExists
    case permissionDenied
    case startFailed

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Confirme o consentimento dos participantes e o uso de conteúdo sintético antes de gravar."
        case .invalidDestination:
            "Escolha um novo arquivo M4A para guardar a gravação."
        case .destinationExists:
            "Já existe um arquivo nesse destino. Escolha outro nome para não substituir o conteúdo existente."
        case .permissionDenied:
            "O acesso ao microfone não foi autorizado. A gravação não começou."
        case .startFailed:
            "O microfone não iniciou a gravação. Qualquer áudio criado foi preservado no destino escolhido."
        }
    }
}

@MainActor
protocol EncounterMicrophoneCapturing: AnyObject {
    func requestAccess() async -> Bool
    func startRecording(
        at url: URL,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) throws
    func stopRecording()
}

@MainActor
final class EncounterMicrophoneRecordingModel: ObservableObject {
    static let maximumDuration: TimeInterval = 60 * 60

    @Published private(set) var state: EncounterMicrophoneRecordingState = .idle
    @Published private(set) var recordedURL: URL?
    @Published private(set) var status = "Escolha onde guardar o áudio sintético antes de iniciar."

    private let capture: any EncounterMicrophoneCapturing
    private var generation: UInt = 0
    private var activeURL: URL?
    private var stopRequested = false

    init(capture: any EncounterMicrophoneCapturing) {
        self.capture = capture
    }

    convenience init() {
        self.init(capture: AppleEncounterMicrophoneCapture())
    }

    func start(at url: URL, consent: Bool) async {
        guard recordedURL == nil,
              state != .requestingPermission,
              state != .recording else { return }
        guard consent else {
            fail(EncounterMicrophoneRecordingIssue.consentRequired)
            return
        }
        guard !Task.isCancelled else {
            state = .idle
            status = "Gravação cancelada antes de começar."
            return
        }

        do {
            try validateNewDestination(url)
        } catch {
            fail(error)
            return
        }

        generation &+= 1
        let sessionGeneration = generation
        activeURL = nil
        stopRequested = false
        state = .requestingPermission
        status = "Solicitando acesso ao microfone…"

        let authorized = await capture.requestAccess()
        guard generation == sessionGeneration, state == .requestingPermission else { return }
        guard !Task.isCancelled else {
            generation &+= 1
            state = .idle
            status = "Gravação cancelada antes de começar."
            return
        }
        guard authorized else {
            fail(EncounterMicrophoneRecordingIssue.permissionDenied)
            return
        }

        do {
            try validateNewDestination(url)
            try capture.startRecording(
                at: url,
                maximumDuration: Self.maximumDuration,
                eventHandler: { [weak self] event in
                    Task { @MainActor in
                        self?.receive(event, at: url, generation: sessionGeneration)
                    }
                }
            )
            guard generation == sessionGeneration else {
                capture.stopRecording()
                return
            }
            activeURL = url
            state = .recording
            status = "Gravando pelo microfone… limite de 60 minutos."
        } catch {
            if error as? EncounterMicrophoneRecordingIssue == .startFailed {
                recordedURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            activeURL = nil
            fail(error)
        }
    }

    func stop() {
        if state == .requestingPermission {
            generation &+= 1
            activeURL = nil
            stopRequested = false
            capture.stopRecording()
            state = .idle
            status = "Gravação cancelada antes de começar."
            return
        }
        guard state == .recording, !stopRequested else { return }
        stopRequested = true
        status = "Finalizando gravação…"
        capture.stopRecording()
    }

    func dismiss() {
        generation &+= 1
        if state == .recording || state == .requestingPermission {
            capture.stopRecording()
        }
        activeURL = nil
        stopRequested = false
        state = .idle
        status = recordedURL == nil
            ? "Gravação encerrada."
            : "Gravação encerrada. O áudio permanece no destino escolhido."
    }

    func reset() {
        dismiss()
        recordedURL = nil
        status = "Escolha onde guardar o áudio sintético antes de iniciar."
    }

    private func receive(
        _ event: EncounterMicrophoneCaptureEvent,
        at url: URL,
        generation sessionGeneration: UInt
    ) {
        guard generation == sessionGeneration,
              state == .recording,
              activeURL?.standardizedFileURL == url.standardizedFileURL else { return }
        activeURL = nil
        stopRequested = false
        recordedURL = url
        switch event {
        case .finished:
            state = .recorded
            status = "Gravação encerrada. O áudio foi preservado no destino escolhido."
        case .failed:
            let message = "A gravação foi interrompida. O áudio disponível foi preservado no destino escolhido."
            state = .failed(message)
            status = message
        }
    }

    private func validateNewDestination(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a" else {
            throw EncounterMicrophoneRecordingIssue.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EncounterMicrophoneRecordingIssue.destinationExists
        }
    }

    private func fail(_ error: any Error) {
        let message = error.localizedDescription
        state = .failed(message)
        status = message
    }
}

@MainActor
final class AppleEncounterMicrophoneCapture: NSObject, EncounterMicrophoneCapturing,
    @preconcurrency AVAudioRecorderDelegate
{
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    private var recorder: AVAudioRecorder?
    private var eventHandler: (@Sendable (EncounterMicrophoneCaptureEvent) -> Void)?

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    func startRecording(
        at url: URL,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) throws {
        guard recorder == nil else { throw EncounterMicrophoneRecordingIssue.startFailed }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EncounterMicrophoneRecordingIssue.destinationExists
        }

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        } catch {
            throw EncounterMicrophoneRecordingIssue.startFailed
        }
        recorder.delegate = self
        self.recorder = recorder
        self.eventHandler = eventHandler
        guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
            self.recorder = nil
            self.eventHandler = nil
            recorder.delegate = nil
            recorder.stop()
            throw EncounterMicrophoneRecordingIssue.startFailed
        }
    }

    func stopRecording() {
        recorder?.stop()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finish(recorder, event: flag ? .finished : .failed)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        finish(recorder, event: .failed)
        recorder.stop()
    }

    private func finish(_ finishedRecorder: AVAudioRecorder, event: EncounterMicrophoneCaptureEvent) {
        guard recorder === finishedRecorder else { return }
        let handler = eventHandler
        recorder = nil
        eventHandler = nil
        handler?(event)
    }
}
