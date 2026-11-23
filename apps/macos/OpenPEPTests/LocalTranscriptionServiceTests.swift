// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct LocalTranscriptionServiceTests {
    @Test("refuses transcription when the local engine is unavailable")
    func refusesUnavailableEngine() async throws {
        let engine = SyntheticTranscriptionEngine(availability: .speechUnavailable)
        let service = LocalTranscriptionService(engine: engine)
        let audioURL = try syntheticAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await #expect(throws: LocalTranscriptionIssue.speechUnavailable) {
            _ = try await service.transcribeImportedAudio(at: audioURL)
        }
        #expect(await engine.transcriptionCount == 0)
    }

    @Test("reports missing pt-BR assets without starting a transcription or download")
    func reportsMissingAssets() async throws {
        let engine = SyntheticTranscriptionEngine(
            availability: .assetsNotInstalled(localeIdentifier: "pt-BR")
        )
        let service = LocalTranscriptionService(engine: engine)
        let audioURL = try syntheticAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await #expect(throws: LocalTranscriptionIssue.assetsNotInstalled("pt-BR")) {
            _ = try await service.transcribeImportedAudio(at: audioURL)
        }
        #expect(await engine.transcriptionCount == 0)
    }

    @Test("rejects a non-file URL before consulting the engine")
    func rejectsNonFileURL() async {
        let engine = SyntheticTranscriptionEngine(
            availability: .ready(localeIdentifier: "pt-BR")
        )
        let service = LocalTranscriptionService(engine: engine)

        await #expect(throws: LocalTranscriptionIssue.invalidAudioFile) {
            _ = try await service.transcribeImportedAudio(
                at: URL(string: "https://example.invalid/synthetic.wav")!
            )
        }
        #expect(await engine.availabilityCount == 0)
    }

    @Test("returns a reviewable synthetic draft without changing clinical state")
    func returnsReviewableDraft() async throws {
        let engine = SyntheticTranscriptionEngine(
            availability: .ready(localeIdentifier: "pt-BR"),
            transcript: "Paciente sintético refere melhora."
        )
        let service = LocalTranscriptionService(engine: engine)
        let audioURL = try syntheticAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let draft = try await service.transcribeImportedAudio(at: audioURL)

        #expect(draft == LocalTranscriptionDraft(
            text: "Paciente sintético refere melhora.",
            localeIdentifier: "pt-BR"
        ))
        #expect(await engine.transcriptionCount == 1)
    }

    @Test("cancellation asks the engine to finish immediately")
    func cancellationCleansUpEngine() async throws {
        let engine = SyntheticTranscriptionEngine(
            availability: .ready(localeIdentifier: "pt-BR"),
            delay: .seconds(30)
        )
        let service = LocalTranscriptionService(engine: engine)
        let audioURL = try syntheticAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task { try await service.transcribeImportedAudio(at: audioURL) }

        while await engine.transcriptionCount == 0 {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let cancellationCount = await engine.cancellationCount
        let cancelledOperations = Set(await engine.cancellationOperationIDs)
        let transcribedOperations = Set(await engine.transcriptionOperationIDs)
        #expect(cancellationCount > 0)
        #expect(cancelledOperations == transcribedOperations)
    }

    @Test("cancellation during availability never starts the engine")
    func cancellationDuringAvailabilityDoesNotTranscribe() async throws {
        let engine = SyntheticTranscriptionEngine(
            availability: .speechUnavailable,
            availabilityDelay: .milliseconds(100)
        )
        let service = LocalTranscriptionService(engine: engine)
        let audioURL = try syntheticAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task { try await service.transcribeImportedAudio(at: audioURL) }

        while await engine.availabilityCount == 0 {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await engine.transcriptionCount == 0)
    }

    private func syntheticAudioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "openpep-transcription-synthetic-\(UUID().uuidString).wav"
        )
        try Data("synthetic audio placeholder".utf8).write(to: url, options: .atomic)
        return url
    }
}

private actor SyntheticTranscriptionEngine: LocalTranscriptionEngine {
    let configuredAvailability: LocalTranscriptionAvailability
    let transcript: String
    let delay: Duration?
    let availabilityDelay: Duration?
    private(set) var availabilityCount = 0
    private(set) var transcriptionCount = 0
    private(set) var cancellationCount = 0
    private(set) var transcriptionOperationIDs: [UUID] = []
    private(set) var cancellationOperationIDs: [UUID] = []

    init(
        availability: LocalTranscriptionAvailability,
        transcript: String = "",
        delay: Duration? = nil,
        availabilityDelay: Duration? = nil
    ) {
        configuredAvailability = availability
        self.transcript = transcript
        self.delay = delay
        self.availabilityDelay = availabilityDelay
    }

    func availability(for locale: Locale) async -> LocalTranscriptionAvailability {
        availabilityCount += 1
        if let availabilityDelay {
            await Task.detached {
                try? await Task.sleep(for: availabilityDelay)
            }.value
        }
        return configuredAvailability
    }

    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String {
        transcriptionCount += 1
        transcriptionOperationIDs.append(operationID)
        if let delay {
            try await Task.sleep(for: delay)
        }
        return transcript
    }

    func cancel(operationID: UUID) {
        cancellationCount += 1
        cancellationOperationIDs.append(operationID)
    }
}
