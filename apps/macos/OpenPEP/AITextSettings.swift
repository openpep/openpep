// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Preferences contain no credential or patient content.
enum AITextSettings {
    static let enabledKey = "openpep.ai.openai.text-enabled"
    static let assistantVoiceEnabledKey = "openpep.ai.assistant.voice-enabled"
    static let assistantEnabledKey = "openpep.ai.openai.assistant-enabled"
    static let autoWikiKey = "openpep.ai.openai.auto-wiki"
    static let modelKey = "openpep.ai.openai.text-model"
    static let defaultModel = "gpt-5.6-sol"
    static let consultationSummaryEnabledKey = "openpep.ai.openai.consultation-summary-enabled"
    static let consultationSummaryProviderKey = "openpep.ai.consultation-summary-provider"
    static let consultationSummaryModelKey = "openpep.ai.openai.consultation-summary-model"
    static let defaultConsultationSummaryProvider = "openai"
    static let defaultConsultationSummaryModel = "gpt-4o"
    static let liveTranscriptionEnabledKey = "openpep.ai.openai.live-transcription-enabled"
    static let liveTranscriptionModelKey = "openpep.ai.openai.live-transcription-model"
    static let defaultLiveTranscriptionModel = "gpt-live-transcribe"

    @MainActor
    static func configuredRequest(input: String, instructions: String,
                                  responseFormat: OpenAITextResponseFormat? = nil) async throws -> OpenAITextResult {
        guard UserDefaults.standard.bool(forKey: enabledKey) else {
            throw AITextSettingsIssue.disabled
        }
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        guard let data = try IntegrationCredentialStore().read(account: OpenAIKeyInput.account),
              let key = String(data: data, encoding: .utf8) else {
            throw AITextSettingsIssue.missingKey
        }
        try Task.checkCancellation()
        let result = try await OpenAITextService().respond(input: input, instructions: instructions,
                                                        model: model, apiKey: key, responseFormat: responseFormat)
        try Task.checkCancellation()
        guard UserDefaults.standard.bool(forKey: enabledKey),
              (UserDefaults.standard.string(forKey: modelKey) ?? defaultModel) == model else {
            throw AITextSettingsIssue.changed
        }
        return result
    }

    @MainActor
    static func configuredConsultationSummaryRequest(
        input: String,
        instructions: String,
        model expectedModel: String? = nil,
        responseFormat: OpenAITextResponseFormat? = nil
    ) async throws -> OpenAITextResult {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: consultationSummaryEnabledKey) else {
            throw AITextSettingsIssue.summaryDisabled
        }
        let model = defaults.string(forKey: consultationSummaryModelKey)
            ?? defaultConsultationSummaryModel
        guard expectedModel == nil || expectedModel == model else {
            throw AITextSettingsIssue.changed
        }
        let key = try apiKey()
        let result = try await OpenAITextService().respond(
            input: input,
            instructions: instructions,
            model: model,
            apiKey: key,
            responseFormat: responseFormat
        )
        try Task.checkCancellation()
        guard defaults.bool(forKey: consultationSummaryEnabledKey),
              (defaults.string(forKey: consultationSummaryModelKey)
               ?? defaultConsultationSummaryModel) == model,
              expectedModel == nil || expectedModel == model else {
            throw AITextSettingsIssue.changed
        }
        return result
    }

    @MainActor
    static func configuredLiveTranscription() throws -> (apiKey: String, model: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: liveTranscriptionEnabledKey) else {
            throw AITextSettingsIssue.transcriptionDisabled
        }
        let model = defaults.string(forKey: liveTranscriptionModelKey)
            ?? defaultLiveTranscriptionModel
        return (try apiKey(), model)
    }

    @MainActor
    static func consultationSummaryProvider() -> String {
        UserDefaults.standard.string(forKey: consultationSummaryProviderKey)
            ?? defaultConsultationSummaryProvider
    }

    @MainActor
    private static func apiKey() throws -> String {
        guard let data = try IntegrationCredentialStore().read(account: OpenAIKeyInput.account),
              let key = String(data: data, encoding: .utf8) else {
            throw AITextSettingsIssue.missingKey
        }
        return key
    }
}

enum AITextSettingsIssue: LocalizedError {
    case disabled, summaryDisabled, transcriptionDisabled, missingKey, changed
    var errorDescription: String? {
        switch self {
        case .disabled: "Ative o processamento de texto pela OpenAI em Configurações para gerar. O texto local continua disponível."
        case .summaryDisabled: "Ative o envio de texto da consulta à OpenAI ou escolha o resumo local da Apple."
        case .transcriptionDisabled: "Ative o envio de áudio à OpenAI antes de iniciar a transcrição ao vivo."
        case .missingKey: "Guarde uma chave OpenAI em Configurações antes de gerar."
        case .changed: "A configuração de IA mudou durante a geração. O resultado não foi aplicado."
        }
    }
}
