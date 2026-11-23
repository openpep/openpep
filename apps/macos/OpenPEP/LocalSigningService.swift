// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct LocalSigningScope: Equatable, Sendable {
    let vaultID: String
    let deviceID: String

    var keychainAccount: String { "\(vaultID)|\(deviceID)" }
}

struct LocalSigningIdentity: Codable, Equatable, Sendable {
    let storageVersion: Int
    let vaultID: String
    let deviceID: String
    let userID: String
    let keyID: String
    let algorithm: String
    let publicKeyX963: String
    let authorizedFrom: String

    init(
        scope: LocalSigningScope,
        userID: String,
        keyID: String,
        publicKeyX963: String,
        authorizedFrom: String
    ) {
        storageVersion = 1
        vaultID = scope.vaultID
        deviceID = scope.deviceID
        self.userID = userID
        self.keyID = keyID
        algorithm = "ES256"
        self.publicKeyX963 = publicKeyX963
        self.authorizedFrom = authorizedFrom
    }

    var scope: LocalSigningScope {
        LocalSigningScope(vaultID: vaultID, deviceID: deviceID)
    }
}

struct LocalSigningCandidate: Equatable, Sendable {
    let userID: String
    let keyID: String
    let authorizedFrom: String
}

struct LocalEventHash: Equatable, Sendable {
    let bytes: Data

    init(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw LocalSigningIssue.invalidEventHash }
        self.bytes = bytes
    }
}

struct LocalSigningCheck: Equatable, Sendable {
    let identity: LocalSigningIdentity
    let signature: Data
}

enum LocalSigningStatus: Equatable, Sendable {
    case unavailable
    case notPrepared
    case configured(LocalSigningIdentity)
    case verified(LocalSigningIdentity)
}

struct LocalSigningStoredEnvelope: Codable, Equatable, Sendable {
    let identity: LocalSigningIdentity
    let keyHandle: Data
}

enum LocalSigningReconciliation: Equatable, Sendable {
    case create
    case use(LocalSigningIdentity)
    case repairMetadata(LocalSigningIdentity)

    static func resolve(
        metadata: LocalSigningIdentity?,
        protectedIdentity: LocalSigningIdentity?
    ) throws -> LocalSigningReconciliation {
        switch (metadata, protectedIdentity) {
        case (nil, nil):
            return .create
        case let (nil, protectedIdentity?):
            return .repairMetadata(protectedIdentity)
        case (_?, nil):
            throw LocalSigningIssue.identityCorrupted
        case let (metadata?, protectedIdentity?) where metadata == protectedIdentity:
            return .use(metadata)
        default:
            throw LocalSigningIssue.identityCorrupted
        }
    }
}

enum LocalSigningIssue: Error, LocalizedError, Equatable {
    case secureEnclaveUnavailable
    case authenticationUnavailable
    case authenticationFailed
    case identityCorrupted
    case identityAlreadyExists
    case invalidEventHash
    case invalidPublicKey
    case invalidSignature
    case developmentSigningRequired
    case keychain(Int32)

    static func fromKeychainStatus(_ status: OSStatus) -> LocalSigningIssue {
        status == errSecMissingEntitlement ? .developmentSigningRequired : .keychain(status)
    }

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            "O Secure Enclave não está disponível neste Mac. Nenhuma chave alternativa foi criada."
        case .authenticationUnavailable:
            "A autenticação local do Mac não está disponível."
        case .authenticationFailed:
            "A autenticação local não foi concluída. Nenhuma chave foi criada ou usada."
        case .identityCorrupted:
            "A identidade local armazenada está incompleta ou diverge deste vault."
        case .identityAlreadyExists:
            "Já existe uma chave local para este identificador. Ela não foi substituída."
        case .invalidEventHash:
            "A assinatura aceita somente um hash de evento com 32 bytes."
        case .invalidPublicKey:
            "A chave pública local não possui o formato P-256 esperado."
        case .invalidSignature:
            "A assinatura local não possui o formato ES256 low-S esperado."
        case .developmentSigningRequired:
            "Esta compilação não possui uma assinatura e um perfil autorizados para o Data Protection Keychain. Verifique a equipe e a capability privada do Keychain em Signing & Capabilities, depois execute novamente."
        case let .keychain(status):
            "O Keychain recusou a operação (código \(status))."
        }
    }
}

struct LocalAuthenticationSession: Equatable, Sendable {
    static let defaultDuration: TimeInterval = 6 * 60 * 60

    let duration: TimeInterval
    private(set) var authenticatedAt: Date?

    init(
        duration: TimeInterval = LocalAuthenticationSession.defaultDuration,
        authenticatedAt: Date? = nil
    ) {
        self.duration = duration
        self.authenticatedAt = authenticatedAt
    }

    func isActive(at date: Date = Date()) -> Bool {
        guard let authenticatedAt, date >= authenticatedAt else { return false }
        return date < authenticatedAt.addingTimeInterval(duration)
    }

    func expirationDate(at date: Date = Date()) -> Date? {
        guard isActive(at: date), let authenticatedAt else { return nil }
        return authenticatedAt.addingTimeInterval(duration)
    }

    mutating func registerSuccessfulAuthentication(at date: Date = Date()) {
        authenticatedAt = date
    }

    mutating func clear() {
        authenticatedAt = nil
    }
}

@MainActor
protocol LocalSigningAuthenticating {
    func authenticate(reason: String) async throws -> LAContext
}

@MainActor
protocol LocalSigningKeyProviding {
    var isSecureEnclaveAvailable: Bool { get }

    func existingIdentity(for scope: LocalSigningScope) throws -> LocalSigningIdentity?
    func prepareIdentity(
        for scope: LocalSigningScope,
        candidate: LocalSigningCandidate,
        context: LAContext
    ) throws -> LocalSigningIdentity
    func signEventHash(
        _ eventHash: LocalEventHash,
        identity: LocalSigningIdentity,
        context: LAContext
    ) throws -> Data
}

@MainActor
struct LocalSigningService {
    private static let syntheticChallenge = Data(SHA256.hash(
        data: Data("OpenPEP MAC-004 synthetic signing check".utf8)
    ))

    private let authenticator: any LocalSigningAuthenticating
    private let keyProvider: any LocalSigningKeyProviding
    private let now: () -> Date

    init(
        authenticator: any LocalSigningAuthenticating = SystemLocalAuthenticator(),
        keyProvider: any LocalSigningKeyProviding = KeychainSecureEnclaveProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.keyProvider = keyProvider
        self.now = now
    }

    func existingIdentity(for scope: LocalSigningScope) throws -> LocalSigningIdentity? {
        try keyProvider.existingIdentity(for: scope)
    }

    func status(for scope: LocalSigningScope) throws -> LocalSigningStatus {
        guard keyProvider.isSecureEnclaveAvailable else { return .unavailable }
        guard let identity = try keyProvider.existingIdentity(for: scope) else {
            return .notPrepared
        }
        return .configured(identity)
    }

    func prepareAndCheck(for scope: LocalSigningScope) async throws -> LocalSigningCheck {
        guard keyProvider.isSecureEnclaveAvailable else {
            throw LocalSigningIssue.secureEnclaveUnavailable
        }
        let context = try await authenticator.authenticate(
            reason: "Preparar ou testar a chave local de assinatura do OpenPEP"
        )
        let candidate = try makeCandidate(at: now())
        let identity = try keyProvider.prepareIdentity(
            for: scope,
            candidate: candidate,
            context: context
        )
        let eventHash = try LocalEventHash(Self.syntheticChallenge)
        let rawSignature = try keyProvider.signEventHash(
            eventHash,
            identity: identity,
            context: context
        )
        let normalized = try LocalSignatureNormalizer.normalize(rawSignature)
        try verify(
            signature: normalized,
            eventHash: eventHash.bytes,
            publicKeyX963: identity.publicKeyX963
        )
        return LocalSigningCheck(identity: identity, signature: normalized)
    }

    private func makeCandidate(at date: Date) throws -> LocalSigningCandidate {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return LocalSigningCandidate(
            userID: "usr_\(try UUIDv7.generate(at: date))",
            keyID: "key_\(try UUIDv7.generate(at: date))",
            authorizedFrom: formatter.string(from: date)
        )
    }

    private func verify(signature: Data, eventHash: Data, publicKeyX963: String) throws {
        guard let publicData = Data(base64URLEncoded: publicKeyX963),
              publicData.count == 65,
              publicData.first == 0x04,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData) else {
            throw LocalSigningIssue.invalidPublicKey
        }
        guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              publicKey.isValidSignature(parsed, for: eventHash) else {
            throw LocalSigningIssue.invalidSignature
        }
    }
}

@MainActor
struct SystemLocalAuthenticator: LocalSigningAuthenticating {
    func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedReason = reason
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw LocalSigningIssue.authenticationUnavailable
        }
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) else {
                throw LocalSigningIssue.authenticationFailed
            }
            return context
        } catch {
            throw LocalSigningIssue.authenticationFailed
        }
    }
}

@MainActor
struct KeychainSecureEnclaveProvider: LocalSigningKeyProviding {
    private static let metadataService = "org.openpep.OpenPEP.local-signing-metadata.v1"
    private static let keyService = "org.openpep.OpenPEP.local-signing-key.v1"

    var isSecureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    func existingIdentity(for scope: LocalSigningScope) throws -> LocalSigningIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.metadataService,
            kSecAttrAccount as String: scope.keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LocalSigningIssue.fromKeychainStatus(status)
        }
        guard let identity = try? JSONDecoder().decode(LocalSigningIdentity.self, from: data) else {
            throw LocalSigningIssue.identityCorrupted
        }
        try validateIdentity(identity, for: scope)
        return identity
    }

    func prepareIdentity(
        for scope: LocalSigningScope,
        candidate: LocalSigningCandidate,
        context: LAContext
    ) throws -> LocalSigningIdentity {
        guard isSecureEnclaveAvailable else {
            throw LocalSigningIssue.secureEnclaveUnavailable
        }

        let metadata = try existingIdentity(for: scope)
        let envelope = try storedEnvelope(for: scope, context: context)
        switch try LocalSigningReconciliation.resolve(
            metadata: metadata,
            protectedIdentity: envelope?.identity
        ) {
        case let .use(identity):
            guard let envelope else { throw LocalSigningIssue.identityCorrupted }
            _ = try privateKey(from: envelope, expected: identity, context: context)
            return identity
        case let .repairMetadata(identity):
            guard let envelope else { throw LocalSigningIssue.identityCorrupted }
            _ = try privateKey(from: envelope, expected: identity, context: context)
            try addMetadata(identity)
            return identity
        case .create:
            break
        }

        let keyAccess = try accessControl(flags: [.privateKeyUsage, .userPresence])
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: keyAccess,
            authenticationContext: context
        )
        let publicData = key.publicKey.x963Representation
        guard publicData.count == 65, publicData.first == 0x04 else {
            throw LocalSigningIssue.invalidPublicKey
        }
        let identity = LocalSigningIdentity(
            scope: scope,
            userID: candidate.userID,
            keyID: candidate.keyID,
            publicKeyX963: publicData.base64URLEncodedString(),
            authorizedFrom: candidate.authorizedFrom
        )
        try addProtectedEnvelope(
            LocalSigningStoredEnvelope(identity: identity, keyHandle: key.dataRepresentation),
            context: context
        )
        try addMetadata(identity)
        return identity
    }

    func signEventHash(
        _ eventHash: LocalEventHash,
        identity: LocalSigningIdentity,
        context: LAContext
    ) throws -> Data {
        let key = try privateKey(for: identity, context: context)
        let signature = try key.signature(for: eventHash.bytes)
        return signature.rawRepresentation
    }

    private func privateKey(
        for identity: LocalSigningIdentity,
        context: LAContext
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let envelope = try storedEnvelope(for: identity.scope, context: context) else {
            throw LocalSigningIssue.identityCorrupted
        }
        return try privateKey(from: envelope, expected: identity, context: context)
    }

    private func storedEnvelope(
        for scope: LocalSigningScope,
        context: LAContext
    ) throws -> LocalSigningStoredEnvelope? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: scope.keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let envelope = try? JSONDecoder().decode(
                  LocalSigningStoredEnvelope.self,
                  from: data
              ),
              envelope.identity.scope == scope else {
            if status == errSecSuccess { throw LocalSigningIssue.identityCorrupted }
            throw LocalSigningIssue.fromKeychainStatus(status)
        }
        try validateIdentity(envelope.identity, for: scope)
        return envelope
    }

    private func privateKey(
        from envelope: LocalSigningStoredEnvelope,
        expected identity: LocalSigningIdentity,
        context: LAContext
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard envelope.identity == identity else { throw LocalSigningIssue.identityCorrupted }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: envelope.keyHandle,
                authenticationContext: context
            )
        } catch {
            throw LocalSigningIssue.identityCorrupted
        }
        guard key.publicKey.x963Representation.base64URLEncodedString()
            == identity.publicKeyX963 else {
            throw LocalSigningIssue.identityCorrupted
        }
        return key
    }

    private func addProtectedEnvelope(
        _ envelope: LocalSigningStoredEnvelope,
        context: LAContext
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let itemAccess = try accessControl(flags: [.userPresence])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: envelope.identity.scope.keychainAccount,
            kSecAttrLabel as String: "OpenPEP local signing key",
            kSecAttrAccessControl as String: itemAccess,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw LocalSigningIssue.identityAlreadyExists }
        guard status == errSecSuccess else {
            throw LocalSigningIssue.fromKeychainStatus(status)
        }
    }

    private func addMetadata(_ identity: LocalSigningIdentity) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.metadataService,
            kSecAttrAccount as String: identity.scope.keychainAccount,
            kSecAttrLabel as String: "OpenPEP local signing identity",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw LocalSigningIssue.identityAlreadyExists }
        guard status == errSecSuccess else {
            throw LocalSigningIssue.fromKeychainStatus(status)
        }
    }

    private func accessControl(flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            flags,
            &error
        ) else {
            throw LocalSigningIssue.authenticationUnavailable
        }
        return access
    }

    private func isTypedUUIDv7(_ value: String, prefix: String) -> Bool {
        let pattern = "^\(prefix)_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func validateIdentity(
        _ identity: LocalSigningIdentity,
        for scope: LocalSigningScope
    ) throws {
        guard identity.storageVersion == 1,
              identity.scope == scope,
              identity.algorithm == "ES256",
              isTypedUUIDv7(identity.userID, prefix: "usr"),
              isTypedUUIDv7(identity.keyID, prefix: "key"),
              identity.authorizedFrom.hasSuffix("Z"),
              ISO8601DateFormatter().date(from: identity.authorizedFrom) != nil,
              let publicKey = Data(base64URLEncoded: identity.publicKeyX963),
              publicKey.count == 65,
              publicKey.first == 0x04,
              (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else {
            throw LocalSigningIssue.identityCorrupted
        }
    }
}

enum LocalSignatureNormalizer {
    private static let order = bytes(
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
    )
    private static let halfOrder = bytes(
        "7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8"
    )

    static func normalize(_ signature: Data) throws -> Data {
        guard signature.count == 64 else { throw LocalSigningIssue.invalidSignature }
        let r = Array(signature.prefix(32))
        let s = Array(signature.suffix(32))
        guard !isZero(r), !isZero(s), compare(r, order) < 0, compare(s, order) < 0 else {
            throw LocalSigningIssue.invalidSignature
        }
        guard compare(s, halfOrder) > 0 else { return signature }
        return Data(r + subtract(order, s))
    }

    static func isLowS(_ signature: Data) -> Bool {
        guard signature.count == 64 else { return false }
        return compare(Array(signature.suffix(32)), halfOrder) <= 0
    }

    private static func isZero(_ value: [UInt8]) -> Bool {
        value.allSatisfy { $0 == 0 }
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }

    private static func subtract(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: lhs.count)
        var borrow = 0
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(lhs[index]) - Int(rhs[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return result
    }

    private static func bytes(_ hexadecimal: String) -> [UInt8] {
        stride(from: 0, to: hexadecimal.count, by: 2).map { offset in
            let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
            let end = hexadecimal.index(start, offsetBy: 2)
            return UInt8(hexadecimal[start..<end], radix: 16)!
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized
            + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: padded)
        guard base64URLEncodedString() == value else { return nil }
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
