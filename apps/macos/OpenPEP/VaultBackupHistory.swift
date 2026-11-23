// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct VaultBackupHistoryEntry: Codable, Equatable, Sendable {
    let manifestSHA256: String
    let createdAt: String
    let verifiedAt: Date
    let fileCount: Int
    let byteCount: Int
    var restoredAt: Date?
}

/// A local historical receipt, not a claim that the destination is still available.
struct VaultBackupHistoryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func entry(for vaultID: String) -> VaultBackupHistoryEntry? {
        guard let data = defaults.data(forKey: key(vaultID)) else { return nil }
        return try? JSONDecoder().decode(VaultBackupHistoryEntry.self, from: data)
    }

    @discardableResult
    func recordVerification(_ backup: VaultBackupSummary, at date: Date = Date()) throws -> VaultBackupHistoryEntry {
        let previous = entry(for: backup.manifest.vaultID)
        let value = VaultBackupHistoryEntry(
            manifestSHA256: backup.manifestSHA256,
            createdAt: backup.manifest.createdAt,
            verifiedAt: date,
            fileCount: backup.manifest.fileCount,
            byteCount: backup.manifest.byteCount,
            restoredAt: previous?.manifestSHA256 == backup.manifestSHA256 ? previous?.restoredAt : nil
        )
        try save(value, vaultID: backup.manifest.vaultID)
        return value
    }

    @discardableResult
    func recordRestoration(_ backup: VaultBackupSummary, at date: Date = Date()) throws -> VaultBackupHistoryEntry {
        var value = try recordVerification(backup, at: date)
        value.restoredAt = date
        try save(value, vaultID: backup.manifest.vaultID)
        return value
    }

    private func save(_ entry: VaultBackupHistoryEntry, vaultID: String) throws {
        defaults.set(try JSONEncoder().encode(entry), forKey: key(vaultID))
    }

    private func key(_ vaultID: String) -> String { "openpep.backup.history.\(vaultID)" }
}
