// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import SwiftUI

@MainActor
enum FirstRunSetup {
    static let completedKey = "openpep.first-run.completed.v1"
    static let textModel = "gpt-4.1-mini"
    static let cloudKeys = [AITextSettings.enabledKey, AITextSettings.assistantEnabledKey,
        AITextSettings.assistantVoiceEnabledKey, AITextSettings.autoWikiKey,
        AITextSettings.consultationSummaryEnabledKey, AITextSettings.liveTranscriptionEnabledKey]

    static func activateOpenAI(key input: String, defaults: UserDefaults = .standard,
        store: IntegrationCredentialStore = .init(),
        test: (String, String) async throws -> Void = { key, model in
            _ = try await OpenAITextService().respond(input: "Responda apenas: conexão funcionando.",
                instructions: "Este é um teste sintético de conexão, sem dados de pacientes.", model: model, apiKey: key)
        }) async throws {
        let key = try OpenAIKeyInput.normalized(input)
        let model = defaults.string(forKey: AITextSettings.modelKey) ?? textModel
        try await test(key, model)
        try Task.checkCancellation()
        try store.save(Data(key.utf8), account: OpenAIKeyInput.account)
        for setting in cloudKeys { defaults.set(true, forKey: setting) }
        if defaults.string(forKey: AITextSettings.modelKey) == nil { defaults.set(model, forKey: AITextSettings.modelKey) }
        if defaults.string(forKey: AITextSettings.consultationSummaryModelKey) == nil {
            defaults.set(model, forKey: AITextSettings.consultationSummaryModelKey)
        }
        defaults.set(ConsultationTranscriptionMode.openAILive.rawValue, forKey: ConsultationCaptureSettings.transcriptionModeKey)
        defaults.set(ProgressiveSummaryProvider.openAI.rawValue, forKey: AITextSettings.consultationSummaryProviderKey)
    }

    static func useLocal(defaults: UserDefaults = .standard) {
        for setting in cloudKeys { defaults.set(false, forKey: setting) }
        defaults.set(ConsultationTranscriptionMode.appleLive.rawValue, forKey: ConsultationCaptureSettings.transcriptionModeKey)
        defaults.set(ProgressiveSummaryProvider.apple.rawValue, forKey: AITextSettings.consultationSummaryProviderKey)
    }
}

struct FirstRunSetupView: View {
    var onFinish: () -> Void
    var onCancel: (() -> Void)?
    @State private var key = ""
    @State private var step = 0
    @State private var issue: String?
    @State private var task: Task<Void, Never>?
    @State private var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("OpenPEP · versão alfa").font(.largeTitle.bold())
                    Spacer()
                    if let onCancel { Button("Fechar", action: onCancel).keyboardShortcut(.cancelAction) }
                }
                Text(step == 0 ? "Vamos preparar sua primeira consulta." : "Agora, o microfone.")
                    .font(.title2.weight(.semibold))
                if step == 0 {
                    Text("Cole a chave da OpenAI. Vamos testar a conexão e preparar transcrição, resumos, assistente e atualização da história do paciente de uma vez.")
                    SecureField("Chave da API OpenAI", text: $key).textFieldStyle(.roundedBorder)
                        .textContentType(.password).disabled(task != nil)
                    Text("Ao ativar, você autoriza o envio de áudio durante a transcrição e de texto para os recursos de IA, incluindo atualização automática da wiki. A API tem cobrança própria. Tudo pode ser ajustado depois em Configurações.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Testar chave e ativar IA") { activate() }
                            .buttonStyle(.borderedProminent).disabled(key.isEmpty || task != nil)
                        if task != nil { ProgressView().controlSize(.small); Button("Cancelar") { task?.cancel() } }
                    }
                    DisclosureGroup("Como conseguir a chave") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Entre no painel da OpenAI, configure a cobrança da API e crie uma chave para o projeto. Copie a chave e cole no campo acima. Ela será guardada no Chaves deste Mac.")
                            Link("Criar chave na OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            Link("Configurar cobrança da API", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                            Link("Guia oficial de primeiros passos", destination: URL(string: "https://developers.openai.com/api/docs/quickstart")!)
                        }.padding(.top, 8)
                    }
                    Button("Usar recursos locais neste Mac") { FirstRunSetup.useLocal(); key = ""; issue = nil; step = 1 }
                        .disabled(task != nil)
                    Text("O teste envia somente uma frase de exemplo. Não grava áudio nem verifica todas as permissões de modelos da conta.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Autorize o microfone para transcrever suas consultas. Este passo não inicia uma gravação.")
                    Label(microphoneAllowed ? "Microfone autorizado" : "Permissão de microfone pendente",
                          systemImage: microphoneAllowed ? "checkmark.circle" : "mic")
                    if !microphoneAllowed {
                        Button("Autorizar microfone") { requestMicrophone() }.disabled(task != nil)
                        Link("Abrir permissões do microfone", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Text("Ao escolher a pasta do prontuário, os áudios ficarão nela, na subpasta recordings. Não é preciso escolher outro destino.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(microphoneAllowed ? "Começar" : "Continuar e autorizar depois") {
                        UserDefaults.standard.set(true, forKey: FirstRunSetup.completedKey); onFinish()
                    }.buttonStyle(.borderedProminent).disabled(task != nil)
                }
                if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Text("Alfa experimental. Use somente dados de demonstração.").font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onDisappear { key = ""; task?.cancel() }
    }

    private func activate() {
        issue = nil
        task = Task { @MainActor in
            defer { task = nil }
            do { try await FirstRunSetup.activateOpenAI(key: key); key = ""; step = 1 }
            catch is CancellationError { issue = "Teste cancelado. Nenhum recurso foi ativado." }
            catch { issue = error.localizedDescription }
        }
    }
    private func requestMicrophone() {
        task = Task { @MainActor in
            defer { task = nil }
            microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            issue = microphoneAllowed ? nil : "O microfone não foi autorizado. Você pode permitir o acesso nos Ajustes do macOS."
        }
    }
}
