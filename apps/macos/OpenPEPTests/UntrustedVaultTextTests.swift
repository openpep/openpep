// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct UntrustedVaultTextTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let assetID = "asset_0198f5d4-0000-7000-8000-000000000001"

    private func header(title: String) -> IndependentClinicalDocument.Header {
        .init(document_format: "openpep-document-snapshot-v1", document_id: UUID().uuidString.lowercased(),
              patient_id: patientID, encounter_id: nil, title: title, created_at: "2026-01-05T12:00:00Z",
              pdf_asset_id: assetID, pdf_sha256: String(repeating: "a", count: 64))
    }

    @Test func identifiersRejectATrailingNewline() {
        #expect(OpenPEPIdentifier.isPatient(patientID))
        #expect(!OpenPEPIdentifier.isPatient(patientID + "\n"))
        #expect(!OpenPEPIdentifier.isAsset(assetID + "\n"))
    }

    @Test func documentSnapshotRoundTripsPlainTitlesWithAmpersand() throws {
        let document = IndependentClinicalDocument(header: header(title: "Exames & laudos"), body: "Texto sintético.")
        let reread = try IndependentClinicalDocument.read(try document.text)
        #expect(reread.header.title == "Exames & laudos")
        #expect(reread.body == "Texto sintético.")
    }

    @Test func documentSnapshotRefusesAnchorsAliasesTagsAndOversizedHeaders() throws {
        let valid = try IndependentClinicalDocument(header: header(title: "Receita"), body: "Corpo").text
        for injected in ["title: &a Receita", "title: *a", "title: !!binary AAAA", "title: [a, b]",
                         "title:\n  &a Receita", "\"title\": &a Receita", "'title': *a"] {
            let text = valid.replacingOccurrences(of: "title: Receita", with: injected)
            #expect(text != valid)
            #expect(throws: (any Error).self) { try IndependentClinicalDocument.read(text) }
        }
        let padding = "title: Receita\nx_padding: '" + String(repeating: "x", count: 17 * 1024) + "'"
        #expect(throws: (any Error).self) {
            try IndependentClinicalDocument.read(valid.replacingOccurrences(of: "title: Receita", with: padding))
        }
    }
}
