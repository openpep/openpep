// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct DoctorDocumentFavorite: Identifiable, Sendable {
    let url: URL
    let title: String
    let markdown: String
    let sha256: String
    var id: String { url.lastPathComponent }
}

/// User-selected Markdown folder, separate from patient vaults. The current solo Mac library is not a multi-user authentication boundary.
struct DoctorDocumentLibrary {
    static func read(_ directory: URL) throws -> [DoctorDocumentFavorite] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ConsultationFieldsError.ambiguous }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        return try urls.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 300_000 else { throw ConsultationFieldsError.tooLarge }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw ConsultationFieldsError.ambiguous }
            var markdown = text
            if text.contains(ConsultationFields.start) || text.contains(ConsultationFields.end) {
                let parsed = try ConsultationFields.read(from: text)
                guard !parsed.items.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines) == parsed.markdown else {
                    throw ConsultationFieldsError.ambiguous
                }
                markdown = parsed.markdown
            }
            return DoctorDocumentFavorite(url: url, title: url.deletingPathExtension().lastPathComponent,
                markdown: markdown, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }
}
