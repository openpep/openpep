// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GoogleMeetIntegrationController: ObservableObject {
    enum State: Equatable {
        case needsClient
        case readyToConnect
        case connected
        case connecting
        case creating
        case failed(String)

        var label: String {
            switch self {
            case .needsClient: "Importe o arquivo de conexão do Google para habilitar o login"
            case .readyToConnect: "Cliente configurado; conta não conectada"
            case .connected: "Conta Google conectada neste Mac"
            case .connecting: "Aguardando autorização no navegador…"
            case .creating: "Criando sala…"
            case .failed(let message): message
            }
        }

        var symbol: String {
            switch self {
            case .needsClient: "wrench.and.screwdriver"
            case .readyToConnect: "person.crop.circle.badge.questionmark"
            case .connected: "checkmark.circle"
            case .connecting, .creating: "hourglass"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    @Published private(set) var state: State
    @Published private(set) var lastCreatedURL: URL?
    let service: GoogleMeetService
    private(set) var hasClient = false
    private var hasConnection = false

    init(service: GoogleMeetService = GoogleMeetService()) {
        self.service = service
        do {
            switch try service.credentialState() {
            case .needsClient:
                state = .needsClient
            case .readyToConnect:
                hasClient = true
                state = .readyToConnect
            case .connected:
                hasClient = true
                hasConnection = true
                state = .connected
            }
        } catch {
            state = .failed("O Keychain deste Mac não pôde ser consultado.")
        }
    }

    var canConnect: Bool {
        guard !hasConnection else { return false }
        switch state {
        case .readyToConnect, .connected, .failed: return hasClient
        default: return false
        }
    }

    var isBusy: Bool {
        state == .connecting || state == .creating
    }

    var canCreate: Bool {
        hasConnection && !isBusy
    }

    func refreshCredentialState() {
        guard !isBusy else { return }
        do {
            switch try service.credentialState() {
            case .needsClient:
                hasClient = false
                hasConnection = false
                state = .needsClient
            case .readyToConnect:
                hasClient = true
                hasConnection = false
                state = .readyToConnect
            case .connected:
                hasClient = true
                hasConnection = true
                state = .connected
            }
        } catch {
            state = .failed("O Keychain deste Mac não pôde ser consultado.")
        }
    }

    func importClient(from url: URL) {
        guard !isBusy else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 else {
                throw GoogleMeetIssue.invalidClientFile
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
            try service.importClient(from: data)
            hasClient = true
            hasConnection = false
            lastCreatedURL = nil
            state = .readyToConnect
        } catch {
            state = .failed(publicMessage(for: error))
        }
    }

    func connect() async {
        guard canConnect else { return }
        state = .connecting
        do {
            try await service.connect()
            hasConnection = true
            state = .connected
        } catch {
            hasConnection = false
            state = Task.isCancelled ? .readyToConnect : .failed(publicMessage(for: error))
        }
    }

    func disconnect() {
        guard !isBusy else { return }
        do {
            try service.disconnect()
            hasConnection = false
            lastCreatedURL = nil
            state = hasClient ? .readyToConnect : .needsClient
        } catch {
            state = .failed(publicMessage(for: error))
        }
    }

    func createSpace() async -> URL? {
        guard canCreate else { state = .failed(GoogleMeetIssue.notConnected.localizedDescription); return nil }
        state = .creating
        do {
            let url = try await service.createSpace()
            lastCreatedURL = url
            state = .connected
            return url
        } catch {
            state = .failed(publicMessage(for: error))
            return nil
        }
    }

    private func publicMessage(for error: Error) -> String {
        (error as? GoogleMeetIssue)?.localizedDescription ?? "A operação não pôde ser concluída."
    }
}

struct GoogleMeetSettingsView: View {
    @ObservedObject var controller: GoogleMeetIntegrationController
    @State private var importsClient = false
    @State private var connectionTask: Task<Void, Never>?

    init(controller: GoogleMeetIntegrationController) {
        self.controller = controller
    }

    private var clientSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prepare a conexão uma vez").font(.headline)
            Text("Nesta alfa, a conexão usa um arquivo JSON criado no Google Cloud. Não é necessário instalar um cliente do Meet.")
            Text("1. Abra um projeto no Google Cloud e ative a Google Meet API.")
            Link("Abrir Google Meet API", destination: URL(string: "https://console.cloud.google.com/apis/library/meet.googleapis.com")!)
            Text("2. Em Google Auth Platform, configure a tela de consentimento e inclua sua conta como usuário de teste, se o projeto estiver em teste.")
            Text("3. Em Clientes, crie um cliente do tipo Aplicativo para computador (Desktop app) e baixe o JSON.")
            Link("Abrir clientes do Google", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
            Text("4. Importe o arquivo abaixo. Em seguida, Entrar com Google ficará disponível.")
            Button("Importar arquivo JSON do Google…") { importsClient = true }
                .buttonStyle(.borderedProminent).disabled(controller.isBusy)
            Link("Guia oficial de configuração", destination: URL(string: "https://developers.google.com/workspace/meet/api/guides/quickstart/python#authorize_credentials_for_a_desktop_application")!)
            Text("A configuração vale para este Mac. Um cliente oficial compartilhado do OpenPEP ainda está em preparação.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }

    var body: some View {
        GroupBox("Google Meet") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Conecte uma conta Google para criar salas vazias. O login acontece no navegador e o OpenPEP nunca pede sua senha Google.")
                    .font(.callout)

                Label(controller.state.label, systemImage: controller.state.symbol)
                    .accessibilityLabel("Estado do Google Meet: \(controller.state.label)")

                Text("A permissão Google pode criar, modificar e ler metadados das salas criadas pelo app. Este corte do OpenPEP usa somente a criação.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.state == .connecting {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancelar conexão") {
                            connectionTask?.cancel()
                            connectionTask = nil
                        }
                    }
                } else if !controller.canCreate {
                    Button("Entrar com Google…") {
                        connectionTask = Task {
                            await controller.connect()
                            connectionTask = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canConnect)
                    .accessibilityHint("Abre o navegador padrão para autorizar a permissão Google descrita acima")
                }

                if controller.canCreate {
                    Button("Desconectar conta deste Mac") { controller.disconnect() }
                }

                if case .failed = controller.state {
                    Button("Tentar consultar o Keychain novamente") { controller.refreshCredentialState() }
                        .disabled(controller.isBusy)
                }

                if let url = controller.lastCreatedURL {
                    LabeledContent("Última sala criada nesta sessão") {
                        Text(url.absoluteString).textSelection(.enabled)
                    }
                }

                if !controller.hasClient {
                    clientSetup
                } else {
                    DisclosureGroup("Alterar arquivo de conexão") { clientSetup }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .fileImporter(isPresented: $importsClient, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            controller.importClient(from: url)
        }
        .onDisappear {
            connectionTask?.cancel()
            connectionTask = nil
        }
    }
}

struct GoogleMeetCreationView: View {
    @ObservedObject var controller: GoogleMeetIntegrationController
    let onCreated: (URL) -> Void
    let saveExplanation: String
    @State private var confirmsCreation = false
    @State private var creationTask: Task<Void, Never>?

    init(
        controller: GoogleMeetIntegrationController,
        saveExplanation: String = "O link será preenchido neste formulário e só será salvo quando você salvar o agendamento.",
        onCreated: @escaping (URL) -> Void
    ) {
        self.controller = controller
        self.saveExplanation = saveExplanation
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.state == .creating {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Aguardando resposta do Google. Não feche este formulário.")
                        .font(.caption)
                }
            } else {
                Button("Criar sala do Google Meet…") { confirmsCreation = true }
                    .disabled(!controller.canCreate)
                    .accessibilityHint("Pede confirmação antes de enviar um único pedido ao Google")
            }
            Label(controller.state.label, systemImage: controller.state.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Criar uma sala vazia do Google Meet?",
            isPresented: $confirmsCreation,
            titleVisibility: .visible
        ) {
            Button("Criar sala") {
                creationTask = Task {
                    if let url = await controller.createSpace() { onCreated(url) }
                    creationTask = nil
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O pedido não inclui paciente, horário ou conteúdo clínico. \(saveExplanation)")
        }
        .onDisappear {
            creationTask?.cancel()
            creationTask = nil
        }
    }
}
