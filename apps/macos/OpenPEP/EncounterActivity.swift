// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct ActiveEncounterReference: Equatable, Sendable {
    let patientID: String
    let encounterID: String
}

struct EncounterActivity: Equatable, Sendable {
    private(set) var active: ActiveEncounterReference?

    mutating func activate(patientID: String, encounterID: String) {
        active = ActiveEncounterReference(patientID: patientID, encounterID: encounterID)
    }

    mutating func finish(patientID: String, encounterID: String) {
        guard active == ActiveEncounterReference(patientID: patientID, encounterID: encounterID) else {
            return
        }
        active = nil
    }

    mutating func clear() {
        active = nil
    }
}

enum EncounterSavePresentation: Equatable, Sendable {
    case saving
    case saved
    case failed

    static func resolve(isSaving: Bool, hasUnsavedChanges: Bool, errorMessage: String?) -> Self {
        if isSaving { return .saving }
        if errorMessage != nil { return .failed }
        if hasUnsavedChanges { return .saving }
        return .saved
    }

    var label: String {
        switch self {
        case .saving: "Salvando"
        case .saved: "Salvo"
        case .failed: "Falha ao salvar"
        }
    }

    var systemImage: String {
        switch self {
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
