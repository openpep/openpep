// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import OpenPEP

@MainActor
struct LocalSigningServiceTests {
    private let scope = LocalSigningScope(
        vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
        deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
    )

    @Test("keeps authentication in memory for six fixed hours")
    func authenticationSessionHasFixedDuration() {
        let start = Date(timeIntervalSince1970: 1_788_134_400)
        var session = LocalAuthenticationSession()
        #expect(!session.isActive(at: start))

        session.registerSuccessfulAuthentication(at: start)
        #expect(session.isActive(at: start))
        #expect(session.isActive(at: start.addingTimeInterval(6 * 60 * 60 - 1)))
        #expect(!session.isActive(at: start.addingTimeInterval(6 * 60 * 60)))
        #expect(session.expirationDate(at: start) == start.addingTimeInterval(6 * 60 * 60))

        session.clear()
        #expect(!session.isActive(at: start.addingTimeInterval(60)))
        #expect(session.expirationDate(at: start.addingTimeInterval(60)) == nil)
    }

    @Test("refuses signing input outside the 32-byte event-hash contract")
    func rejectsInvalidEventHashLength() throws {
        do {
            _ = try LocalEventHash(Data(repeating: 0, count: 31))
            Issue.record("31 bytes deveriam ser recusados")
        } catch let issue as LocalSigningIssue {
            #expect(issue == .invalidEventHash)
        }
        #expect(try LocalEventHash(Data(repeating: 0, count: 32)).bytes.count == 32)
    }

    @Test("explains a Data Protection Keychain build without signing entitlement")
    func explainsMissingDevelopmentSigning() {
        #expect(
            LocalSigningIssue.fromKeychainStatus(errSecMissingEntitlement)
                == .developmentSigningRequired
        )
        #expect(LocalSigningIssue.fromKeychainStatus(errSecAuthFailed) == .keychain(errSecAuthFailed))
        #expect(
            LocalSigningIssue.developmentSigningRequired.errorDescription?
                .contains("Signing & Capabilities") == true
        )
    }

    @Test("normalizes high-S P1363 and rejects invalid components")
    func normalizesP1363LowS() throws {
        let lowSignature = try goldenSignature()
        #expect(lowSignature.count == 64)
        #expect(LocalSignatureNormalizer.isLowS(lowSignature))

        let highSignature = try highSVersion(of: lowSignature)
        #expect(!LocalSignatureNormalizer.isLowS(highSignature))
        #expect(try LocalSignatureNormalizer.normalize(highSignature) == lowSignature)
        #expect(try LocalSignatureNormalizer.normalize(lowSignature) == lowSignature)

        for invalid in [
            Data(repeating: 1, count: 63),
            Data(repeating: 0, count: 64),
            Data(repeating: 0xff, count: 64),
        ] {
            do {
                _ = try LocalSignatureNormalizer.normalize(invalid)
                Issue.record("a assinatura P1363 inválida deveria ser recusada")
            } catch let issue as LocalSigningIssue {
                #expect(issue == .invalidSignature)
            }
        }
    }

    @Test("fails closed before authentication when Secure Enclave is unavailable")
    func refusesUnavailableSecureEnclave() async throws {
        let authenticator = FakeAuthenticator()
        let provider = FakeKeyProvider(isSecureEnclaveAvailable: false)
        let service = LocalSigningService(
            authenticator: authenticator,
            keyProvider: provider,
            now: { Date(timeIntervalSince1970: 0) }
        )

        do {
            _ = try await service.prepareAndCheck(for: scope)
            Issue.record("Secure Enclave indisponível deveria bloquear a preparação")
        } catch let issue as LocalSigningIssue {
            #expect(issue == .secureEnclaveUnavailable)
        }
        #expect(authenticator.calls == 0)
        #expect(provider.prepareCalls == 0)
        #expect(provider.signCalls == 0)
    }

    @Test("authentication failure never prepares or uses a key")
    func authenticationFailureDoesNotReachKey() async throws {
        let authenticator = FakeAuthenticator(error: .authenticationFailed)
        let provider = FakeKeyProvider()
        let service = LocalSigningService(
            authenticator: authenticator,
            keyProvider: provider,
            now: { Date(timeIntervalSince1970: 0) }
        )

        do {
            _ = try await service.prepareAndCheck(for: scope)
            Issue.record("a autenticação recusada deveria interromper a preparação")
        } catch let issue as LocalSigningIssue {
            #expect(issue == .authenticationFailed)
        }
        #expect(authenticator.calls == 1)
        #expect(provider.prepareCalls == 0)
        #expect(provider.signCalls == 0)
    }

    @Test("prepares once, reuses the same identity and verifies normalized signatures")
    func preparesAndReusesIdentity() async throws {
        let authenticator = FakeAuthenticator()
        let provider = FakeKeyProvider(returnsHighS: true)
        let fixedDate = Date(timeIntervalSince1970: 1_788_131_200)
        let service = LocalSigningService(
            authenticator: authenticator,
            keyProvider: provider,
            now: { fixedDate }
        )

        let first = try await service.prepareAndCheck(for: scope)
        let second = try await service.prepareAndCheck(for: scope)

        #expect(first.identity == second.identity)
        #expect(first.identity.scope == scope)
        #expect(first.identity.userID.hasPrefix("usr_"))
        #expect(first.identity.keyID.hasPrefix("key_"))
        #expect(first.identity.algorithm == "ES256")
        #expect(first.identity.publicKeyX963.count == 87)
        #expect(first.signature.count == 64)
        #expect(LocalSignatureNormalizer.isLowS(first.signature))
        #expect(authenticator.calls == 2)
        #expect(provider.prepareCalls == 2)
        #expect(provider.createdIdentities == 1)
        #expect(provider.signCalls == 2)
    }

    @Test("reading status does not authenticate or touch private key use")
    func readsStatusWithoutPrompt() throws {
        let authenticator = FakeAuthenticator()
        let provider = FakeKeyProvider()
        let identity = provider.seedIdentity(for: scope)
        let service = LocalSigningService(
            authenticator: authenticator,
            keyProvider: provider
        )

        #expect(try service.existingIdentity(for: scope) == identity)
        #expect(authenticator.calls == 0)
        #expect(provider.prepareCalls == 0)
        #expect(provider.signCalls == 0)
    }

    @Test("status distinguishes unavailable, unprepared and configured without authentication")
    func reportsReadOnlyStatus() throws {
        let authenticator = FakeAuthenticator()
        let unavailable = LocalSigningService(
            authenticator: authenticator,
            keyProvider: FakeKeyProvider(isSecureEnclaveAvailable: false)
        )
        #expect(try unavailable.status(for: scope) == .unavailable)

        let emptyProvider = FakeKeyProvider()
        let empty = LocalSigningService(authenticator: authenticator, keyProvider: emptyProvider)
        #expect(try empty.status(for: scope) == .notPrepared)

        let configuredProvider = FakeKeyProvider()
        let identity = configuredProvider.seedIdentity(for: scope)
        let configured = LocalSigningService(
            authenticator: authenticator,
            keyProvider: configuredProvider
        )
        #expect(try configured.status(for: scope) == .configured(identity))
        #expect(authenticator.calls == 0)
    }

    @Test("reconciliation repairs an interrupted metadata write and rejects the inverse")
    func reconcilesPartialStorage() throws {
        let identity = FakeKeyProvider().seedIdentity(for: scope)
        #expect(try LocalSigningReconciliation.resolve(
            metadata: nil,
            protectedIdentity: nil
        ) == .create)
        #expect(try LocalSigningReconciliation.resolve(
            metadata: nil,
            protectedIdentity: identity
        ) == .repairMetadata(identity))
        #expect(try LocalSigningReconciliation.resolve(
            metadata: identity,
            protectedIdentity: identity
        ) == .use(identity))

        do {
            _ = try LocalSigningReconciliation.resolve(
                metadata: identity,
                protectedIdentity: nil
            )
            Issue.record("metadata sem item protegido deveria ser recusada")
        } catch let issue as LocalSigningIssue {
            #expect(issue == .identityCorrupted)
        }
    }

    @Test("rejects an invalid public key and a signature from another key")
    func rejectsMismatchedCryptographicMaterial() async throws {
        for provider in [
            FakeKeyProvider(invalidPublicKey: true),
            FakeKeyProvider(signsWithAnotherKey: true),
        ] {
            let service = LocalSigningService(
                authenticator: FakeAuthenticator(),
                keyProvider: provider,
                now: { Date(timeIntervalSince1970: 0) }
            )
            do {
                _ = try await service.prepareAndCheck(for: scope)
                Issue.record("material criptográfico divergente deveria ser recusado")
            } catch let issue as LocalSigningIssue {
                #expect(issue == .invalidPublicKey || issue == .invalidSignature)
            }
        }
    }

    @Test("internal Keychain metadata round-trips without becoming a protocol fixture")
    func roundTripsInternalMetadata() throws {
        let identity = FakeKeyProvider().seedIdentity(for: scope)
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(LocalSigningIdentity.self, from: encoded)
        #expect(decoded == identity)
        #expect(decoded.storageVersion == 1)
    }

    @Test("preparing the local credential does not modify the vault")
    func doesNotModifyVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-local-signing-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appending(path: "vault.yaml")
        let original = Data("synthetic vault bytes\n".utf8)
        try original.write(to: manifest)
        let before = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate]

        let service = LocalSigningService(
            authenticator: FakeAuthenticator(),
            keyProvider: FakeKeyProvider(),
            now: { Date(timeIntervalSince1970: 0) }
        )
        _ = try await service.prepareAndCheck(for: scope)

        #expect(try Data(contentsOf: manifest) == original)
        let after = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate]
        #expect(before as? Date == after as? Date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vault.yaml"])
    }

    private func goldenSignature() throws -> Data {
        let ledgerURL = repositoryRoot.appending(
            path: "fixtures/clinical-ledger-v1/golden/two-events/ledger.ndjson"
        )
        let data = try Data(contentsOf: ledgerURL)
        let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
        let event = try JSONDecoder().decode(SignatureFixture.self, from: Data(line.utf8))
        return try #require(Data(base64URLEncodedForTest: event.signature))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func highSVersion(of lowSignature: Data) throws -> Data {
        let order = try hexadecimal(
            "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
        )
        let s = Array(lowSignature.suffix(32))
        var highS = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            var value = Int(order[index]) - Int(s[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            highS[index] = UInt8(value)
        }
        return Data(Array(lowSignature.prefix(32)) + highS)
    }

    private func hexadecimal(_ value: String) throws -> [UInt8] {
        guard value.count.isMultiple(of: 2) else { throw LocalSigningIssue.invalidSignature }
        return try stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            return try #require(UInt8(value[start..<end], radix: 16))
        }
    }
}

@MainActor
private final class FakeAuthenticator: LocalSigningAuthenticating {
    private let error: LocalSigningIssue?
    private(set) var calls = 0

    init(error: LocalSigningIssue? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws -> LAContext {
        calls += 1
        if let error { throw error }
        return LAContext()
    }
}

@MainActor
private final class FakeKeyProvider: LocalSigningKeyProviding {
    let isSecureEnclaveAvailable: Bool
    private let privateKey = P256.Signing.PrivateKey()
    private let returnsHighS: Bool
    private let invalidPublicKey: Bool
    private let signsWithAnotherKey: Bool
    private let otherPrivateKey = P256.Signing.PrivateKey()
    private var identity: LocalSigningIdentity?
    private(set) var prepareCalls = 0
    private(set) var createdIdentities = 0
    private(set) var signCalls = 0

    init(
        isSecureEnclaveAvailable: Bool = true,
        returnsHighS: Bool = false,
        invalidPublicKey: Bool = false,
        signsWithAnotherKey: Bool = false
    ) {
        self.isSecureEnclaveAvailable = isSecureEnclaveAvailable
        self.returnsHighS = returnsHighS
        self.invalidPublicKey = invalidPublicKey
        self.signsWithAnotherKey = signsWithAnotherKey
    }

    func existingIdentity(for scope: LocalSigningScope) throws -> LocalSigningIdentity? {
        guard identity?.scope == scope else { return nil }
        return identity
    }

    func prepareIdentity(
        for scope: LocalSigningScope,
        candidate: LocalSigningCandidate,
        context: LAContext
    ) throws -> LocalSigningIdentity {
        prepareCalls += 1
        if let identity { return identity }
        createdIdentities += 1
        let created = LocalSigningIdentity(
            scope: scope,
            userID: candidate.userID,
            keyID: candidate.keyID,
            publicKeyX963: invalidPublicKey
                ? Data(repeating: 0, count: 65).base64URLEncodedForTest()
                : privateKey.publicKey.x963Representation.base64URLEncodedForTest(),
            authorizedFrom: candidate.authorizedFrom
        )
        identity = created
        return created
    }

    func signEventHash(
        _ eventHash: LocalEventHash,
        identity: LocalSigningIdentity,
        context: LAContext
    ) throws -> Data {
        signCalls += 1
        let signingKey = signsWithAnotherKey ? otherPrivateKey : privateKey
        let raw = try signingKey.signature(for: eventHash.bytes).rawRepresentation
        let low = try LocalSignatureNormalizer.normalize(raw)
        guard returnsHighS else { return low }
        return try makeHighS(low)
    }

    func seedIdentity(for scope: LocalSigningScope) -> LocalSigningIdentity {
        let seeded = LocalSigningIdentity(
            scope: scope,
            userID: "usr_0198f4a0-0000-7000-8000-000000000001",
            keyID: "key_0198f5c1-0000-7000-8000-000000000010",
            publicKeyX963: privateKey.publicKey.x963Representation.base64URLEncodedForTest(),
            authorizedFrom: "2026-08-30T17:00:00Z"
        )
        identity = seeded
        return seeded
    }

    private func makeHighS(_ lowSignature: Data) throws -> Data {
        let orderHex = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
        let order = stride(from: 0, to: orderHex.count, by: 2).map { offset -> UInt8 in
            let start = orderHex.index(orderHex.startIndex, offsetBy: offset)
            let end = orderHex.index(start, offsetBy: 2)
            return UInt8(orderHex[start..<end], radix: 16)!
        }
        let s = Array(lowSignature.suffix(32))
        var high = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            var value = Int(order[index]) - Int(s[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            high[index] = UInt8(value)
        }
        return Data(Array(lowSignature.prefix(32)) + high)
    }
}

private struct SignatureFixture: Decodable {
    let signature: String
}

private extension Data {
    init?(base64URLEncodedForTest value: String) {
        let normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized
            + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedForTest() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
