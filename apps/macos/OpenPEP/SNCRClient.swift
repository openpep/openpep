// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Talks to the gateway of the environment recorded in each intent; see SNCREnvironment.
struct SNCRClient {
    static func allowsAuthorization(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return ["anvisa.gov.br", "acesso.gov.br"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    struct Intent {
        var environment: SNCREnvironment = .homologation
        let id: UUID
        let state: String
        let createdAt: Date
        let callback: URL
        let type: String
        let quantity: Int
        let registration: String
        let uf: String
        let cnpj: String
        var loginURL: URL {
            var url = URLComponents(url: environment.gateway.appending(path: "auth/login"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "client_url", value: callback.absoluteString), .init(name: "state", value: state)]
            return url.url!
        }
        func session(from url: URL, now: Date = Date()) throws -> String {
            guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) <= 300,
                  url.scheme == callback.scheme, url.host == callback.host, url.port == callback.port,
                  url.path == callback.path, url.user == nil, url.password == nil, url.fragment == nil,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CockpitError.message("O retorno do SNCR não corresponde a este pedido.") }
            let items = parts.queryItems ?? []
            let states = items.filter { $0.name == "state" }, sessions = items.filter { $0.name == "session_id" }
            guard !items.contains(where: { $0.name == "error" }), states.count == 1, states.first?.value == state,
                  sessions.count == 1, let session = sessions.first?.value, !session.isEmpty, session.utf8.count <= 4096 else {
                throw CockpitError.message("O retorno do SNCR não corresponde a este pedido.")
            }
            return session
        }
        var requestBody: [String: Any] {
            if ["RCE", "RET"].contains(type) { return ["conselho":"CRM", "tipo":type, "documento":registration, "uf":uf, "cnpj":cnpj] }
            return ["receita":type, "conselho":"CRM", "uf":uf, "documento":registration, "quantidade":quantity]
        }
    }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    let send: Transport
    init(send: @escaping Transport = SNCRTransport.send) { self.send = send }
    func execute(_ intent: Intent, returnedURL: URL, store: SNCRRegistryStore) async throws {
        guard store.environment == intent.environment else { throw CockpitError.invalidRegistry }
        let sessionID = try intent.session(from: returnedURL)
        // Claim before any network operation: duplicate callback cannot exchange or submit twice.
        try store.update { registry in
            guard let i = registry.requests.firstIndex(where: { $0.id == intent.id }), registry.requests[i].state == "prepared",
                  registry.requests[i].type == intent.type, registry.requests[i].quantity == intent.quantity else {
                throw CockpitError.message("Este pedido já foi processado. Confira o registro de números.")
            }
            registry.requests[i].state = "sending"
        }
        var status = "uncertain", http: Int?, received: [String] = []
        do {
            var tokenURL = URLComponents(url: intent.environment.gateway.appending(path: "auth/token"), resolvingAgainstBaseURL: false)!
            tokenURL.queryItems = [.init(name: "session_id", value: sessionID)]
            var request = URLRequest(url: tokenURL.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://" + intent.callback.host!, forHTTPHeaderField: "Origin")
            let (data, response) = try await send(request)
            guard response.statusCode == 200, data.count <= 65536,
                  response.mimeType == "application/json", let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["token_type"] as? String == "Bearer", let token = json["access_token"] as? String,
                  !token.isEmpty, token.utf8.count <= 32768, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw CockpitError.message("Não foi possível recuperar a autorização do SNCR.")
            }
            let path = ["RCE","RET"].contains(intent.type) ? "numeracoes/receita-especial-retencao" : "numeracoes/notificacao-receita"
            request = URLRequest(url: intent.environment.gateway.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: intent.requestBody)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://" + intent.callback.host!, forHTTPHeaderField: "Origin")
            let (body, numberResponse) = try await send(request); http = numberResponse.statusCode
            if numberResponse.statusCode == 204 || (400..<500).contains(numberResponse.statusCode) { status = "refused" }
            else if (200..<300).contains(numberResponse.statusCode) {
                status = "quarantine"
                if body.count <= 262144, numberResponse.mimeType == "application/json",
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let numbers = try? Self.numbers(object, type: intent.type, quantity: intent.quantity) {
                    status = "received"; received = numbers
                }
            }
        } catch { /* category only: never persist URL, session_id, token or provider error body */ }
        try store.update { registry in
            guard let i = registry.requests.firstIndex(where: { $0.id == intent.id }), registry.requests[i].state == "sending" else { throw CockpitError.invalidRegistry }
            if received.contains(where: { value in registry.numbers.contains { $0.id == value } }) { status = "quarantine"; received = [] }
            registry.requests[i].state = status; registry.requests[i].http = http
            if status == "received" {
                registry.numbers += received.map { .init(id: $0, requestID: intent.id, prescriber: registry.requests[i].prescriber, type: intent.type) }
            }
        }
    }
    static func numbers(_ object: [String: Any], type: String, quantity: Int) throws -> [String] {
        var numbers: [String]
        if ["RCE","RET"].contains(type) {
            guard quantity == 1000, object["quantidade"] as? Int == 1000,
                  let start = object["inicio"] as? String, let end = object["fim"] as? String,
                  SNCRRegistry.validNumber(start), SNCRRegistry.validNumber(end), start.dropLast(7) == end.dropLast(7),
                  let first = Int(start.suffix(7)), let last = Int(end.suffix(7)), last - first == 999 else { throw CockpitError.invalidRegistry }
            numbers = (first...last).map { String(start.dropLast(7)) + String(format: "%07d", $0) }
        } else {
            let raw = object["numeroReceita"] ?? object["numerosReceita"] ?? object["numeracoesReceita"]
            if let list = raw as? [String] { numbers = list }
            else if let text = raw as? String {
                numbers = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
            } else { throw CockpitError.invalidRegistry }
            guard !numbers.isEmpty, numbers.count <= quantity else { throw CockpitError.invalidRegistry }
        }
        guard numbers.allSatisfy(SNCRRegistry.validNumber), Set(numbers).count == numbers.count else { throw CockpitError.invalidRegistry }
        return numbers
    }
}

private final class SNCRTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = SNCRTransport(), config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, !(300..<400).contains(http.statusCode) else { throw CockpitError.invalidRegistry }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262144 else { throw CockpitError.invalidRegistry }
            data.append(byte)
        }
        return (data, http)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
