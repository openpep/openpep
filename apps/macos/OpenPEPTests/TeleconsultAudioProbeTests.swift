// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@MainActor
@Suite("AUDIO-PROBE-001 synthetic audio diagnostic")
struct TeleconsultAudioProbeTests {
    private let faceTime = TeleconsultAudioApplication(
        name: "FaceTime sintético",
        bundleIdentifier: "com.apple.FaceTime",
        processIdentifier: 101
    )

    @Test("requires explicit synthetic consent before capture")
    func requiresConsent() async {
        let capture = SyntheticTeleconsultAudioCapture(applications: [faceTime])
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()

        #expect(model.state == .ready)
        #expect(model.canStart == false)
        await model.start()
        #expect(capture.startCount == 0)

        model.confirmsSyntheticConsent = true
        #expect(model.canStart)
        await model.start()
        #expect(model.state == .capturing)
        #expect(capture.startCount == 1)
    }

    @Test("keeps application and microphone levels separate")
    func keepsMetersSeparate() async {
        let capture = SyntheticTeleconsultAudioCapture(applications: [faceTime])
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true
        await model.start()

        capture.emit(TeleconsultAudioLevels(application: 0.25, microphone: 0.75))
        await waitUntil { model.levels.application == 0.25 }

        #expect(model.levels == TeleconsultAudioLevels(application: 0.25, microphone: 0.75))
    }

    @Test("stopping clears volatile levels and consent")
    func stopClearsVolatileState() async {
        let capture = SyntheticTeleconsultAudioCapture(applications: [faceTime])
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true
        await model.start()
        capture.emit(TeleconsultAudioLevels(application: 0.4, microphone: 0.3))
        await waitUntil { model.levels.application == 0.4 }

        await model.stop()

        #expect(capture.stopCount == 1)
        #expect(model.levels == TeleconsultAudioLevels())
        #expect(model.confirmsSyntheticConsent == false)
        #expect(model.state == .ready)
    }

    @Test("failed startup requests cleanup")
    func failedStartCleansUp() async {
        let capture = SyntheticTeleconsultAudioCapture(
            applications: [faceTime],
            startError: TeleconsultAudioProbeIssue.startFailed
        )
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true

        await model.start()

        #expect(capture.startCount == 1)
        #expect(capture.stopCount == 1)
        #expect(model.state == .failed(TeleconsultAudioProbeIssue.startFailed.localizedDescription))
    }

    @Test("dismissal always requests cleanup")
    func dismissalCleansUp() async {
        let capture = SyntheticTeleconsultAudioCapture(applications: [faceTime])
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true
        await model.start()

        await model.dismiss()

        #expect(capture.stopCount == 1)
        #expect(model.state == .idle)
        #expect(model.levels == TeleconsultAudioLevels())
    }

    @Test("late startup completion cannot revive a dismissed probe")
    func lateStartAfterDismissalStaysInactive() async {
        let capture = SyntheticTeleconsultAudioCapture(
            applications: [faceTime],
            startDelay: .milliseconds(50)
        )
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true
        let startTask = Task { await model.start() }
        await waitUntil { capture.startCount == 1 }

        await model.dismiss()
        await startTask.value

        #expect(model.state == .idle)
        #expect(model.levels == TeleconsultAudioLevels())
        #expect(capture.stopCount == 1)
    }

    @Test("late previous startup cannot stop a replacement capture")
    func latePreviousStartDoesNotStopReplacement() async {
        let capture = SyntheticTeleconsultAudioCapture(
            applications: [faceTime],
            startDelay: .milliseconds(50)
        )
        let model = TeleconsultAudioProbeModel(capture: capture)
        await model.loadApplications()
        model.confirmsSyntheticConsent = true
        let firstStart = Task { await model.start() }
        await waitUntil { capture.startCount == 1 }

        await model.stop()
        model.confirmsSyntheticConsent = true
        let replacementStart = Task { await model.start() }
        await firstStart.value
        await replacementStart.value

        #expect(model.state == .capturing)
        #expect(capture.startCount == 2)
        #expect(capture.stopCount == 1)
    }

    @Test("RMS normalization is deterministic without a real capture")
    func calculatesSyntheticRMS() {
        #expect(TeleconsultAudioStreamOutput.normalizedRMS(samples: []) == 0)
        #expect(TeleconsultAudioStreamOutput.normalizedRMS(samples: [1, -1]) == 1)
        #expect(abs(TeleconsultAudioStreamOutput.normalizedRMS(samples: [0.5, -0.5]) - 0.5) < 0.000_001)
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
private final class SyntheticTeleconsultAudioCapture: TeleconsultAudioCapturing {
    let applications: [TeleconsultAudioApplication]
    let startError: (any Error)?
    let startDelay: Duration?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var levelHandler: (@Sendable (TeleconsultAudioLevels) -> Void)?

    init(
        applications: [TeleconsultAudioApplication],
        startError: (any Error)? = nil,
        startDelay: Duration? = nil
    ) {
        self.applications = applications
        self.startError = startError
        self.startDelay = startDelay
    }

    func availableApplications() async throws -> [TeleconsultAudioApplication] {
        applications
    }

    func start(
        application: TeleconsultAudioApplication,
        levelHandler: @escaping @Sendable (TeleconsultAudioLevels) -> Void,
        stopHandler: @escaping @Sendable () -> Void
    ) async throws {
        startCount += 1
        if let startDelay { try await Task.sleep(for: startDelay) }
        if let startError { throw startError }
        self.levelHandler = levelHandler
    }

    func stop() async {
        stopCount += 1
        levelHandler = nil
    }

    func emit(_ levels: TeleconsultAudioLevels) {
        levelHandler?(levels)
    }
}
