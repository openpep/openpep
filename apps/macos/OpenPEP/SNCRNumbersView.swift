// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import WebKit

struct SNCRNumbersView: View {
    let store: SNCRRegistryStore
    let prescriber: CockpitPrescription.Prescriber
    let onClose: () -> Void
    /// False while a number is reserved or a document is being issued in the calling view.
    var allowsEnvironmentChange = false
    @AppStorage private var callback: String
    @AppStorage("openpep.sncr.platform.cnpj") private var cnpj = ""
    @State private var type = "RCE"
    @State private var quantity = 10
    @State private var snapshot: SNCRRegistry?
    @State private var intent: SNCRClient.Intent?
    @State private var authorizing = false
    @State private var sending = false
    @State private var error: String?
    @State private var confirms = false
    @State private var pendingEnvironment: SNCREnvironment?
    init(store: SNCRRegistryStore, prescriber: CockpitPrescription.Prescriber, allowsEnvironmentChange: Bool = false, onClose: @escaping () -> Void) {
        self.store = store; self.prescriber = prescriber; self.allowsEnvironmentChange = allowsEnvironmentChange; self.onClose = onClose
        // The return address is registered per environment.
        _callback = AppStorage(wrappedValue: "", "openpep.sncr.\(store.environment.rawValue).callback")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Meus números").font(.title2); Spacer(); Button("Fechar", action: onClose).disabled(sending || authorizing) }
            Picker("Ambiente do SNCR", selection: Binding(get: { store.environment }, set: { if $0 != store.environment { pendingEnvironment = $0 } })) {
                ForEach(SNCREnvironment.allCases, id: \.self) { Text($0.label.capitalized).tag($0) }
            }.pickerStyle(.segmented).fixedSize().disabled(!allowsEnvironmentChange || sending || authorizing)
            if !allowsEnvironmentChange { Text("Conclua ou feche a receita em andamento para trocar de ambiente.").font(.callout).foregroundStyle(.secondary) }
            Text("\(prescriber.nome) · CRM \(prescriber.crm)/\(prescriber.uf)")
            if !prescriber.isComplete { Text("Preencha os dados do médico no receituário antes de solicitar números.").foregroundStyle(.secondary) }
            HStack {
                Picker("Tipo", selection: $type) {
                    ForEach(SNCRRegistry.types, id: \.self) { Text(CockpitPrescription.names[$0] ?? $0).tag($0) }
                }
                if ["RCE","RET"].contains(type) { Text("Faixa de 1.000 números") }
                else { Stepper("Quantidade: \(quantity)", value: $quantity, in: 1...100) }
            }
            DisclosureGroup("Cadastro da plataforma no SNCR") {
                Form {
                    TextField("Endereço de retorno", text: $callback, prompt: Text("https://dominio.br/"))
                    TextField("CNPJ da plataforma", text: $cnpj)
                    Text("Informe o endereço HTTPS de retorno cadastrado para o OpenPEP e o CNPJ da plataforma. As credenciais do Cockpit RX não são reaproveitadas.").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
            Button("Solicitar pelo gov.br…") { confirms = true }.buttonStyle(.borderedProminent)
                .disabled(!prescriber.isComplete || sending || authorizing)
            if sending { ProgressView("Registrando resposta do SNCR…") }
            if let error { Text(error).foregroundStyle(.red) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SNCRRegistry.types, id: \.self) { kind in
                        let rows = snapshot?.numbers.filter { $0.prescriber == prescriber.key && $0.type == kind } ?? []
                        if !rows.isEmpty {
                            HStack {
                                Text(CockpitPrescription.names[kind] ?? kind).font(.headline)
                                Spacer()
                                Text("\(rows.filter { $0.state == "available" }.count) disponíveis · \(rows.filter { $0.state == "reserved" }.count) reservados · \(rows.filter { $0.state == "used" }.count) usados")
                            }
                        }
                    }
                    if let requests = snapshot?.requests.filter({ $0.prescriber == prescriber.key }), !requests.isEmpty {
                        Text("Pedidos").font(.headline)
                        ForEach(requests.reversed()) { request in
                            HStack {
                                Text(request.createdAt.formatted(date: .numeric, time: .shortened))
                                Text(request.type); Spacer(); Text(stateLabel(request.state))
                            }.font(.callout)
                        }
                    } else { Text("Nenhum pedido registrado.").foregroundStyle(.secondary) }
                }
            }
            Text("Pedidos incertos ou interrompidos não são repetidos. Números reservados permanecem indisponíveis até conferência.").font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 710, height: 610)
        .task { refresh() }
        .interactiveDismissDisabled(sending || authorizing)
        .confirmationDialog("Solicitar números no ambiente de \(store.environment.label)?", isPresented: $confirms, titleVisibility: .visible) {
            Button("Continuar para gov.br") { begin() }
        } message: { Text((store.environment == .production ? "São números reais, vinculados ao seu registro profissional. " : "")
            + "A solicitação retira ou gera números para este prescritor. O OpenPEP registra o pedido antes do envio e não repete em caso de dúvida.") }
        .confirmationDialog(pendingEnvironment == .production ? "Ativar o SNCR de produção neste Mac?" : "Voltar ao SNCR de homologação?",
            isPresented: Binding(get: { pendingEnvironment != nil }, set: { if !$0 { pendingEnvironment = nil } }), titleVisibility: .visible) {
            Button(pendingEnvironment == .production ? "Ativar produção" : "Usar homologação") {
                if let pendingEnvironment { UserDefaults.standard.set(pendingEnvironment.rawValue, forKey: SNCREnvironment.defaultsKey) }
                pendingEnvironment = nil; onClose()
            }
        } message: { Text(pendingEnvironment == .production
            ? "As receitas passam a usar números reais do SNCR e saem sem a marca de ensaio. Os estoques de homologação e produção são separados. O app confere a integridade da assinatura, não a política ICP-Brasil; a responsabilidade pela emissão é do profissional."
            : "As receitas voltam a sair marcadas como ensaio, com os números de homologação. Os números de produção permanecem guardados.") }
        .sheet(isPresented: $authorizing) {
            if let intent {
                VStack {
                    HStack { Text("gov.br · SNCR de \(store.environment.label)").font(.headline); Spacer(); Button("Cancelar") { cancel() } }.padding()
                    SNCRAuthorizationView(intent: intent, onReturn: { url in finish(url) }, onError: { message in error = message; cancel() })
                }.frame(width: 800, height: 700).interactiveDismissDisabled()
            }
        }
    }
    private func stateLabel(_ state: String) -> String {
        ["prepared":"Aguardando login", "sending":"Envio interrompido: conferir", "received":"Recebido", "refused":"Recusado",
         "uncertain":"Resultado incerto: conferir", "quarantine":"Resposta em quarentena", "cancelled":"Cancelado antes do envio"][state] ?? state
    }
    private func refresh() { do { snapshot = try store.read() } catch { self.error = error.localizedDescription } }
    private func begin() {
        do {
            guard let url = URL(string: callback), url.scheme == "https", url.host?.hasSuffix(".br") == true,
                  url.path == "/", url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  prescriber.isComplete else { throw CockpitError.message("Confira o cadastro do médico e o endereço HTTPS de retorno, terminado em .br/.") }
            let digits = cnpj.filter(\.isNumber)
            guard !["RCE","RET"].contains(type) || digits.count == 14 else { throw CockpitError.message("Informe o CNPJ da plataforma para solicitar esta faixa.") }
            let value = SNCRClient.Intent(environment: store.environment, id: UUID(), state: UUID().uuidString + UUID().uuidString, createdAt: Date(), callback: url,
                type: type, quantity: ["RCE","RET"].contains(type) ? 1000 : quantity, registration: prescriber.crm, uf: prescriber.uf, cnpj: digits)
            try store.update { $0.requests.append(.init(id: value.id, prescriber: prescriber.key, type: type, quantity: value.quantity)) }
            intent = value; error = nil; authorizing = true; refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func cancel() {
        authorizing = false
        if let intent {
            do { try store.update { registry in
                if let i = registry.requests.firstIndex(where: { $0.id == intent.id }), registry.requests[i].state == "prepared" {
                    registry.requests[i].state = "cancelled"
                }
            } } catch { self.error = error.localizedDescription }
        }
        intent = nil; refresh()
    }
    private func finish(_ url: URL) {
        guard !sending, let intent else { return }
        authorizing = false; sending = true
        Task { @MainActor in
            defer { sending = false; self.intent = nil; refresh() }
            do { try await SNCRClient().execute(intent, returnedURL: url, store: store) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SNCRAuthorizationView: NSViewRepresentable {
    let intent: SNCRClient.Intent
    let onReturn: (URL) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: intent.loginURL))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SNCRAuthorizationView
        var finished = false
        init(parent: SNCRAuthorizationView) { self.parent = parent }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.scheme == "https" else { decisionHandler(.cancel); return }
            if url.host == parent.intent.callback.host {
                // Intercept before navigating to the callback server: session never leaves for the platform site.
                decisionHandler(.cancel)
                guard !finished else { return }; finished = true
                do { _ = try parent.intent.session(from: url); parent.onReturn(url) }
                catch { parent.onError("O retorno do SNCR não corresponde ao pedido iniciado.") }
            } else if !finished, SNCRClient.allowsAuthorization(url) { decisionHandler(.allow) }
            else {
                decisionHandler(.cancel)
                guard !finished else { return }; finished = true
                parent.onError("O login tentou abrir um endereço fora da Anvisa ou do acesso gov.br. A navegação foi interrompida.")
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !finished else { return }; finished = true
            parent.onError("Não foi possível concluir o login. Nenhum pedido de números foi enviado.")
        }
    }
}
