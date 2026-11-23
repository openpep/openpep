// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite(.serialized)
@MainActor
struct GoogleMeetServiceTests {
    @Test("imports only bounded desktop credentials pinned to Google endpoints")
    func parsesDesktopClient() throws {
        let accepted = try GoogleMeetOAuthClient.parse(download: clientJSON())
        #expect(accepted.clientID == "synthetic-123.apps.googleusercontent.com")
        #expect(accepted.clientSecret == "synthetic+secret")

        #expect(throws: GoogleMeetIssue.invalidClientFile) {
            _ = try GoogleMeetOAuthClient.parse(download: clientJSON(authURI: "https://attacker.invalid/auth"))
        }
        #expect(throws: GoogleMeetIssue.invalidClientFile) {
            _ = try GoogleMeetOAuthClient.parse(download: Data(repeating: 0x20, count: 65 * 1024))
        }
        let web = Data(#"{"web":{"client_id":"synthetic.apps.googleusercontent.com"}}"#.utf8)
        #expect(throws: GoogleMeetIssue.invalidClientFile) {
            _ = try GoogleMeetOAuthClient.parse(download: web)
        }
    }

    @Test("uses PKCE S256 and only the Meet creation scope")
    func buildsAuthorization() throws {
        let pkce = try GoogleMeetPKCE.generate { count in Data(repeating: count == 64 ? 0x61 : 0x62, count: count) }
        #expect((43...128).contains(pkce.verifier.count))
        #expect(!pkce.challenge.contains("="))
        let service = GoogleMeetService(credentials: memoryCredentials().access)
        let url = try service.authorizationURL(
            clientID: "synthetic-123.apps.googleusercontent.com",
            redirectURI: URL(string: "http://127.0.0.1:49152/oauth2/callback")!,
            pkce: pkce
        )
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["scope"] == GoogleMeetService.scope)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == pkce.state)
        #expect(items["redirect_uri"] == "http://127.0.0.1:49152/oauth2/callback")
        #expect(!items.keys.contains("openid"))
        #expect(url.host == "accounts.google.com")
    }

    @Test("accepts bounded callback metadata and rejects ambiguous HTTP")
    func validatesCallback() throws {
        let request = Data("GET /oauth2/callback?code=synthetic-code&state=synthetic-state&scope=scope&authuser=0&prompt=consent HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nConnection: close\r\n\r\n".utf8)
        let callback = try GoogleMeetOAuthCallback.parse(request: request, port: 49152)
        #expect(callback.code == "synthetic-code")
        #expect(callback.state == "synthetic-state")

        for invalid in [
            "GET /oauth2/callback?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nHost: 127.0.0.1:49152\r\n\r\n",
            "GET /oauth2/callback?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /oauth2/callback?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n",
            "GET /oauth2/callback?code=a&code=b&state=c HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n",
            "GET /oauth2/callback?error=access_denied&state=c HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nContent-Length: 1\r\n\r\nx"
        ] {
            #expect(throws: GoogleMeetIssue.self) {
                _ = try GoogleMeetOAuthCallback.parse(request: Data(invalid.utf8), port: 49152)
            }
        }
    }

    @Test("exchanges code and creates one empty space without patient data")
    func connectsAndCreatesEmptySpace() async throws {
        let memory = memoryCredentials()
        var requests: [URLRequest] = []
        GoogleMeetTestURLProtocol.handler = { request in
            requests.append(materialized(request))
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, Data(#"{"access_token":"synthetic-access","expires_in":3600,"refresh_token":"synthetic-refresh","scope":"https://www.googleapis.com/auth/meetings.space.created","token_type":"Bearer"}"#.utf8))
            }
            return (200, Data(#"{"name":"spaces/synthetic","meetingUri":"https://meet.google.com/abc-defg-hij"}"#.utf8))
        }
        let receiver = MockGoogleMeetReceiver()
        let service = GoogleMeetService(
            credentials: memory.access,
            session: testSession(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            openBrowser: { url in
                receiver.state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
                return true
            },
            callbackReceiver: { receiver }
        )
        try service.importClient(from: clientJSON())
        try await service.connect(timeout: 1)
        let url = try await service.createSpace()

        #expect(url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(requests.count == 2)
        let tokenRequest = try #require(requests.first)
        let tokenBody = String(data: tokenRequest.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(tokenBody.contains("client_secret=synthetic%2Bsecret"))
        #expect(tokenBody.contains("code=synthetic%2Bcode"))
        let create = try #require(requests.last)
        #expect(create.httpMethod == "POST")
        #expect(create.httpBody == Data("{}".utf8))
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
        let body = String(data: create.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("patient"))
        #expect(memory.values[GoogleMeetService.tokenAccount] != nil)
    }

    @Test("does not retry an uncertain creation response")
    func noRetryAfterUncertainPost() async throws {
        let memory = memoryCredentials()
        var createCount = 0
        GoogleMeetTestURLProtocol.handler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, Data(#"{"access_token":"a","expires_in":3600,"refresh_token":"r","token_type":"Bearer"}"#.utf8))
            }
            createCount += 1
            return (503, Data(#"{"error":"temporarily unavailable"}"#.utf8))
        }
        let receiver = MockGoogleMeetReceiver()
        let service = GoogleMeetService(
            credentials: memory.access,
            session: testSession(),
            openBrowser: { url in
                receiver.state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
                return true
            },
            callbackReceiver: { receiver }
        )
        try service.importClient(from: clientJSON())
        try await service.connect(timeout: 1)
        await #expect(throws: GoogleMeetIssue.creationUncertain) { try await service.createSpace() }
        #expect(createCount == 1)
    }

    @Test("cancellation during loopback startup never opens the browser or stores tokens")
    func cancelsDuringStartup() async throws {
        let memory = memoryCredentials()
        let receiver = SlowGoogleMeetReceiver()
        var browserCount = 0
        let service = GoogleMeetService(
            credentials: memory.access,
            session: testSession(),
            openBrowser: { _ in browserCount += 1; return true },
            callbackReceiver: { receiver }
        )
        try service.importClient(from: clientJSON())
        let task = Task { try await service.connect(timeout: 1) }
        for _ in 0..<1_000 {
            if receiver.started { break }
            await Task.yield()
        }
        try #require(receiver.started)
        task.cancel()
        await #expect(throws: GoogleMeetIssue.callbackCancelled) { try await task.value }
        #expect(receiver.cancelled)
        #expect(browserCount == 0)
        #expect(memory.values[GoogleMeetService.tokenAccount] == nil)
    }

    private func clientJSON(authURI: String = "https://accounts.google.com/o/oauth2/auth") -> Data {
        Data("""
        {"installed":{
          "client_id":"synthetic-123.apps.googleusercontent.com",
          "client_secret":"synthetic+secret",
          "auth_uri":"\(authURI)",
          "token_uri":"https://oauth2.googleapis.com/token",
          "redirect_uris":["http://localhost"]
        }}
        """.utf8)
    }

    private func memoryCredentials() -> MemoryGoogleMeetCredentials {
        MemoryGoogleMeetCredentials()
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleMeetTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while data.count <= 128 * 1024 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}

@MainActor
private final class MemoryGoogleMeetCredentials {
    var values: [String: Data] = [:]

    var access: GoogleMeetCredentialAccess {
        GoogleMeetCredentialAccess(
            read: { [weak self] in self?.values[$0] },
            save: { [weak self] data, account in self?.values[account] = data },
            delete: { [weak self] account in self?.values.removeValue(forKey: account) }
        )
    }
}

@MainActor
private final class MockGoogleMeetReceiver: GoogleMeetCallbackReceiving {
    var state: String?
    private(set) var cancelled = false

    func start() async throws -> URL {
        URL(string: "http://127.0.0.1:49152/oauth2/callback")!
    }

    func receive(timeout: TimeInterval) async throws -> GoogleMeetOAuthCallback {
        guard let state else { throw GoogleMeetIssue.invalidCallback }
        return GoogleMeetOAuthCallback(code: "synthetic+code", error: nil, state: state)
    }

    func cancel() { cancelled = true }
}

@MainActor
private final class SlowGoogleMeetReceiver: GoogleMeetCallbackReceiving {
    private(set) var started = false
    private(set) var cancelled = false
    private var startContinuation: CheckedContinuation<URL, Error>?

    func start() async throws -> URL {
        started = true
        return try await withCheckedThrowingContinuation { startContinuation = $0 }
    }

    func receive(timeout: TimeInterval) async throws -> GoogleMeetOAuthCallback {
        throw GoogleMeetIssue.invalidCallback
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        startContinuation?.resume(throwing: GoogleMeetIssue.callbackCancelled)
        startContinuation = nil
    }
}

private final class GoogleMeetTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw GoogleMeetIssue.requestRejected }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(data.count)"
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
