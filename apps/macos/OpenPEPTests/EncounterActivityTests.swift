// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import OpenPEP

struct EncounterActivityTests {
    @Test("keeps only one active encounter in the Solo workspace")
    func keepsSingleActiveEncounter() {
        var activity = EncounterActivity()

        #expect(activity.active == nil)
        activity.activate(patientID: "pt_synthetic_a", encounterID: "enc_synthetic_a")

        activity.activate(patientID: "pt_synthetic_b", encounterID: "enc_synthetic_b")
        #expect(activity.active == ActiveEncounterReference(
            patientID: "pt_synthetic_b",
            encounterID: "enc_synthetic_b"
        ))
        activity.finish(patientID: "pt_synthetic_a", encounterID: "enc_synthetic_a")
        #expect(activity.active?.encounterID == "enc_synthetic_b")
        activity.activate(patientID: "pt_synthetic_a", encounterID: "enc_synthetic_a")
        #expect(activity.active?.encounterID == "enc_synthetic_a")
    }

    @Test("clears activity only when the active encounter finishes")
    func clearsOnlyMatchingEncounter() {
        var activity = EncounterActivity()
        activity.activate(patientID: "pt_synthetic", encounterID: "enc_active")

        activity.finish(patientID: "pt_synthetic", encounterID: "enc_other")
        #expect(activity.active != nil)

        activity.finish(patientID: "pt_synthetic", encounterID: "enc_active")
        #expect(activity.active == nil)
    }

    @Test("presents saving, saved and failed states without relying on color")
    func resolvesSavePresentation() {
        #expect(EncounterSavePresentation.resolve(
            isSaving: true,
            hasUnsavedChanges: true,
            errorMessage: nil
        ) == .saving)
        #expect(EncounterSavePresentation.resolve(
            isSaving: false,
            hasUnsavedChanges: false,
            errorMessage: nil
        ) == .saved)
        #expect(EncounterSavePresentation.resolve(
            isSaving: false,
            hasUnsavedChanges: true,
            errorMessage: "synthetic failure"
        ) == .failed)
        #expect(EncounterSavePresentation.failed.label == "Falha ao salvar")
        #expect(!EncounterSavePresentation.failed.systemImage.isEmpty)
    }
}
