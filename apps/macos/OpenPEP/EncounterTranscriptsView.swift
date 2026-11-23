// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import SwiftUI

struct EncounterTranscriptDocument: Identifiable, Sendable {
    let id: String
    let name: String
    let text: String
}

/// Reads only verified text assets already linked to this encounter.
struct EncounterTranscriptDocumentReader {
    func read(vaultURL: URL, patientID: String, encounterID: String) throws -> [EncounterTranscriptDocument] {
        let vault = try VaultReader().open(vaultURL)
        guard let patient = vault.patients.first(where: { $0.patientID == patientID }),
              patient.encounters.contains(where: { $0.metadata.encounterID == encounterID }) else {
            throw PatientAIIssue.changed
        }
        var documents = try patient.rawAssets.filter {
            $0.encounterID == encounterID && $0.mediaType == "text/plain"
                && $0.originalName.hasPrefix("transcricao-")
        }.sorted { $0.assetID < $1.assetID }.map { asset in
            let values = try asset.originalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 6 * 1024 * 1024 else { throw PatientAIIssue.changed }
            let data = try Data(contentsOf: asset.originalURL)
            guard data.count == asset.sizeBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256,
                  let fullText = String(data: data, encoding: .utf8) else { throw PatientAIIssue.changed }
            let text = fullText.range(of: "\n---\n\n").map { String(fullText[$0.upperBound...]) } ?? fullText
            let date = ISO8601DateFormatter().date(from: asset.importedAt)
            let name = "Transcrição · " + (date?.formatted(date: .abbreviated, time: .shortened) ?? asset.importedAt)
            return EncounterTranscriptDocument(id: asset.assetID, name: name, text: text)
        }
        let workDocuments = try ProgressiveConsultationWorkStore().documents(
            in: patient.url.appending(path: "content", directoryHint: .isDirectory),
            patientID: patientID
        )
        documents.append(contentsOf: workDocuments.filter {
            $0.encounterID == encounterID && !$0.segments.isEmpty
        }.sorted { $0.createdAt < $1.createdAt }.map { work in
            let date = work.capture.startedAt ?? work.createdAt
            return EncounterTranscriptDocument(
                id: work.sessionID,
                name: "Transcrição ao vivo · " + date.formatted(date: .abbreviated, time: .shortened),
                text: work.segments.map(\.text).joined(separator: "\n") + "\n"
            )
        })
        return documents
    }
}

struct EncounterTranscriptsView: View {
    let vaultURL: URL
    let authorizationURL: URL
    let patientID: String
    let encounterID: String
    let assets: [RawAssetSummary]
    @State private var documents: [EncounterTranscriptDocument] = []
    @State private var error: String?
    @State private var expandedID: String?
    @State private var reloadCount = 0

    private var revision: String {
        assets.map { $0.assetID + $0.sha256 }.joined(separator: ":")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !documents.isEmpty {
                Text("Transcrições da consulta").font(.headline)
                Text("Confira o reconhecimento antes de usar o texto. Sua nota permanece separada.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(documents) { document in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedID == document.id },
                        set: { expandedID = $0 ? document.id : nil }
                    )) {
                        ScrollView {
                            Text(document.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 280)
                    } label: {
                        Label(document.name, systemImage: "text.alignleft")
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Button("Tentar abrir novamente") { reloadCount += 1 }
            }
        }
        .task(id: revision + ":" + String(reloadCount)) {
            let task = Task.detached {
                // Keep the bookmark's authorization alive for the entire background read.
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                return try EncounterTranscriptDocumentReader().read(vaultURL: vaultURL,
                    patientID: patientID, encounterID: encounterID)
            }
            do {
                let result = try await task.value
                try Task.checkCancellation()
                if result.last?.id != documents.last?.id { expandedID = result.last?.id }
                documents = result
                error = nil
            } catch is CancellationError {
                task.cancel()
            } catch {
                documents = []
                self.error = "Não foi possível abrir as transcrições: " + error.localizedDescription
            }
        }
    }
}
