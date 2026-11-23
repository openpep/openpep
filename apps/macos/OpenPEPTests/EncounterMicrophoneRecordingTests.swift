// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import OpenPEP

@MainActor
@Suite("TRANSCRIPTION-003 synthetic microphone recording")
struct EncounterMicrophoneRecordingTests {
    @Test("requires explicit consent without requesting microphone access")
    func requiresConsent() async {
        let capture = SyntheticEncounterMicrophoneCapture()
        let model = EncounterMicrophoneRecordingModel(capture: capture)

        await model.start(at: destination(), consent: false)

        #expect(capture.permissionRequestCount == 0)
        #expect(capture.startCount == 0)
        #expect(model.state == .failed(EncounterMicrophoneRecordingIssue.consentRequired.localizedDescription))
    }

    @Test("reports denied permission without creating or starting a recording")
    func reportsDeniedPermission() async {
        let capture = SyntheticEncounterMicrophoneCapture(permissionGranted: false)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()

        await model.start(at: url, consent: true)

        #expect(capture.permissionRequestCount == 1)
        #expect(capture.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.state == .failed(EncounterMicrophoneRecordingIssue.permissionDenied.localizedDescription))
    }

    @Test("dismissal invalidates pending microphone authorization")
    func dismissalInvalidatesAuthorization() async {
        let capture = SyntheticEncounterMicrophoneCapture(suspendsPermission: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let task = Task { await model.start(at: destination(), consent: true) }
        await waitUntil { capture.permissionRequestCount == 1 }

        model.dismiss()
        capture.resolvePermission(true)
        await task.value

        #expect(capture.startCount == 0)
        #expect(capture.stopCount == 1)
        #expect(model.state == .idle)
        #expect(model.recordedURL == nil)
    }

    @Test("stop invalidates pending microphone authorization")
    func stopInvalidatesAuthorization() async {
        let capture = SyntheticEncounterMicrophoneCapture(suspendsPermission: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let task = Task { await model.start(at: destination(), consent: true) }
        await waitUntil { capture.permissionRequestCount == 1 }

        model.stop()
        capture.resolvePermission(true)
        await task.value

        #expect(capture.startCount == 0)
        #expect(capture.stopCount == 1)
        #expect(model.state == .idle)
        #expect(model.status.contains("cancelada"))
    }

    @Test("task cancellation after authorization cannot start recording")
    func taskCancellationDoesNotStart() async {
        let capture = SyntheticEncounterMicrophoneCapture(suspendsPermission: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let task = Task { await model.start(at: destination(), consent: true) }
        await waitUntil { capture.permissionRequestCount == 1 }

        task.cancel()
        capture.resolvePermission(true)
        await task.value

        #expect(capture.startCount == 0)
        #expect(model.state == .idle)
        #expect(model.status.contains("cancelada"))
    }

    @Test("stops into a recoverable M4A and applies the sixty minute limit")
    func stopsAndPreservesAudio() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(writesSyntheticAudio: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)
        #expect(model.state == .recording)
        #expect(capture.maximumDuration == 3_600)

        model.stop()
        capture.finish(.finished)
        await waitUntil { model.state == .recorded }

        #expect(capture.stopCount == 1)
        #expect(model.recordedURL == url)
        #expect(try Data(contentsOf: url) == Data("audio sintético".utf8))
    }

    @Test("a second start cannot disturb an active recording")
    func secondStartCannotDisturbActiveRecording() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(writesSyntheticAudio: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)
        await model.start(at: destination(), consent: false)

        #expect(capture.startCount == 1)
        #expect(model.state == .recording)
        #expect(model.recordedURL == nil)
    }

    @Test("an interruption preserves the destination and reports failure")
    func interruptionPreservesAudio() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(writesSyntheticAudio: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)
        capture.finish(.failed)
        await waitUntil {
            if case .failed = model.state { return true }
            return false
        }

        #expect(model.recordedURL == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(model.status.contains("preservado"))
    }

    @Test("refuses an existing destination before requesting access")
    func refusesExistingDestination() async throws {
        let capture = SyntheticEncounterMicrophoneCapture()
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        let original = Data("não substituir".utf8)
        try original.write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)

        #expect(capture.permissionRequestCount == 0)
        #expect(capture.startCount == 0)
        #expect(try Data(contentsOf: url) == original)
        #expect(model.state == .failed(EncounterMicrophoneRecordingIssue.destinationExists.localizedDescription))
    }

    @Test("refuses a destination created while permission is pending without overwriting it")
    func refusesDestinationCreatedDuringAuthorization() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(suspendsPermission: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        let external = Data("conteúdo externo sintético".utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { await model.start(at: url, consent: true) }
        await waitUntil { capture.permissionRequestCount == 1 }

        try external.write(to: url, options: .withoutOverwriting)
        capture.resolvePermission(true)
        await task.value

        #expect(capture.startCount == 0)
        #expect(try Data(contentsOf: url) == external)
        #expect(model.state == .failed(EncounterMicrophoneRecordingIssue.destinationExists.localizedDescription))
    }

    @Test("startup failure keeps any created audio recoverable")
    func startupFailurePreservesAudio() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(
            writesSyntheticAudio: true,
            startError: EncounterMicrophoneRecordingIssue.startFailed
        )
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)

        #expect(model.recordedURL == url)
        #expect(try Data(contentsOf: url) == Data("audio sintético".utf8))
        #expect(model.state == .failed(EncounterMicrophoneRecordingIssue.startFailed.localizedDescription))
    }

    @Test("late recorder callbacks cannot revive a dismissed session")
    func ignoresLateCallbackAfterDismissal() async throws {
        let capture = SyntheticEncounterMicrophoneCapture(writesSyntheticAudio: true)
        let model = EncounterMicrophoneRecordingModel(capture: capture)
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }

        await model.start(at: url, consent: true)
        model.dismiss()
        capture.finish(.finished)
        await Task.yield()

        #expect(capture.stopCount == 1)
        #expect(model.state == .idle)
        #expect(model.recordedURL == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("native settings are mono 16 kHz AAC at 32 kbps")
    func nativeSettingsMatchBoundedFormat() {
        let settings = AppleEncounterMicrophoneCapture.settings
        #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Int == 16_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVEncoderBitRateKey] as? Int == 32_000)
        #expect(EncounterMicrophoneRecordingModel.maximumDuration == 3_600)
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "openpep-microphone-synthetic-\(UUID().uuidString.lowercased()).m4a"
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("A condição sintética não foi alcançada no limite do teste")
    }
}

@MainActor
private final class SyntheticEncounterMicrophoneCapture: EncounterMicrophoneCapturing {
    let permissionGranted: Bool
    let suspendsPermission: Bool
    let writesSyntheticAudio: Bool
    let startError: (any Error)?
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var maximumDuration: TimeInterval?
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var eventHandler: (@Sendable (EncounterMicrophoneCaptureEvent) -> Void)?

    init(
        permissionGranted: Bool = true,
        suspendsPermission: Bool = false,
        writesSyntheticAudio: Bool = false,
        startError: (any Error)? = nil
    ) {
        self.permissionGranted = permissionGranted
        self.suspendsPermission = suspendsPermission
        self.writesSyntheticAudio = writesSyntheticAudio
        self.startError = startError
    }

    func requestAccess() async -> Bool {
        permissionRequestCount += 1
        if suspendsPermission {
            return await withCheckedContinuation { permissionContinuation = $0 }
        }
        return permissionGranted
    }

    func startRecording(
        at url: URL,
        maximumDuration: TimeInterval,
        eventHandler: @escaping @Sendable (EncounterMicrophoneCaptureEvent) -> Void
    ) throws {
        startCount += 1
        self.maximumDuration = maximumDuration
        self.eventHandler = eventHandler
        if writesSyntheticAudio {
            try Data("audio sintético".utf8).write(to: url, options: .withoutOverwriting)
        }
        if let startError { throw startError }
    }

    func stopRecording() {
        stopCount += 1
    }

    func resolvePermission(_ granted: Bool) {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: granted)
    }

    func finish(_ event: EncounterMicrophoneCaptureEvent) {
        eventHandler?(event)
    }
}
