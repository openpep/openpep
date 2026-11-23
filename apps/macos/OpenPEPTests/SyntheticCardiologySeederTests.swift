// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import PDFKit
import Testing

@testable import OpenPEP

@Suite("Synthetic cardiology cohort")
struct SyntheticCardiologySeederTests {
  @Test("seeds a rich cardiology cohort and preserves it through backup")
  func seedsRichCardiologyCohort() throws {
    try withOutputDirectory { parent, shouldPreserve in
      let referenceDate = shouldPreserve ? Date() : Date(timeIntervalSince1970: 1_788_195_600)
      let seeded = try SyntheticReleaseSeeder(cardiology: true).seed(in: parent, at: referenceDate)

      #expect(seeded.patients.count == 10)
      #expect(seeded.appointments.count == 30)
      #expect(seeded.unavailablePatients.isEmpty)
      #expect(seeded.unavailableAppointments.isEmpty)
      #expect(seeded.writingAllowed)
      #expect(Set(seeded.appointments.map(\.record.modality)) == Set(AppointmentModality.allCases))
      #expect(Set(seeded.appointments.map(\.record.status)) == Set(AppointmentStatus.allCases))
      #expect(
        Set(seeded.patients.map(\.displayName)) ==
          Set(SyntheticCardiologyScenarios.patients.map(\.name))
      )
      #expect(seeded.patients.flatMap(\.encounters).allSatisfy { encounter in
        if case .verified = encounter.finalizationStatus { return true }
        return false
      })

      let orderedPatients = seeded.patients.sorted { $0.displayName < $1.displayName }
      let orderedScenarios = SyntheticCardiologyScenarios.patients.sorted { $0.name < $1.name }
      for (patient, scenario) in zip(orderedPatients, orderedScenarios) {
        let documentSpecs = SyntheticCardiologyScenarios.documents[
          SyntheticCardiologyScenarios.patients.firstIndex { $0.name == scenario.name }!
        ]
        #expect(patient.encounters.count == scenario.encounters.count)
        #expect(patient.rawAssets.count == documentSpecs.count)
        #expect(patient.rawAssets.filter { $0.originalURL.pathExtension.lowercased() == "pdf" }.count ==
                documentSpecs.filter(\.isPDF).count)

        if SyntheticCardiologyScenarios.patients.firstIndex(where: { $0.name == scenario.name })! < 4 {
          #expect(patient.encounters.count > 5)
          #expect(patient.rawAssets.count > 10)
        }

        for document in documentSpecs where document.isPDF {
          let asset = try #require(patient.rawAssets.first {
            $0.originalName.localizedCaseInsensitiveContains(document.title)
              && $0.originalURL.pathExtension.lowercased() == "pdf"
          })
          let pdf = try #require(PDFDocument(url: asset.originalURL))
          #expect(pdf.pageCount > 0)
          #expect(!(pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        let wiki = try PatientWikiStore().load(for: patient)
        let summary = try #require(wiki.summary)
        #expect(wiki.summaryIssue == nil)
        let overview = try #require(summary.overview)
        #expect(overview == SyntheticCardiologyScenarios.overviews[
          SyntheticCardiologyScenarios.patients.firstIndex { $0.name == scenario.name }!
        ])
        #expect(overview.count <= 500)
        #expect(summary.exclusions != nil)
        #expect(summary.markdown.contains("[F1]"))
        #expect(summary.sources.count >= patient.encounters.count)
        let chronological = patient.encounters.sorted { $0.metadata.startedAt < $1.metadata.startedAt }
        #expect(summary.sources.prefix(chronological.count).map(\.id) == chronological.map(\.metadata.encounterID))
        #expect(summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines) == scenario.wiki.trimmingCharacters(in: .whitespacesAndNewlines))
        let history = try PatientHistoryReader().load(
          patientID: patient.patientID,
          vaultURL: seeded.url,
          authorizationURL: seeded.url
        )
        let context = try PatientWikiContext.make(patient: patient, entries: history.entries, corrections: "")
        #expect(summary.sourceFingerprint == context.fingerprint)
        let entryHashes = Dictionary(uniqueKeysWithValues: context.entries.map {
          ($0.id, PatientAIContext.digest(Data($0.text.utf8)))
        })
        #expect(summary.sources.allSatisfy { entryHashes[$0.id] == $0.sha256 })
      }

      let backupURL = parent.appending(path: "cardiology-backup")
      let backup = try VaultBackupService().create(from: seeded.url, to: backupURL)
      _ = try VaultBackupService().verify(at: backupURL)
      let restoredURL = parent.appending(path: "cardiology-restored")
      _ = try VaultBackupService().restore(
        from: backup.packageURL,
        to: restoredURL,
        expectedManifestSHA256: backup.manifestSHA256
      )
      let restored = try VaultReader().open(restoredURL)
      for patient in restored.patients {
        let wiki = try PatientWikiStore().load(for: patient)
        #expect(wiki.summaryIssue == nil)
        let original = try #require(seeded.patients.first { $0.patientID == patient.patientID })
        let originalWiki = try PatientWikiStore().load(for: original)
        #expect(wiki.summary?.overview == originalWiki.summary?.overview)
      }
      #expect(restored.patients.count == 10)
      #expect(restored.appointments.count == 30)
      #expect(restored.patients.flatMap(\.encounters).count == seeded.patients.flatMap(\.encounters).count)
      #expect(restored.patients.flatMap(\.rawAssets).count == seeded.patients.flatMap(\.rawAssets).count)
      #expect(ClinicalSearchIndex(patients: restored.patients) == ClinicalSearchIndex(patients: seeded.patients))

      if shouldPreserve {
        #expect(FileManager.default.fileExists(atPath: seeded.url.path))
        print("CARDIOLOGY_VAULT=\(seeded.url.path)")
        print("CARDIOLOGY_COUNTS patients=\(seeded.patients.count) encounters=\(seeded.patients.flatMap(\.encounters).count) documents=\(seeded.patients.flatMap(\.rawAssets).count)")
      }
    }
  }

  private func withOutputDirectory(
    _ body: (URL, Bool) throws -> Void
  ) throws {
    let fileManager = FileManager.default
    if let output = ProcessInfo.processInfo.environment["OPENPEP_CARDIOLOGY_OUTPUT"], !output.isEmpty {
      let parent = URL(fileURLWithPath: output, isDirectory: true)
        .appending(path: "ensaio-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
      try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
      try body(parent, true)
      return
    }

    let parent = fileManager.temporaryDirectory.appending(
      path: "openpep-cardiology-synthetic-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: parent) }
    try body(parent, false)
  }
}
