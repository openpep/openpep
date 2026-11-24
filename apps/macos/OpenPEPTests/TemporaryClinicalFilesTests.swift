// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct TemporaryClinicalFilesTests {
    @Test func sweepRemovesOnlyDeliveryAndResendFolders() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "OpenPEP-Sweep-Test-" + UUID().uuidString)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        for name in ["OpenPEP-Delivery-A", "OpenPEP-Resend-B"] {
            let folder = root.appending(path: name)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("%PDF-sintetico".utf8).write(to: folder.appending(path: "Receita.pdf"))
        }
        let kept = root.appending(path: "Outro-App-C")
        try fileManager.createDirectory(at: kept, withIntermediateDirectories: false)

        #expect(TemporaryClinicalFiles.sweep(in: root) == 2)
        #expect(try fileManager.contentsOfDirectory(atPath: root.path) == ["Outro-App-C"])
        #expect(TemporaryClinicalFiles.sweep(in: root) == 0)
    }
}
