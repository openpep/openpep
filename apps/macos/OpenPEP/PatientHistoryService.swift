// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import FoundationModels
import PDFKit

struct PatientHistoryEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let timestamp: String
    let status: String
    let text: String
    let source: String
    let assetID: String?
    let issue: String?
    var mediaType: String? = nil
    var date: Date? { ISO8601DateFormatter().date(from: timestamp) }
    var isDocument: Bool { assetID != nil }
    var isDraft: Bool { !isDocument && status == "Rascunho salvo" }
    var displayDate: String {
        date?.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "pt_BR"))) ?? timestamp
    }
    func matches(_ query: String) -> Bool {
        let terms = PatientSearch.normalize(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = PatientSearch.normalize([title, text, displayDate, timestamp, status].joined(separator: " "))
        return terms.allSatisfy { haystack.contains($0) }
    }
}

struct PatientHistorySnapshot: Sendable {
    let patientName: String
    let entries: [PatientHistoryEntry]
}

struct PatientHistoryReader: Sendable {
    static let maximumTextCharacters = 100_000

    func load(patientID: String, vaultURL: URL, authorizationURL: URL, includeDrafts: Bool = true) throws -> PatientHistorySnapshot {
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let vault = try VaultReader().open(vaultURL)
        guard let patient = vault.patients.first(where: { $0.patientID == patientID }) else {
            throw VaultValidationIssue(rule: "history.patient_unavailable", path: patientID,
                                       message: "O paciente não está disponível após reler e verificar o prontuário.")
        }
        var entries: [PatientHistoryEntry] = []
        for encounter in patient.encounters {
            try Task.checkCancellation()
            let id = encounter.metadata.encounterID
            switch encounter.finalizationStatus {
            case .draft:
                guard includeDrafts else { continue }
                entries.append(entry(id: id, title: "Consulta", timestamp: encounter.metadata.startedAt,
                    status: "Rascunho salvo", text: encounter.draft.body,
                    source: "content/notes/drafts/" + encounter.draft.url.lastPathComponent))
            case let .verified(finalization):
                entries.append(entry(id: id, title: "Consulta", timestamp: encounter.metadata.startedAt,
                    status: "Finalizada", text: finalization.finalNote.body,
                    source: "content/notes/final/" + finalization.finalNote.url.lastPathComponent))
                for addendum in finalization.addenda {
                    entries.append(entry(id: addendum.metadata.addendumID, title: "Adendo à consulta de \(encounter.metadata.startedAt.prefix(10))",
                        timestamp: addendum.metadata.createdAt, status: "Adendo verificado",
                        text: "Motivo: \(addendum.metadata.reason)\n\n\(addendum.body)",
                        source: "content/notes/addenda/" + addendum.url.lastPathComponent))
                }
            case .altered:
                entries.append(PatientHistoryEntry(id: id, title: "Consulta indisponível", timestamp: encounter.metadata.startedAt,
                    status: "Alteração detectada", text: "", source: id, assetID: nil,
                    issue: "Abra a consulta para revisar a alteração. Conteúdo excluído da busca e da IA."))
            }
        }
        let sourcesByPDF = Self.verifiedDocumentPairs(in: patient)
        let pairedSourceIDs = Set(sourcesByPDF.values.map { $0.0.assetID })
        for asset in patient.rawAssets {
            if pairedSourceIDs.contains(asset.assetID) { continue }
            if let (source, document) = sourcesByPDF[asset.assetID] {
                entries.append(entry(id: asset.assetID, title: document.header.title, timestamp: document.header.created_at,
                    status: document.header.encounter_id == nil ? "Documento avulso" : "Documento da consulta",
                    text: document.body, source: source.originalURL.path.replacingOccurrences(of: patient.url.path + "/", with: ""),
                    assetID: asset.assetID, mediaType: asset.mediaType))
                continue
            }
            try Task.checkCancellation()
            do {
                let extracted = try Self.documentText(asset)
                entries.append(entry(id: asset.assetID, title: asset.originalName, timestamp: asset.importedAt,
                    status: "Documento guardado · data de importação", text: extracted,
                    source: asset.originalURL.path.replacingOccurrences(of: patient.url.path + "/", with: ""),
                    assetID: asset.assetID,
                    issue: extracted.isEmpty ? "Sem texto extraível. Abra o original; este documento não entra no resumo. OCR ainda não disponível." : nil, mediaType: asset.mediaType))
            } catch {
                entries.append(PatientHistoryEntry(id: asset.assetID, title: asset.originalName,
                    timestamp: asset.importedAt, status: "Documento guardado", text: "", source: asset.assetID,
                    assetID: asset.assetID, issue: "Texto indisponível: \(error.localizedDescription)", mediaType: asset.mediaType))
            }
        }
        return PatientHistorySnapshot(patientName: patient.displayName, entries: entries.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
        })
    }

    private func entry(id: String, title: String, timestamp: String, status: String, text: String, source: String,
                       assetID: String? = nil, issue: String? = nil, mediaType: String? = nil) -> PatientHistoryEntry {
        let tooLong = text.count > Self.maximumTextCharacters
        return PatientHistoryEntry(id: id, title: title, timestamp: timestamp, status: status,
            text: tooLong ? String(text.prefix(Self.maximumTextCharacters)) : text,
            source: source, assetID: assetID,
            issue: tooLong ? "Texto excede o limite de leitura rápida; trecho exibido, excluído da IA. Abra o original completo." : issue, mediaType: mediaType)
    }

    static func verifiedDocumentPairs(in patient: PatientSummary) -> [String: (RawAssetSummary, IndependentClinicalDocument)] {
        // Pair only verified sources with their exact PDF, avoiding duplicate history/AI entries.
        var sourcesByPDF: [String: (RawAssetSummary, IndependentClinicalDocument)] = [:]
        for asset in patient.rawAssets where asset.mediaType == "text/plain" {
            guard let text = try? Self.documentText(asset),
                  let document = try? IndependentClinicalDocument.read(text),
                  document.header.patient_id == patient.patientID,
                  document.header.encounter_id == asset.encounterID,
                  let pdf = patient.rawAssets.first(where: { $0.assetID == document.header.pdf_asset_id }),
                  pdf.mediaType == "application/pdf", pdf.encounterID == asset.encounterID,
                  pdf.sha256 == document.header.pdf_sha256,
                  (try? Self.verifiedData(pdf)) != nil else { continue }
            sourcesByPDF[pdf.assetID] = (asset, document)
        }
        return sourcesByPDF
    }

    static func verifiedData(_ asset: RawAssetSummary) throws -> Data {
        let values = try asset.originalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == asset.sizeBytes, asset.sizeBytes <= DocumentImportDescriptor.maximumBytes else {
            throw ConsultationFieldsError.tooLarge
        }
        let data = try Data(contentsOf: asset.originalURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            throw VaultValidationIssue(rule: "history.asset_changed", path: asset.assetID,
                                       message: "O arquivo mudou depois da verificação. Atualize o histórico.")
        }
        return data
    }

    static func documentText(_ asset: RawAssetSummary) throws -> String {
        let data = try verifiedData(asset)
        if asset.mediaType == "text/plain" {
            guard let text = String(data: data, encoding: .utf8) else { throw ConsultationFieldsError.ambiguous }
            return text
        }
        guard asset.mediaType == "application/pdf" else { return "" }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount <= 200 else {
            throw ConsultationFieldsError.tooLarge
        }
        var pages: [String] = []
        var count = 0
        for index in 0..<pdf.pageCount {
            let text = pdf.page(at: index)?.string ?? ""
            count += text.count
            guard count <= maximumTextCharacters else { throw ConsultationFieldsError.tooLarge }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Separate prompt from transcription insertion; history answers are ephemeral and never finalize a note.
actor ApplePatientHistoryEngine: ConsultationSummaryEngine {
    let question: String
    private let model = SystemLanguageModel.default
    init(question: String) { self.question = question }
    private let instructions = AIPromptCatalog.patientHistoryApple.instructions
    func availability(for locale: Locale) -> ConsultationSummaryAvailability {
        switch model.availability {
        case .available: return model.supportsLocale(locale) ? .ready : .localeUnsupported(locale.identifier)
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable: return .modelNotReady
        }
    }
    private func prompt(_ source: String, _ label: String) -> String {
        "Pergunta de localização (vazia significa resumo):\n<pergunta>\(question)</pergunta>\n"
        + "Resuma como proposta para revisão; identifique cada item com [\(label)].\n<fonte>\(source)</fonte>"
    }
    func accepts(_ source: String, sourceLabel: String, locale: Locale) async throws -> Bool {
        let input = prompt(source, sourceLabel)
        if #available(macOS 26.4, *) {
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let inputTokens = try await model.tokenCount(for: Prompt(input))
            return instructionTokens + inputTokens + 800 <= model.contextSize
        }
        return input.utf8.count <= 2_800
    }
    func summarize(_ source: String, sourceLabel: String, locale: Locale) async throws -> String {
        guard availability(for: locale) == .ready else { throw ConsultationSummaryIssue.modelNotReady }
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt(source, sourceLabel),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 640)).content
    }
}
