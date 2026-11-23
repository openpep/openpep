// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ClinicalSearchTarget: Equatable, Sendable {
    case patient
    case encounter(String)
    case document(String)
}

enum ClinicalSearchFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    case patients
    case encounters
    case drafts
    case finalized
    case documents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Tudo"
        case .patients: "Pacientes"
        case .encounters: "Consultas"
        case .drafts: "Rascunhos"
        case .finalized: "Finalizadas"
        case .documents: "Documentos"
        }
    }
}

struct ClinicalSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let patientID: String
    let patientName: String
    let title: String
    let context: String
    let target: ClinicalSearchTarget

    var kind: String {
        switch target {
        case .patient: "Paciente"
        case .encounter: "Consulta"
        case .document: "Documento"
        }
    }

    var systemImage: String {
        switch target {
        case .patient: "person.crop.circle"
        case .encounter: "stethoscope"
        case .document: "doc.text"
        }
    }
}

/// Disposable projection of the reader's validated summaries. It never writes a cache or query history.
struct ClinicalSearchIndex: Equatable, Sendable {
    private enum EntryKind: Equatable, Sendable {
        case patient
        case encounter(EncounterKind)
        case document

        func matches(_ filter: ClinicalSearchFilter) -> Bool {
            switch (filter, self) {
            case (.all, _), (.patients, .patient), (.encounters, .encounter(_)), (.documents, .document):
                true
            case (.drafts, .encounter(.draft)), (.finalized, .encounter(.finalized)):
                true
            default:
                false
            }
        }
    }

    private enum EncounterKind: Equatable, Sendable {
        case draft
        case finalized
        case altered
    }

    private struct Entry: Equatable, Sendable {
        let result: ClinicalSearchResult
        let text: String
        let date: Date
        let kind: EntryKind
        let supplementary: Bool
    }

    private var entries: [Entry] = []
    var count: Int { entries.count }

    init(patients: [PatientSummary] = []) {
        for patient in patients.sorted(by: { $0.patientID < $1.patientID }) {
            let identity = [patient.patientID, patient.displayName,
                            patient.record?.fullName ?? "", patient.record?.preferredName ?? ""]
                + (patient.record?.identifiers ?? []).flatMap { [$0.value, PatientInputText.asciiDigits($0.value)] }
            let patientTimestamp = patient.record?.updatedAt ?? patient.record?.createdAt ?? ""
            append(patient: patient, title: patient.displayName,
                   context: patient.isArchived ? "Cadastro arquivado" : "Cadastro do paciente",
                   target: .patient, key: "patient", text: identity,
                   timestamp: patientTimestamp, kind: .patient)
            for encounter in patient.encounters.sorted(by: { $0.metadata.startedAt > $1.metadata.startedAt }) {
                let body: String
                let status: String
                let kind: EncounterKind
                switch encounter.finalizationStatus {
                case .draft:
                    body = encounter.draft.body
                    status = "Rascunho salvo"
                    kind = .draft
                case let .verified(finalization):
                    body = ([finalization.finalNote.body] + finalization.addenda.flatMap {
                        [$0.metadata.reason, $0.body]
                    }).joined(separator: "\n")
                    status = finalization.addenda.isEmpty ? "Finalizada" : "Finalizada com adendo"
                    kind = .finalized
                case .altered:
                    body = ""
                    status = "Alteração detectada · precisa revisão"
                    kind = .altered
                }
                let date = Self.displayDate(encounter.metadata.startedAt)
                append(patient: patient, title: "Consulta de \(date)", context: status,
                       target: .encounter(encounter.metadata.encounterID),
                       key: encounter.metadata.encounterID,
                       text: identity + [body, encounter.metadata.encounterID, encounter.metadata.patientID,
                                         encounter.metadata.startedAt, date, status],
                       timestamp: encounter.metadata.startedAt, kind: .encounter(kind))
            }
            let pairs = PatientHistoryReader.verifiedDocumentPairs(in: patient)
            let sourceIDs = Set(pairs.values.map { $0.0.assetID })
            for asset in patient.rawAssets.sorted(by: { $0.assetID < $1.assetID }) {
                let date = Self.displayDate(asset.importedAt)
                let document = pairs[asset.assetID]?.1
                let technical = asset.mediaType == "text/plain"
                    && asset.originalName.hasPrefix("openpep-progressive-summary-source-")
                    && ((try? PatientHistoryReader.documentText(asset))?.hasPrefix("Fonte de resumo progressivo aceita") == true)
                let type = asset.mediaType == "application/pdf" ? "PDF" : (asset.mediaType == "text/plain" ? "Texto" : "Arquivo")
                append(patient: patient, title: document?.header.title ?? (technical ? "Fonte do resumo progressivo" : asset.originalName),
                       context: "\(type) · \(date)",
                       target: .document(asset.assetID), key: asset.assetID,
                       text: identity + [asset.originalName, asset.assetID, asset.source, asset.mediaType, date,
                                         document?.header.title ?? "", pairs[asset.assetID]?.0.originalName ?? ""],
                       timestamp: asset.importedAt, kind: .document,
                       supplementary: technical || sourceIDs.contains(asset.assetID))
            }
        }
        entries.sort(by: Self.precedes)
    }

    func search(
        _ query: String,
        filter: ClinicalSearchFilter = .all,
        includesSupplementaryFiles: Bool = false
    ) -> [ClinicalSearchResult] {
        let terms = PatientSearch.normalize(query).split(separator: " ").map(String.init)
        return entries.filter { entry in
            entry.kind.matches(filter)
                && (includesSupplementaryFiles || !entry.supplementary)
                && terms.allSatisfy { entry.text.contains($0) }
        }.map(\.result)
    }

    private mutating func append(
        patient: PatientSummary, title: String, context: String,
        target: ClinicalSearchTarget, key: String, text: [String],
        timestamp: String, kind: EntryKind, supplementary: Bool = false
    ) {
        entries.append(Entry(
            result: ClinicalSearchResult(id: "\(patient.patientID):\(key)", patientID: patient.patientID,
                                         patientName: patient.displayName, title: title, context: context, target: target),
            text: PatientSearch.normalize(text.joined(separator: " ")),
            date: Self.parseDate(timestamp) ?? .distantPast,
            kind: kind, supplementary: supplementary
        ))
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.date == rhs.date ? lhs.result.id < rhs.result.id : lhs.date > rhs.date
    }

    private static func displayDate(_ value: String) -> String {
        guard let date = parseDate(value) else { return value }
        return date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "pt_BR")))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
