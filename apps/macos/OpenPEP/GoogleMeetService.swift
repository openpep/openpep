// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum GoogleMeetIssue: LocalizedError, Equatable {
    case invalidClientFile
    case clientNotConfigured
    case browserRejected
    case callbackCancelled
    case callbackTimedOut
    case invalidCallback
    case authorizationDenied
    case invalidTokenResponse
    case notConnected
    case requestRejected
    case creationUncertain
    case invalidSpaceResponse
}

extension GoogleMeetIssue {
    var errorDescription: String? {
        switch self {
        case .invalidClientFile: "O arquivo não é um cliente OAuth para aplicativo de computador válido."
        case .clientNotConfigured: "Importe o cliente OAuth do Google antes de conectar a conta."
        case .browserRejected: "O navegador padrão não aceitou a abertura da autorização Google."
        case .callbackCancelled: "A conexão com o Google foi cancelada."
        case .callbackTimedOut: "A autorização expirou. Inicie a conexão novamente."
        case .invalidCallback: "O retorno da autorização Google não pôde ser validado."
        case .authorizationDenied: "O Google não autorizou a conexão solicitada."
        case .invalidTokenResponse: "O Google devolveu uma resposta de autorização inválida."
        case .notConnected: "Conecte uma conta Google antes de criar a sala."
        case .requestRejected: "O Google recusou a solicitação. Confira a conexão da conta."
        case .creationUncertain: "Não foi possível confirmar se a sala foi criada. Confira sua conta Google antes de tentar novamente."
        case .invalidSpaceResponse: "O Google devolveu uma sala sem endereço válido."
        }
    }
}

struct GoogleMeetOAuthClient: Codable, Equatable {
    let clientID: String
    let clientSecret: String?

    private struct Download: Decodable {
        struct Installed: Decodable {
            let clientID: String
            let clientSecret: String?
            let authURI: String
            let tokenURI: String
            let redirectURIs: [String]

            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case clientSecret = "client_secret"
                case authURI = "auth_uri"
                case tokenURI = "token_uri"
                case redirectURIs = "redirect_uris"
            }
        }
        let installed: Installed
    }

    static func parse(download data: Data) throws -> GoogleMeetOAuthClient {
        guard data.count <= 64 * 1024,
              let file = try? JSONDecoder().decode(Download.self, from: data) else {
            throw GoogleMeetIssue.invalidClientFile
        }
        let installed = file.installed
        let clientID = installed.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = installed.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (10...2048).contains(clientID.utf8.count),
              clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 46
              }),
              secret.map({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true,
              installed.authURI == "https://accounts.google.com/o/oauth2/auth",
              installed.tokenURI == "https://oauth2.googleapis.com/token",
              installed.redirectURIs.contains(where: { uri in
                  uri == "http://localhost" || uri == "http://127.0.0.1"
              }) else {
            throw GoogleMeetIssue.invalidClientFile
        }
        return GoogleMeetOAuthClient(clientID: clientID, clientSecret: secret)
    }
}

struct GoogleMeetCredentialAccess {
    let read: (String) throws -> Data?
    let save: (Data, String) throws -> Void
    let delete: (String) throws -> Void

    static func live(store: IntegrationCredentialStore = IntegrationCredentialStore()) -> Self {
        Self(
            read: { try store.read(account: $0) },
            save: { try store.save($0, account: $1) },
            delete: { try store.delete(account: $0) }
        )
    }
}

struct GoogleMeetPKCE: Equatable {
    let verifier: String
    let challenge: String
    let state: String

    static func generate(randomBytes: (Int) throws -> Data = secureRandomBytes) throws -> Self {
        let verifier = base64URL(try randomBytes(64))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = base64URL(try randomBytes(32))
        guard (43...128).contains(verifier.count), state.count >= 32 else {
            throw GoogleMeetIssue.invalidCallback
        }
        return Self(verifier: verifier, challenge: challenge, state: state)
    }

    private static func secureRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw GoogleMeetIssue.invalidCallback
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GoogleMeetOAuthCallback: Equatable {
    let code: String?
    let error: String?
    let state: String

    static func parse(request data: Data, port: UInt16) throws -> Self {
        guard data.count <= 8 * 1024,
              let request = String(data: data, encoding: .utf8),
              let headerEnd = request.range(of: "\r\n\r\n"),
              request[headerEnd.upperBound...].isEmpty else {
            throw GoogleMeetIssue.invalidCallback
        }
        let lines = request[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { throw GoogleMeetIssue.invalidCallback }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        let headers = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            return (
                line[..<separator].trimmingCharacters(in: .whitespaces).lowercased(),
                line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            )
        }
        let hosts = headers.filter { $0.0 == "host" }.map(\.1)
        let contentLengths = headers.filter { $0.0 == "content-length" }.map(\.1)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              headers.count == lines.count - 1,
              hosts == ["127.0.0.1:\(port)"],
              contentLengths.isEmpty || contentLengths == ["0"],
              !headers.contains(where: { $0.0 == "transfer-encoding" }) else {
            throw GoogleMeetIssue.invalidCallback
        }
        let target = String(parts[1])
        guard target.hasPrefix("/oauth2/callback?"),
              let components = URLComponents(string: "http://127.0.0.1:\(port)\(target)"),
              components.path == "/oauth2/callback", components.fragment == nil else {
            throw GoogleMeetIssue.invalidCallback
        }
        let items = components.queryItems ?? []
        func only(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count == 1 else { return nil }
            return matches[0].value
        }
        let code = only("code")
        let error = only("error")
        guard (code != nil) != (error != nil),
              code.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true,
              error.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              let state = only("state"), !state.isEmpty, state.utf8.count <= 512 else {
            throw GoogleMeetIssue.invalidCallback
        }
        return Self(code: code, error: error, state: state)
    }
}

enum GoogleMeetFormEncoder {
    static func encode(_ fields: [String: String]) -> Data {
        let body = fields.keys.sorted().map { key in
            "\(component(key))=\(component(fields[key] ?? ""))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func component(_ value: String) -> String {
        value.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

@MainActor
protocol GoogleMeetCallbackReceiving: AnyObject, Sendable {
    func start() async throws -> URL
    func receive(timeout: TimeInterval) async throws -> GoogleMeetOAuthCallback
    func cancel()
}

@MainActor
final class GoogleMeetLoopbackServer: GoogleMeetCallbackReceiving {
    private let queue = DispatchQueue(label: "org.openpep.google-meet-loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<GoogleMeetOAuthCallback, Error>?
    private var bufferedResult: Result<GoogleMeetOAuthCallback, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var completed = false

    @MainActor
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.handle(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    Task { @MainActor in
                        guard self?.startContinuation != nil else { return }
                        self?.failStart()
                    }
                }
            } catch {
                startContinuation = nil
                continuation.resume(throwing: GoogleMeetIssue.invalidCallback)
            }
        }
    }

    @MainActor
    func receive(timeout: TimeInterval) async throws -> GoogleMeetOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            if let bufferedResult {
                self.bufferedResult = nil
                continuation.resume(with: bufferedResult)
                return
            }
            callbackContinuation = continuation
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                Task { @MainActor in self?.finish(.failure(GoogleMeetIssue.callbackTimedOut)) }
            }
        }
    }

    @MainActor
    func cancel() {
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: GoogleMeetIssue.callbackCancelled)
        }
        finish(.failure(GoogleMeetIssue.callbackCancelled))
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener?.port?.rawValue,
                  let redirect = URL(string: "http://127.0.0.1:\(rawPort)/oauth2/callback") else {
                failStart()
                return
            }
            port = rawPort
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: redirect)
        case .failed, .cancelled:
            if startContinuation != nil { failStart() }
        default:
            break
        }
    }

    private func failStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(throwing: GoogleMeetIssue.invalidCallback)
        finish(.failure(GoogleMeetIssue.invalidCallback))
    }

    private func accept(_ connection: NWConnection) {
        guard !completed, let port else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data(), port: port)
    }

    private func receive(from connection: NWConnection, accumulated: Data, port: UInt16) {
        let remaining = 8 * 1024 + 1 - accumulated.count
        guard remaining > 0 else { reject(connection); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if buffer.count > 8 * 1024 { self.reject(connection); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    do {
                        let callback = try GoogleMeetOAuthCallback.parse(request: buffer, port: port)
                        self.respond(connection, success: true)
                        self.finish(.success(callback))
                    } catch {
                        self.respond(connection, success: false)
                        self.finish(.failure(error))
                    }
                } else if complete || error != nil {
                    self.reject(connection)
                } else {
                    self.receive(from: connection, accumulated: buffer, port: port)
                }
            }
        }
    }

    private func reject(_ connection: NWConnection) {
        respond(connection, success: false)
        finish(.failure(GoogleMeetIssue.invalidCallback))
    }

    private func respond(_ connection: NWConnection, success: Bool) {
        let message = success
            ? "Autorização recebida. Volte ao OpenPEP e feche esta página."
            : "O retorno não foi aceito. Volte ao OpenPEP."
        let body = "<!doctype html><meta charset=\"utf-8\"><title>OpenPEP</title><p>\(message)</p>"
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func finish(_ result: Result<GoogleMeetOAuthCallback, Error>) {
        guard !completed else { return }
        completed = true
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            bufferedResult = result
        }
    }
}

private final class GoogleMeetNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class GoogleMeetService {
    static let scope = "https://www.googleapis.com/auth/meetings.space.created"
    static let clientAccount = "google.oauth.client"
    static let tokenAccount = "google.oauth.tokens"

    private struct StoredTokens: Codable {
        let clientID: String
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct SpaceResponse: Decodable { let meetingUri: String }

    private let credentials: GoogleMeetCredentialAccess
    private let session: URLSession
    private let now: () -> Date
    private let openBrowser: (URL) -> Bool
    private let callbackReceiver: () -> GoogleMeetCallbackReceiving

    init(
        credentials: GoogleMeetCredentialAccess = .live(),
        session: URLSession? = nil,
        now: @escaping () -> Date = Date.init,
        openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        callbackReceiver: @escaping () -> GoogleMeetCallbackReceiving = { GoogleMeetLoopbackServer() }
    ) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: GoogleMeetNoRedirectDelegate(), delegateQueue: nil)
        }
        self.now = now
        self.openBrowser = openBrowser
        self.callbackReceiver = callbackReceiver
    }

    func importClient(from data: Data) throws {
        let client = try GoogleMeetOAuthClient.parse(download: data)
        try credentials.delete(Self.tokenAccount)
        try credentials.save(try JSONEncoder().encode(client), Self.clientAccount)
    }

    func isConfigured() -> Bool { (try? loadClient()) != nil }
    func isConnected() -> Bool {
        guard let client = try? loadClient(), let tokens = try? loadTokens() else { return false }
        return tokens.clientID == client.clientID
    }

    enum CredentialState {
        case needsClient, readyToConnect, connected
    }

    func credentialState() throws -> CredentialState {
        guard try credentials.read(Self.clientAccount) != nil else { return .needsClient }
        let client = try loadClient()
        guard try credentials.read(Self.tokenAccount) != nil else { return .readyToConnect }
        let tokens = try loadTokens()
        guard tokens.clientID == client.clientID else { return .readyToConnect }
        return .connected
    }

    func disconnect() throws {
        try credentials.delete(Self.tokenAccount)
    }

    func authorizationURL(clientID: String, redirectURI: URL, pkce: GoogleMeetPKCE) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "false")
        ]
        guard let url = components.url else { throw GoogleMeetIssue.invalidCallback }
        return url
    }

    func connect(timeout: TimeInterval = 180) async throws {
        let client = try loadClient()
        let pkce = try GoogleMeetPKCE.generate()
        let receiver = callbackReceiver()
        defer { receiver.cancel() }
        try await withTaskCancellationHandler {
            let redirect = try await receiver.start()
            try Task.checkCancellation()
            let url = try authorizationURL(clientID: client.clientID, redirectURI: redirect, pkce: pkce)
            guard openBrowser(url) else { throw GoogleMeetIssue.browserRejected }
            let callback = try await receiver.receive(timeout: timeout)
            try Task.checkCancellation()
            guard callback.state == pkce.state else { throw GoogleMeetIssue.invalidCallback }
            if callback.error != nil { throw GoogleMeetIssue.authorizationDenied }
            guard let code = callback.code else { throw GoogleMeetIssue.invalidCallback }
            let tokens = try await exchange(
                fields: [
                    "client_id": client.clientID,
                    "code": code,
                    "code_verifier": pkce.verifier,
                    "grant_type": "authorization_code",
                    "redirect_uri": redirect.absoluteString
                ],
                clientSecret: client.clientSecret,
                existingRefreshToken: nil,
                clientID: client.clientID
            )
            try Task.checkCancellation()
            try save(tokens)
        } onCancel: {
            Task { @MainActor in receiver.cancel() }
        }
    }

    func createSpace() async throws -> URL {
        let accessToken = try await validAccessToken()
        let endpoint = URL(string: "https://meet.googleapis.com/v2/spaces")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request, endpoint: endpoint, maximumBytes: 64 * 1024)
        } catch {
            throw GoogleMeetIssue.creationUncertain
        }
        if (400...499).contains(response.statusCode) {
            throw GoogleMeetIssue.requestRejected
        }
        guard (200...299).contains(response.statusCode) else { throw GoogleMeetIssue.creationUncertain }
        guard let space = try? JSONDecoder().decode(SpaceResponse.self, from: data),
              let components = URLComponents(string: space.meetingUri),
              components.scheme == "https", components.host == "meet.google.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil,
              let url = components.url else {
            throw GoogleMeetIssue.creationUncertain
        }
        return url
    }

    private func validAccessToken() async throws -> String {
        let tokens: StoredTokens
        do { tokens = try loadTokens() } catch { throw GoogleMeetIssue.notConnected }
        let client = try loadClient()
        guard tokens.clientID == client.clientID else { throw GoogleMeetIssue.notConnected }
        if tokens.expiresAt > now().addingTimeInterval(60) { return tokens.accessToken }
        let refreshed = try await exchange(
            fields: [
                "client_id": client.clientID,
                "refresh_token": tokens.refreshToken,
                "grant_type": "refresh_token"
            ],
            clientSecret: client.clientSecret,
            existingRefreshToken: tokens.refreshToken,
            clientID: client.clientID
        )
        try Task.checkCancellation()
        try save(refreshed)
        return refreshed.accessToken
    }

    private func exchange(
        fields: [String: String],
        clientSecret: String?,
        existingRefreshToken: String?,
        clientID: String
    ) async throws -> StoredTokens {
        let endpoint = URL(string: "https://oauth2.googleapis.com/token")!
        var form = fields
        if let clientSecret { form["client_secret"] = clientSecret }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = GoogleMeetFormEncoder.encode(form)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request, endpoint: endpoint, maximumBytes: 64 * 1024)
        } catch {
            throw GoogleMeetIssue.invalidTokenResponse
        }
        guard response.statusCode == 200,
              let value = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !value.accessToken.isEmpty, value.accessToken.utf8.count <= 16 * 1024,
              value.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (60...86_400).contains(value.expiresIn),
              value.scope.map({ Set($0.split(separator: " ").map(String.init)) == [Self.scope] }) ?? true,
              let refreshToken = value.refreshToken ?? existingRefreshToken,
              !refreshToken.isEmpty, refreshToken.utf8.count <= 16 * 1024 else {
            throw GoogleMeetIssue.invalidTokenResponse
        }
        return StoredTokens(
            clientID: clientID,
            accessToken: value.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(value.expiresIn))
        )
    }

    private func perform(
        _ request: URLRequest,
        endpoint: URL,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url == endpoint,
              http.expectedContentLength < 0 || http.expectedContentLength <= maximumBytes else {
            throw GoogleMeetIssue.requestRejected
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw GoogleMeetIssue.requestRejected }
            data.append(byte)
        }
        return (data, http)
    }

    private func loadClient() throws -> GoogleMeetOAuthClient {
        guard let data = try credentials.read(Self.clientAccount),
              data.count <= 16 * 1024,
              let client = try? JSONDecoder().decode(GoogleMeetOAuthClient.self, from: data) else {
            throw GoogleMeetIssue.clientNotConfigured
        }
        return client
    }

    private func loadTokens() throws -> StoredTokens {
        guard let data = try credentials.read(Self.tokenAccount),
              data.count <= 64 * 1024,
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data),
              tokens.clientID.hasSuffix(".apps.googleusercontent.com"),
              !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty else {
            throw GoogleMeetIssue.notConnected
        }
        return tokens
    }

    private func save(_ tokens: StoredTokens) throws {
        try credentials.save(try JSONEncoder().encode(tokens), Self.tokenAccount)
    }
}
