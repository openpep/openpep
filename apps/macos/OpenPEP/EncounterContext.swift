// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct EncounterContextExam: Equatable, Sendable {
    let assetID: String
    let kind: String
    let originalName: String
    let importedAt: String
}

struct EncounterContextConsultation: Equatable, Sendable {
    let date: String
}

struct EncounterContext: Equatable, Sendable {
    let patientID: String
    let activeProblems: [String]
    let exams: [EncounterContextExam]
    let previousConsultation: EncounterContextConsultation?
}

enum EncounterContextBuilder {
    static func build(
        patient: PatientSummary,
        profile: DemoPatientProfile,
        encounterID: String
    ) throws -> EncounterContext {
        guard patient.patientID == profile.patientID else {
            throw contextIssue(
                "encounter_context.patient_binding",
                encounterID,
                "O contexto demonstrativo pertence a outro paciente."
            )
        }
        guard patient.encounters.contains(where: { $0.metadata.encounterID == encounterID }),
              let selectedConsultation = profile.consultations.first(where: {
                  $0.encounterID == encounterID
              }) else {
            throw contextIssue(
                "encounter_context.encounter_binding",
                encounterID,
                "O atendimento não pertence ao contexto demonstrativo selecionado."
            )
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: patient.rawAssets.map { ($0.assetID, $0) })
        let exams = try profile.rawAssets.compactMap { candidate -> EncounterContextExam? in
            guard candidate.kind == "laboratory" || candidate.kind == "imaging" else {
                return nil
            }
            guard let asset = assetsByID[candidate.assetID],
                  asset.originalName == candidate.originalName,
                  asset.importedAt == candidate.importedAt,
                  asset.mediaType == "application/pdf",
                  asset.originalURL.pathExtension.lowercased() == "pdf" else {
                throw contextIssue(
                    "encounter_context.asset_binding",
                    candidate.assetID,
                    "Um exame do contexto não corresponde ao original validado."
                )
            }
            return EncounterContextExam(
                assetID: candidate.assetID,
                kind: candidate.kind,
                originalName: candidate.originalName,
                importedAt: candidate.importedAt
            )
        }
        .sorted {
            if $0.importedAt == $1.importedAt {
                return $0.assetID < $1.assetID
            }
            return $0.importedAt > $1.importedAt
        }

        let previous = profile.consultations
            .filter { $0.encounterID != encounterID && $0.date < selectedConsultation.date }
            .sorted {
                if $0.date == $1.date {
                    return $0.encounterID > $1.encounterID
                }
                return $0.date > $1.date
            }
            .first
            .map {
                EncounterContextConsultation(date: $0.date)
            }

        return EncounterContext(
            patientID: patient.patientID,
            activeProblems: profile.activeProblems,
            exams: exams,
            previousConsultation: previous
        )
    }
}

enum OptionalClinicalDraftTemplate {
    static let text = """
    ## Motivo do atendimento

    ## História clínica

    ## Exame

    ## Avaliação

    ## Plano
    """

    static func inserting(into current: String) -> String {
        guard !current.contains(text) else { return current }
        guard !current.isEmpty else { return "\(text)\n" }
        let separator = current.hasSuffix("\n") ? "\n" : "\n\n"
        return "\(current)\(separator)\(text)\n"
    }
}

private func contextIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
