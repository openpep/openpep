// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("BACKUP-001 local history")
struct VaultBackupHistoryTests {
    @Test("persists receipts and separates vault identifiers")
    func persistsAndSeparatesVaults() throws {
        try withIsolatedDefaults { defaults in
            let firstVaultID = "vlt_0198f5c0-0000-7000-8000-000000000201"
            let secondVaultID = "vlt_0198f5c0-0000-7000-8000-000000000202"
            let verifiedAt = Date(timeIntervalSince1970: 1_788_282_000)
            let firstBackup = backup(vaultID: firstVaultID, fingerprint: String(repeating: "a", count: 64))

            let recorded = try VaultBackupHistoryStore(defaults: defaults).recordVerification(
                firstBackup,
                at: verifiedAt
            )
            let reloadedStore = VaultBackupHistoryStore(defaults: defaults)

            #expect(reloadedStore.entry(for: firstVaultID) == recorded)
            #expect(reloadedStore.entry(for: firstVaultID)?.verifiedAt == verifiedAt)
            #expect(reloadedStore.entry(for: secondVaultID) == nil)

            let secondBackup = backup(
                vaultID: secondVaultID,
                fingerprint: String(repeating: "b", count: 64),
                fileCount: 2,
                byteCount: 34
            )
            _ = try reloadedStore.recordVerification(secondBackup, at: verifiedAt.addingTimeInterval(60))

            #expect(reloadedStore.entry(for: firstVaultID) == recorded)
            #expect(reloadedStore.entry(for: secondVaultID)?.manifestSHA256 == secondBackup.manifestSHA256)
            #expect(reloadedStore.entry(for: secondVaultID)?.fileCount == 2)
            #expect(reloadedStore.entry(for: secondVaultID)?.byteCount == 34)
        }
    }

    @Test("preserves restoration only when verifying the same artifact")
    func preservesRestorationForSameArtifact() throws {
        try withIsolatedDefaults { defaults in
            let vaultID = "vlt_0198f5c0-0000-7000-8000-000000000203"
            let backup = backup(vaultID: vaultID, fingerprint: String(repeating: "c", count: 64))
            let restoredAt = Date(timeIntervalSince1970: 1_788_282_120)
            let verifiedAgainAt = restoredAt.addingTimeInterval(90)
            let store = VaultBackupHistoryStore(defaults: defaults)

            _ = try store.recordRestoration(backup, at: restoredAt)
            let verifiedAgain = try store.recordVerification(backup, at: verifiedAgainAt)

            #expect(verifiedAgain.verifiedAt == verifiedAgainAt)
            #expect(verifiedAgain.restoredAt == restoredAt)
            #expect(store.entry(for: vaultID) == verifiedAgain)
        }
    }

    @Test("a new copy clears restoration and artifacts never inherit another success")
    func separatesRestorationByArtifactFingerprint() throws {
        try withIsolatedDefaults { defaults in
            let vaultID = "vlt_0198f5c0-0000-7000-8000-000000000204"
            let first = backup(vaultID: vaultID, fingerprint: String(repeating: "d", count: 64))
            let second = backup(
                vaultID: vaultID,
                fingerprint: String(repeating: "e", count: 64),
                createdAt: "2026-09-04T13:00:00Z"
            )
            let store = VaultBackupHistoryStore(defaults: defaults)

            _ = try store.recordRestoration(first, at: Date(timeIntervalSince1970: 1_788_282_240))
            let newCopy = try store.recordVerification(second, at: Date(timeIntervalSince1970: 1_788_282_300))
            #expect(newCopy.manifestSHA256 == second.manifestSHA256)
            #expect(newCopy.restoredAt == nil)

            _ = try store.recordRestoration(second, at: Date(timeIntervalSince1970: 1_788_282_360))
            let firstVerifiedAgain = try store.recordVerification(
                first,
                at: Date(timeIntervalSince1970: 1_788_282_420)
            )
            #expect(firstVerifiedAgain.manifestSHA256 == first.manifestSHA256)
            #expect(firstVerifiedAgain.restoredAt == nil)
        }
    }

    @Test("returns nil for corrupt persisted JSON")
    func rejectsCorruptJSON() throws {
        try withIsolatedDefaults { defaults in
            let vaultID = "vlt_0198f5c0-0000-7000-8000-000000000205"
            defaults.set(
                Data("{not-valid-json".utf8),
                forKey: "openpep.backup.history.\(vaultID)"
            )

            #expect(VaultBackupHistoryStore(defaults: defaults).entry(for: vaultID) == nil)
        }
    }

    private func backup(
        vaultID: String,
        fingerprint: String,
        createdAt: String = "2026-09-04T12:00:00Z",
        fileCount: Int = 1,
        byteCount: Int = 17
    ) -> VaultBackupSummary {
        let files = (0..<fileCount).map { index in
            VaultBackupFile(
                path: "content/synthetic-\(index).txt",
                sizeBytes: index == 0 ? byteCount : 0,
                sha256: String(repeating: String(index % 10), count: 64)
            )
        }
        return VaultBackupSummary(
            packageURL: URL(fileURLWithPath: "/synthetic-backup-\(fingerprint.prefix(8))"),
            manifestSHA256: fingerprint,
            manifest: VaultBackupManifest(
                format: "openpep-backup",
                version: 1,
                createdAt: createdAt,
                vaultID: vaultID,
                fileCount: fileCount,
                byteCount: byteCount,
                directories: ["content"],
                files: files
            )
        )
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "openpep-backup-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
