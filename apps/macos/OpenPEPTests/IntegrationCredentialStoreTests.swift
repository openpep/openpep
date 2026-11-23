// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security
import Testing
@testable import OpenPEP

struct IntegrationCredentialStoreTests {
    @Test("stores a new credential only in the scoped non-synchronizing Keychain item")
    func newCredential() throws {
        let fake = CredentialOperationsFake()
        fake.updateStatus = errSecItemNotFound
        let store = IntegrationCredentialStore(service: "synthetic.test", operations: fake.operations)
        try store.save(Data("synthetic-credential".utf8), account: "openai.api-key")
        #expect(fake.deleted.isEmpty)
        let query = try #require(fake.added.first)
        #expect(query[kSecAttrService as String] as? String == "synthetic.test")
        #expect(query[kSecAttrAccount as String] as? String == "openai.api-key")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test("failed replacement never deletes the previously stored credential")
    func failedReplacement() {
        let fake = CredentialOperationsFake()
        fake.updateStatus = errSecInteractionNotAllowed
        let store = IntegrationCredentialStore(operations: fake.operations)
        #expect(throws: IntegrationCredentialIssue.self) {
            try store.save(Data("synthetic-replacement".utf8), account: "openai.api-key")
        }
        #expect(fake.deleted.isEmpty)
        #expect(fake.added.isEmpty)
    }

    @Test("distinguishes absent key from a locked or denied Keychain")
    func readStatus() throws {
        let fake = CredentialOperationsFake()
        let store = IntegrationCredentialStore(operations: fake.operations)
        fake.copyStatus = errSecItemNotFound
        #expect(try store.read(account: "google.oauth.tokens") == nil)
        fake.copyStatus = errSecInteractionNotAllowed
        #expect(throws: IntegrationCredentialIssue.self) { try store.read(account: "google.oauth.tokens") }
        fake.copyStatus = errSecSuccess
        fake.data = Data("synthetic-token".utf8)
        #expect(try store.read(account: "google.oauth.tokens") == fake.data)
    }

    @Test("removal is account scoped and absent key removal is idempotent")
    func removal() throws {
        let fake = CredentialOperationsFake()
        fake.deleteStatus = errSecItemNotFound
        let store = IntegrationCredentialStore(operations: fake.operations)
        try store.delete(account: "openai.api-key")
        let query = try #require(fake.deleted.first)
        #expect(query[kSecAttrAccount as String] as? String == "openai.api-key")
        #expect(query[kSecAttrService as String] as? String == "org.openpep.integrations")
    }

    @Test("API key input rejects prose, quotes, controls and oversized values")
    func keyInput() throws {
        let key = "sk-synthetic-not-a-real-key-1234"
        #expect(try OpenAIKeyInput.normalized(" \n" + key + "\n") == key)
        for invalid in ["", "senha", "Bearer " + key, "\"" + key + "\"", key + "\nextra", "sk-" + String(repeating: "a", count: 600)] {
            #expect(throws: IntegrationCredentialIssue.self) { try OpenAIKeyInput.normalized(invalid) }
        }
    }
}

private final class CredentialOperationsFake {
    var updateStatus: OSStatus = errSecSuccess
    var copyStatus: OSStatus = errSecItemNotFound
    var deleteStatus: OSStatus = errSecSuccess
    var data: Data?
    var added: [[String: Any]] = []
    var deleted: [[String: Any]] = []

    var operations: IntegrationCredentialStore.Operations {
        .init(copy: { _, result in
            result?.pointee = self.data as CFData?
            return self.copyStatus
        }, add: { query in
            self.added.append(query as! [String: Any])
            return errSecSuccess
        }, update: { _, _ in self.updateStatus }, delete: { query in
            self.deleted.append(query as! [String: Any])
            return self.deleteStatus
        })
    }
}
