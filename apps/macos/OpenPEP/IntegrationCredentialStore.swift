// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

/// Narrow, non-synchronizing Keychain namespace. Never includes secret values in errors.
struct IntegrationCredentialStore {
    struct Operations {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var add: (CFDictionary) -> OSStatus
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus

        static var live: Operations { Operations(
            copy: { SecItemCopyMatching($0, $1) },
            add: { SecItemAdd($0, nil) },
            update: { SecItemUpdate($0, $1) },
            delete: { SecItemDelete($0) }
        ) }
    }

    let service: String
    private let operations: Operations

    init(service: String = "org.openpep.integrations", operations: Operations = .live) {
        self.service = service
        self.operations = operations
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(account: String) throws -> Data? {
        var values = query(account: account)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copy(values as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IntegrationCredentialIssue.keychain(status) }
        guard let data = result as? Data else { throw IntegrationCredentialIssue.invalidStoredData }
        return data
    }

    func save(_ data: Data, account: String) throws {
        guard !data.isEmpty else { throw IntegrationCredentialIssue.emptyValue }
        let identity = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Update first: a failed replacement must not erase the previous credential.
        var status = operations.update(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = operations.add(identity.merging(attributes) { _, new in new } as CFDictionary)
            if status == errSecDuplicateItem {
                status = operations.update(identity as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw IntegrationCredentialIssue.keychain(status) }
    }

    func delete(account: String) throws {
        let status = operations.delete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IntegrationCredentialIssue.keychain(status)
        }
    }
}

enum IntegrationCredentialIssue: Error, LocalizedError {
    case keychain(OSStatus), invalidStoredData, emptyValue, invalidAPIKey

    var errorDescription: String? {
        switch self {
        case .keychain:
            "Não foi possível acessar o Chaves do macOS. Desbloqueie o Mac e tente novamente no aplicativo assinado."
        case .invalidStoredData:
            "A credencial guardada não pôde ser lida. Configure-a novamente."
        case .emptyValue:
            "Informe a credencial antes de guardar."
        case .invalidAPIKey:
            "Cole somente a chave secreta criada no painel OpenAI, sem aspas ou espaços no meio."
        }
    }
}

enum OpenAIKeyInput {
    static let account = "openai.api-key"

    /// Syntax check only. Does not assert authentication, billing or model access.
    static func normalized(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), (20...512).contains(key.utf8.count),
              key.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { throw IntegrationCredentialIssue.invalidAPIKey }
        return key
    }
}
