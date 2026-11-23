// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct OpenAIConnectionSettingsView: View {
    @State private var keyInput = ""
    @State private var hasStoredKey = false
    @State private var storageReadable = false
    @State private var message: String?
    @State private var issue: String?
    @State private var confirmsRemoval = false
    @AppStorage(AITextSettings.enabledKey) private var allowsText = false
    @AppStorage(AITextSettings.assistantEnabledKey) private var allowsAssistant = false
    @AppStorage(AITextSettings.autoWikiKey) private var autoWiki = false
    @AppStorage(AITextSettings.modelKey) private var model = AITextSettings.defaultModel
    @State private var testQuestion = "Responda somente: conexão sintética funcionando."
    @State private var testResult = ""
    @State private var testTask: Task<Void, Never>?
    private let store = IntegrationCredentialStore()

    var body: some View {
        GroupBox("OpenAI · configuração opcional") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Conecte a API para os recursos da OpenAI. A escolha entre Apple e OpenAI para consultas fica em Transcrição. Guardar uma chave não envia dados. A cobrança da API é separada da assinatura ChatGPT.")
                Label(storageReadable ? (hasStoredKey ? "Chave guardada neste Mac" : "Nenhuma chave configurada") : "Acesso ao Chaves ainda não confirmado",
                      systemImage: hasStoredKey ? "key.fill" : "key")
                    .font(.callout)
                SecureField("Cole sua chave da API OpenAI", text: $keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .accessibilityHint("A chave fica oculta. Não informe a senha da sua conta.")
                HStack {
                    Button(hasStoredKey ? "Substituir chave" : "Guardar no Chaves") { save() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasStoredKey {
                        Button("Remover deste Mac…", role: .destructive) { confirmsRemoval = true }
                    }
                    if !storageReadable { Button("Tentar novamente") { refresh() } }
                }
                Text("Somente no Chaves do macOS, sem sincronização pelo app. Não fica no prontuário nem no backup do vault. Não cole credenciais em conversas ou envie por WhatsApp.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Como obter a chave · passo a passo") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Abra o painel oficial e entre na sua conta OpenAI. A chave é diferente da sua senha.")
                        Link("Abrir painel de chaves OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        Text("2. Confira a cobrança da API e configure seu orçamento. Não presuma que a assinatura do ChatGPT inclui o uso da API; alertas de orçamento não são garantia de bloqueio de gastos.")
                        Link("Ver preços da API", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                        Text("3. Crie uma chave secreta individual para o projeto OpenPEP. Não use uma chave de administrador nem compartilhe a chave entre médicos.")
                        Text("4. Copie a chave exibida pelo painel e cole no campo acima. Clique em Guardar no Chaves. A chave salva não será exibida novamente pelo OpenPEP.")
                        Text("5. Ative o processamento de texto e use Testar pergunta sintética. Guardar a chave não confirma saldo, permissões ou condições de retenção.")
                        Text("Se a chave vazar, revogue-a no painel OpenAI e crie outra. Remover deste Mac não revoga a chave na OpenAI.")
                    }.padding(.top, 8)
                }
                Toggle("Permitir enviar texto para perguntas sobre o prontuário", isOn: $allowsText)
                Text("Quando você pedir uma resposta, serão enviados a pergunta e os textos necessários do paciente em foco. Áudio não está incluído.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("O app solicita não guardar a resposta na API. Isso não garante retenção zero pelo provedor.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Política de dados da API", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                Toggle("Permitir interpretar pedidos do Assistente", isOn: $allowsAssistant)
                    .disabled(!allowsText)
                Text("Envia apenas o pedido digitado, inclusive nomes nele escritos, para abrir um paciente. A lista de pacientes e o rascunho não são enviados pelo Assistente.")
                    .font(.caption).foregroundStyle(.secondary)
                AssistantVoiceSettingsView()
                Toggle("Atualizar resumos ao abrir paciente ou salvar correções", isOn: $autoWiki)
                    .disabled(!allowsText)
                Text("Quando esta opção estiver ativa, fontes novas ou correções pendentes serão enviadas automaticamente ao abrir o paciente ou salvar uma correção. Falhas aguardam nova abertura ou tentativa manual.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Modelo", text: $model).disabled(testTask != nil)
                DisclosureGroup("Testar pergunta sintética") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Pergunta fictícia", text: $testQuestion).disabled(testTask != nil)
                        HStack {
                            Button("Testar conexão") { runTest() }
                                .disabled(!allowsText || !hasStoredKey || testTask != nil || testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if testTask != nil {
                                ProgressView().controlSize(.small)
                                Button("Cancelar") { testTask?.cancel() }
                            }
                        }
                        if !testResult.isEmpty { Text(testResult).textSelection(.enabled) }
                    }.padding(.top, 8)
                }
                if let message { Label(message, systemImage: "checkmark.circle").textSelection(.enabled) }
                if let issue { Label(issue, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { refresh() }
        .onDisappear { keyInput = ""; testTask?.cancel() }
        .confirmationDialog("Remover a chave OpenAI deste Mac?", isPresented: $confirmsRemoval) {
            Button("Remover deste Mac", role: .destructive) {
                do {
                    try store.delete(account: OpenAIKeyInput.account)
                    keyInput = ""
                    refresh()
                    message = "Chave removida deste Mac. A revogação no provedor é separada."
                } catch { issue = error.localizedDescription }
            }
            Button("Cancelar", role: .cancel) { }
        } message: { Text("Isso não revoga a chave no painel OpenAI.") }
    }

    private func runTest() {
        guard testTask == nil else { return }
        let input = testQuestion
        testResult = ""
        testTask = Task { @MainActor in
            defer { testTask = nil }
            do {
                let result = try await AITextSettings.configuredRequest(input: input,
                    instructions: "Responda em português à pergunta sintética. Não use ferramentas.")
                testResult = result.text + "\n\nModelo: " + result.model
            } catch is CancellationError {
                testResult = "Teste cancelado. A pergunta permanece disponível."
            } catch { testResult = error.localizedDescription }
        }
    }

    private func refresh() {
        issue = nil
        message = nil
        do {
            hasStoredKey = try store.read(account: OpenAIKeyInput.account) != nil
            storageReadable = true
        } catch {
            storageReadable = false
            issue = error.localizedDescription
        }
    }

    private func save() {
        message = nil
        issue = nil
        do {
            let key = try OpenAIKeyInput.normalized(keyInput)
            try store.save(Data(key.utf8), account: OpenAIKeyInput.account)
            keyInput = ""
            refresh()
            if storageReadable { message = "Chave guardada. Nenhuma chamada à API foi feita." }
        } catch { issue = error.localizedDescription }
    }
}
