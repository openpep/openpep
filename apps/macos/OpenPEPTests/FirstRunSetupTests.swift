// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security
import Testing
@testable import OpenPEP

@MainActor struct FirstRunSetupTests {
    private func defaults() -> (String, UserDefaults) {
        let name = "openpep.onboarding.test." + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }
    private func store(update: @escaping (CFDictionary, CFDictionary) -> OSStatus) -> IntegrationCredentialStore {
        .init(service: "synthetic.onboarding", operations: .init(copy: { _, _ in errSecItemNotFound },
            add: { _ in errSecSuccess }, update: update, delete: { _ in errSecSuccess }))
    }
    @Test func activationRequiresSuccessfulRequestAndCredentialStorage() async throws {
        let (name, settings) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        var saved = 0
        let credentials = store { _, _ in saved += 1; return errSecSuccess }
        do {
            try await FirstRunSetup.activateOpenAI(key: "sk-synthetic-onboarding-key-123", defaults: settings, store: credentials,
                test: { _, _ in throw OpenAITextIssue.credentialsRejected })
            Issue.record("Rejected key was accepted")
        } catch { }
        #expect(saved == 0)
        #expect(FirstRunSetup.cloudKeys.allSatisfy { !settings.bool(forKey: $0) })
        try await FirstRunSetup.activateOpenAI(key: "sk-synthetic-onboarding-key-123", defaults: settings, store: credentials,
            test: { _, model in #expect(model == FirstRunSetup.textModel) })
        #expect(saved == 1)
        #expect(FirstRunSetup.cloudKeys.allSatisfy { settings.bool(forKey: $0) })
        #expect(settings.string(forKey: ConsultationCaptureSettings.transcriptionModeKey) == ConsultationTranscriptionMode.openAILive.rawValue)
        #expect(!settings.bool(forKey: FirstRunSetup.completedKey))
        #expect(settings.dictionaryRepresentation().values.allSatisfy { ($0 as? String)?.hasPrefix("sk-") != true })
    }
    @Test func storageFailureAndCancellationDoNotEnableCloud() async {
        for cancelled in [false, true] {
            let (name, settings) = defaults(); defer { settings.removePersistentDomain(forName: name) }
            do {
                try await FirstRunSetup.activateOpenAI(key: "sk-synthetic-onboarding-key-123", defaults: settings,
                    store: store { _, _ in errSecInteractionNotAllowed }, test: { _, _ in
                        if cancelled { throw CancellationError() }
                    })
                Issue.record("Failure was accepted")
            } catch { }
            #expect(FirstRunSetup.cloudKeys.allSatisfy { !settings.bool(forKey: $0) })
        }
    }
    @Test func preservesChosenModelsAndLocalModeDisablesRemoteFeatures() async throws {
        let (name, settings) = defaults(); defer { settings.removePersistentDomain(forName: name) }
        settings.set("previous-text-model", forKey: AITextSettings.modelKey)
        settings.set("previous-summary-model", forKey: AITextSettings.consultationSummaryModelKey)
        try await FirstRunSetup.activateOpenAI(key: "sk-synthetic-onboarding-key-123", defaults: settings,
            store: store { _, _ in errSecSuccess }, test: { _, model in #expect(model == "previous-text-model") })
        #expect(settings.string(forKey: AITextSettings.consultationSummaryModelKey) == "previous-summary-model")
        FirstRunSetup.useLocal(defaults: settings)
        #expect(FirstRunSetup.cloudKeys.allSatisfy { !settings.bool(forKey: $0) })
        #expect(settings.string(forKey: AITextSettings.consultationSummaryProviderKey) == "apple")
    }
}
