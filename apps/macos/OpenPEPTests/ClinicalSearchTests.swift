// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

@Suite("SEARCH-EXPORT-001 clinical search index")
struct ClinicalSearchTests {
    @Test("indexes normalized content and exposes altered encounters only through safe metadata")
    func indexesNormalizedContent() throws {
        let index = ClinicalSearchIndex(patients: [indexedPatient])

        #expect(index.count == 5)
        #expect(index.search("").map(\.target) == [
            .patient,
            .encounter(draftEncounterID),
            .encounter(finalEncounterID),
            .encounter(alteredEncounterID),
            .document(assetID),
        ])

        let draft = try #require(index.search("AGATA tensional").first)
        #expect(draft.patientName == "Ágata Sintética")
        #expect(draft.context == "Rascunho salvo")
        #expect(draft.target == .encounter(draftEncounterID))

        let archivedPatient = try #require(
            index.search("52998224725").first(where: { $0.target == .patient })
        )
        #expect(archivedPatient.context == "Cadastro arquivado")

        let document = try #require(index.search("RESSONANCIA application/pdf").first)
        #expect(document.title == "Laudo de Ressonância.pdf")
        #expect(document.target == .document(assetID))
        #expect(index.search("SCANNER clinico").first?.target == .document(assetID))

        let finalNote = try #require(index.search("CARDIOLOGICA estavel").first)
        #expect(finalNote.context == "Finalizada com adendo")
        #expect(finalNote.target == .encounter(finalEncounterID))

        let addendum = try #require(index.search("posologia AJUSTADA").first)
        #expect(addendum.target == .encounter(finalEncounterID))
        #expect(index.search("correcao dose").first?.target == .encounter(finalEncounterID))

        #expect(index.search("segredo adulterado").isEmpty)
        let altered = try #require(index.search("precisa REVISAO").first)
        #expect(altered.target == .encounter(alteredEncounterID))
        #expect(altered.context == "Alteração detectada · precisa revisão")
        #expect(index.search(alteredEncounterID).first?.target == .encounter(alteredEncounterID))
        let fractional = try #require(index.search("tensional").first)
        #expect(!fractional.title.contains("T18:00:00.250Z"))
    }

    @Test("combines typed filters with empty and normalized textual queries")
    func filters() {
        let index = ClinicalSearchIndex(patients: [indexedPatient])

        #expect(ClinicalSearchFilter.allCases.map(\.label) == [
            "Tudo", "Pacientes", "Consultas", "Rascunhos", "Finalizadas", "Documentos",
        ])
        #expect(index.search("", filter: .patients).map(\.target) == [.patient])
        #expect(index.search("", filter: .encounters).map(\.target) == [
            .encounter(draftEncounterID),
            .encounter(finalEncounterID),
            .encounter(alteredEncounterID),
        ])
        #expect(index.search("", filter: .drafts).map(\.target) == [.encounter(draftEncounterID)])
        #expect(index.search("", filter: .finalized).map(\.target) == [.encounter(finalEncounterID)])
        #expect(index.search("", filter: .documents).map(\.target) == [.document(assetID)])
        #expect(index.search("AGATA", filter: .drafts).map(\.target) == [.encounter(draftEncounterID)])
        #expect(index.search("tensional", filter: .finalized).isEmpty)
        #expect(index.search("ressonancia", filter: .documents).map(\.target) == [.document(assetID)])
    }

    @Test("rebuilds from VaultReader after an external persisted draft change")
    func rebuildsAfterExternalDraftChange() throws {
        try withTemporaryDirectory { parent in
            let vault = try createVault(in: parent)
            let patient = try PatientCreator().createRegistered(
                in: vault.url,
                identity: PatientCreationIdentity(patientID: patientID),
                input: PatientRecordInput(
                    fullName: "Paciente Sintético da Busca",
                    preferredName: "Busca",
                    birthDate: nil,
                    contacts: [],
                    identifiers: [],
                    alerts: []
                ),
                createdAt: fixedDate
            )
            _ = try ClinicalDraftCreator().create(
                in: patient,
                identity: ClinicalDraftCreationIdentity(
                    encounterID: draftEncounterID,
                    noteID: noteID,
                    syntheticActorID: authorID
                ),
                startedAt: fixedDate
            )

            var opened = try VaultReader().open(vault.url)
            let encounter = try #require(opened.patients.first?.encounters.first)
            _ = try ClinicalDraftSaver().save(
                encounter: encounter,
                patientID: patientID,
                body: "Queixa inicial sintética.",
                updatedAt: fixedDate.addingTimeInterval(60)
            )

            opened = try VaultReader().open(vault.url)
            let persistedEncounter = try #require(opened.patients.first?.encounters.first)
            let initialIndex = ClinicalSearchIndex(patients: opened.patients)
            #expect(initialIndex.search("queixa inicial").count == 1)
            #expect(initialIndex.search("mudanca externa").isEmpty)

            let previousText = try #require(String(
                data: Data(contentsOf: persistedEncounter.draft.url),
                encoding: .utf8
            ))
            let changedText = previousText.replacingOccurrences(
                of: "Queixa inicial sintética.",
                with: "Mudança externa persistida."
            )
            #expect(changedText != previousText)
            try Data(changedText.utf8).write(to: persistedEncounter.draft.url, options: [.atomic])

            let rebuilt = ClinicalSearchIndex(patients: try VaultReader().open(vault.url).patients)
            #expect(rebuilt.count == initialIndex.count)
            #expect(rebuilt.search("queixa inicial").isEmpty)
            let changed = try #require(rebuilt.search("MUDANCA externa").first)
            #expect(changed.target == .encounter(draftEncounterID))
        }
    }

    private var indexedPatient: PatientSummary {
        PatientSummary(
            patientID: patientID,
            url: placeholderURL.appending(path: patientID),
            record: PatientRecord(
                schema: "openpep/patient@1",
                patientID: patientID,
                status: .archived,
                fullName: "Ágata Sintética",
                preferredName: nil,
                birthDate: nil,
                contacts: [],
                identifiers: [PatientIdentifier(type: .cpf, value: "529.982.247-25")],
                alerts: [],
                createdAt: "2026-09-01T18:00:00Z",
                updatedAt: patientTimestamp,
                archivedAt: patientTimestamp,
                extensions: [:]
            ),
            rawAssets: [RawAssetSummary(
                assetID: assetID,
                encounterID: finalEncounterID,
                originalName: "Laudo de Ressonância.pdf",
                importedAt: assetTimestamp,
                mediaType: "application/pdf",
                fileExtension: "pdf",
                sizeBytes: 42,
                sha256: String(repeating: "a", count: 64),
                source: "scanner clínico",
                inspectionResult: "accepted",
                originalURL: placeholderURL.appending(path: "laudo.pdf")
            )],
            encounters: [draftEncounter, finalizedEncounter, alteredEncounter]
        )
    }

    private var draftEncounter: EncounterSummary {
        encounter(
            id: draftEncounterID,
            body: "Hipótese de cefaleia tensional persistida.",
            status: .draft,
            startedAt: draftTimestamp
        )
    }

    private var finalizedEncounter: EncounterSummary {
        encounter(
            id: finalEncounterID,
            body: "Conteúdo anterior do rascunho.",
            status: .verified(EncounterFinalizationSummary(
                finalNote: FinalClinicalNoteSummary(
                    metadata: FinalClinicalNoteMetadata(
                        noteID: noteID,
                        patientID: patientID,
                        encounterID: finalEncounterID,
                        authorID: authorID,
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        finalizedAt: timestamp,
                        draftSHA256: String(repeating: "b", count: 64)
                    ),
                    url: placeholderURL.appending(path: "final.md"),
                    body: "Avaliação cardiológica estável.",
                    persistedData: Data(),
                    sha256: String(repeating: "c", count: 64)
                ),
                addenda: [ClinicalAddendumSummary(
                    metadata: ClinicalAddendumMetadata(
                        addendumID: addendumID,
                        noteID: noteID,
                        patientID: patientID,
                        encounterID: finalEncounterID,
                        authorID: authorID,
                        createdAt: timestamp,
                        reason: "Correção de dose sintética",
                        finalSHA256: String(repeating: "c", count: 64)
                    ),
                    url: placeholderURL.appending(path: "addendum.md"),
                    body: "Posologia ajustada após revisão.",
                    persistedData: Data(),
                    sha256: String(repeating: "d", count: 64)
                )]
            )),
            startedAt: tiedEncounterTimestamp
        )
    }

    private var alteredEncounter: EncounterSummary {
        encounter(
            id: alteredEncounterID,
            body: "Segredo adulterado que não pode ser indexado.",
            status: .altered("Nota final divergente"),
            startedAt: tiedEncounterTimestamp
        )
    }

    private func encounter(
        id: String,
        body: String,
        status: EncounterFinalizationStatus,
        startedAt: String
    ) -> EncounterSummary {
        let encounterURL = placeholderURL.appending(path: "\(id).md")
        return EncounterSummary(
            metadata: EncounterMetadata(
                encounterID: id,
                patientID: patientID,
                appointmentID: nil,
                status: "in_progress",
                modality: "in_person",
                startedAt: startedAt,
                createdBy: authorID,
                templateID: nil,
                templateVersion: nil,
                telemedicine: nil
            ),
            url: encounterURL,
            draft: ClinicalDraftSummary(
                metadata: ClinicalDraftMetadata(
                    noteID: noteID,
                    patientID: patientID,
                    encounterID: id,
                    status: "draft",
                    noteType: "progress",
                    authorID: authorID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ),
                url: placeholderURL.appending(path: "\(id)-draft.md"),
                body: body,
                persistedData: Data()
            ),
            finalizationStatus: status
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "openpep-search-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func createVault(in parent: URL) throws -> VaultSummary {
        try VaultCreator().create(
            in: parent,
            identity: VaultCreationIdentity(
                vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f",
                deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"
            ),
            createdAt: fixedDate
        )
    }

    private var placeholderURL: URL { URL(fileURLWithPath: "/synthetic-search-fixture") }
    private var fixedDate: Date { Date(timeIntervalSince1970: 1_788_110_400) }
    private var timestamp: String { "2026-08-31T18:00:00Z" }
    private var patientTimestamp: String { "2026-09-05T18:00:00Z" }
    private var draftTimestamp: String { "2026-09-03T18:00:00.250Z" }
    private var tiedEncounterTimestamp: String { "2026-09-03T18:00:00Z" }
    private var assetTimestamp: String { "2026-09-01T18:00:00Z" }
    private var patientID: String { "pt_0198f5c2-0000-7000-8000-000000000001" }
    private var draftEncounterID: String { "enc_0198f5d1-0000-7000-8000-000000000001" }
    private var finalEncounterID: String { "enc_0198f5d1-0000-7000-8000-000000000002" }
    private var alteredEncounterID: String { "enc_0198f5d1-0000-7000-8000-000000000003" }
    private var noteID: String { "note_0198f5d3-0000-7000-8000-000000000001" }
    private var authorID: String { "usr_0198f4a0-0000-7000-8000-000000000001" }
    private var assetID: String { "asset_0198f5d7-0000-7000-8000-000000000001" }
    private var addendumID: String { "add_0198f5d5-0000-7000-8000-000000000001" }
}
