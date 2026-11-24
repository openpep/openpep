// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// PDFs handed to Mail, printing or sharing are copied to per-delivery folders in the temporary
/// directory. Sharing may finish after the sheet closes, so those folders are removed when the app
/// starts and when it quits, never while a delivery can still be reading them.
enum TemporaryClinicalFiles {
    static let prefixes = ["OpenPEP-Delivery-", "OpenPEP-Resend-"]

    @discardableResult
    static func sweep(in root: URL = FileManager.default.temporaryDirectory,
                      fileManager: FileManager = .default) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return 0 }
        var removed = 0
        for entry in entries where prefixes.contains(where: entry.lastPathComponent.hasPrefix) {
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
