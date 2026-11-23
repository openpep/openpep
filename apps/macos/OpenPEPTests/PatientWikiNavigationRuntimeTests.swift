// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import OpenPEP

struct PatientWikiNavigationRuntimeTests {
    private let patientID = "pt_0198f5c2-0000-7000-8000-000000000001"
    private let encounterID = "enc_0198f5c3-0000-7000-8000-000000000001"

    @Test("wiki context follows the selected patient across navigation surfaces")
    func resolvesSelectedPatient() {
        #expect(ContentView.wikiPatientID(
            for: .patient(patientID), selectedPatientID: nil, expandedPatientID: nil) == patientID)
        #expect(ContentView.wikiPatientID(
            for: .encounter(patientID: patientID, encounterID: encounterID),
            selectedPatientID: patientID, expandedPatientID: nil) == patientID)
        #expect(ContentView.wikiPatientID(
            for: .patients, selectedPatientID: nil, expandedPatientID: patientID) == patientID)
        #expect(ContentView.wikiPatientID(
            for: .patients, selectedPatientID: nil, expandedPatientID: nil) == nil)
        #expect(ContentView.wikiPatientID(
            for: .search, selectedPatientID: patientID, expandedPatientID: patientID) == nil)
        #expect(ContentView.wikiPatientID(
            for: .home, selectedPatientID: patientID, expandedPatientID: patientID) == nil)
    }
}
