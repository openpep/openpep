// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import OpenPEP

@MainActor
struct PatientDropTests {
    @Test func decodesFinderFileProvider() async throws {
        let url = URL(fileURLWithPath: "/tmp/Exame sintético.pdf")
        let provider = NSItemProvider(object: url as NSURL)
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                continuation.resume(returning: data)
            }
        }
        #expect(PatientFileDropModifier.fileURL(from: try #require(data)) == url)
        #expect(PatientFileDropModifier.fileURL(from: URL(string: "https://example.invalid/document.pdf")!.dataRepresentation) == nil)
    }
}
