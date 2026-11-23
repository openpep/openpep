// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import PDFKit
import Testing

@testable import OpenPEP

@Suite("RELEASE-SOLO-001 synthetic integrated rehearsal")
struct SyntheticReleaseSeederTests {
  @MainActor @Test("demo registration renders a controlled prescription without manual patient corrections")
  func demoPatientCanPreviewPrescription() async throws {
    let parent = FileManager.default.temporaryDirectory.appending(path: "openpep-demo-prescription-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let vault = try SyntheticReleaseSeeder().seed(in: parent, at: Date(timeIntervalSince1970: 1_788_195_600))
    let patient = try #require(vault.patients.first)
    var draft = CockpitPrescription(patient: patient)
    draft.tipo = "NRB"
    draft.prescriber = .init(nome: "Médico Sintético", crm: "000001", uf: "SP", cpf: "52998224725")
    draft.emitente = .init(endereco: "Rua Sintética, 200", cidade: "São Paulo", uf: "SP")
    draft.medications = [.init(nome: "Medicamento de ensaio", concentracao: "10 mg", forma: "comprimido",
      quantidade: "30", unidade: "comprimidos", posologia: "Ensaio de interface, sem orientação clínica.")]
    let rendered = try await CockpitPDFRenderer().render(draft.input())
    let pdf = try #require(PDFDocument(data: rendered.pdf))
    #expect(pdf.pageCount == 1)
    #expect(pdf.string?.contains(patient.displayName) == true)
    #expect(pdf.string?.contains("ENSAIO SINTÉTICO") == true)
  }

  @Test("seeds, backs up and restores the searchable synthetic cohort")
  func roundTripsSyntheticReleaseVault() throws {
    try withTemporaryDirectory { parent in
      let referenceDate = Date(timeIntervalSince1970: 1_788_195_600)
      let seeded = try SyntheticReleaseSeeder().seed(in: parent, at: referenceDate)
      let audioFolder = try ConsultationCaptureSettings.recordingFolder(in: seeded.url)
      let audio = Data("synthetic recording fixture".utf8)
      try audio.write(to: audioFolder.appendingPathComponent("demo.wav"))
      #expect(try VaultReader().open(seeded.url).writingAllowed)

      #expect(
        seeded.url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
      #expect(seeded.patients.count == 10)
      let cpfs = seeded.patients.compactMap { $0.record?.identifiers.first(where: { $0.type == .cpf })?.value }
      #expect(cpfs.count == 10 && Set(cpfs).count == 10)
      #expect(cpfs.allSatisfy(PatientCPF.isStructurallyValid))
      for patient in seeded.patients {
        let prescription = CockpitPrescription(patient: patient)
        #expect(!prescription.paciente.documento.isEmpty)
        #expect(prescription.paciente.endereco.contains("Endereço fictício"))
        #expect(prescription.paciente.cidade == "São Paulo" && prescription.paciente.uf == "SP")
      }

      #expect(seeded.appointments.count == 30)
      #expect(seeded.unavailablePatients.isEmpty)
      #expect(seeded.unavailableAppointments.isEmpty)
      #expect(seeded.writingAllowed)
      #expect(Set(seeded.patients.map(\.displayName)) == Set(SyntheticPatientScenarios.patients.map(\.name)))
      #expect(seeded.patients.allSatisfy { !$0.displayName.localizedCaseInsensitiveContains("sintética") })
      let contacts = seeded.patients.flatMap { $0.record?.contacts ?? [] }
      let emailContacts = contacts.filter { $0.type == .email }
      #expect(emailContacts.count == 10)
      #expect(emailContacts.allSatisfy { $0.value.hasSuffix("@example.invalid") })
      let phoneContacts = contacts.filter { $0.type == .phone }
      #expect(phoneContacts.count == 10)
      #expect(phoneContacts.allSatisfy { $0.value.hasPrefix("+1 202-555-") })
      #expect(phoneContacts.filter(\.authorizedForCare).count == 8)
      #expect(seeded.patients.flatMap(\.encounters).count == 30)
      #expect(seeded.patients.flatMap(\.rawAssets).count == 10)

      let finalizations = seeded.patients.flatMap(\.encounters).map(\.finalizationStatus)
      #expect(finalizations.filter { if case .draft = $0 { true } else { false } }.isEmpty)
      #expect(finalizations.filter { if case .verified = $0 { true } else { false } }.count == 30)
      #expect(
        finalizations.compactMap { status -> Int? in
          guard case .verified(let summary) = status else { return nil }
          return summary.addenda.count
        }.reduce(0, +) == 3)

      let orderedPatients = seeded.patients.sorted { $0.displayName < $1.displayName }
      for (patient, scenario) in zip(orderedPatients, SyntheticPatientScenarios.patients.sorted { $0.name < $1.name }) {
        let wiki = try PatientWikiStore().load(for: patient)
        let summary = try #require(wiki.summary)
        #expect(wiki.summaryIssue == nil)
        #expect(summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines) == scenario.wiki.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(summary.markdown.contains("[F1]"))
        #expect(summary.markdown.contains("[F2]"))
        #expect(summary.markdown.contains("[F3]"))
        let encounters = patient.encounters.sorted { $0.metadata.startedAt < $1.metadata.startedAt }
        #expect(summary.sources.prefix(3).map(\.id) == encounters.map(\.metadata.encounterID))
        #expect(summary.sources.prefix(3).allSatisfy { $0.path.hasPrefix("content/notes/final/") })
        let finalHashes = encounters.compactMap { encounter -> String? in
          guard case let .verified(finalization) = encounter.finalizationStatus else { return nil }
          return PatientAIContext.digest(Data(finalization.finalNote.body.utf8))
        }
        #expect(summary.sources.prefix(3).map(\.sha256) == finalHashes)
        let history = try PatientHistoryReader().load(
          patientID: patient.patientID,
          vaultURL: seeded.url,
          authorizationURL: seeded.url
        )
        let realContext = try PatientAIContext.make(patient: patient, entries: history.entries, corrections: "")
        #expect(summary.sourceFingerprint == realContext.fingerprint)
      }

      #expect(Set(seeded.appointments.map(\.record.modality)) == Set(AppointmentModality.allCases))
      #expect(Set(seeded.appointments.map(\.record.status)) == Set(AppointmentStatus.allCases))
      #expect(
        Set(
          seeded.appointments.map { appointment in
            Int(appointment.record.endDate.timeIntervalSince(appointment.record.startDate) / 60)
          }) == Set([15, 30, 45, 60, 90]))
      #expect(hasOverlap(seeded.appointments))
      let overlapCount = seeded.appointments.enumerated().reduce(0) { count, item in
        count + seeded.appointments.dropFirst(item.offset + 1).filter {
          item.element.record.status != .cancelled && $0.record.status != .cancelled
            && item.element.record.startDate < $0.record.endDate
            && item.element.record.endDate > $0.record.startDate
        }.count
      }
      #expect(overlapCount == 1)
      var localCalendar = Calendar(identifier: .gregorian)
      localCalendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
      #expect(
        seeded.appointments.filter {
          localCalendar.isDate($0.record.startDate, inSameDayAs: referenceDate)
        }.count >= 10)
      #expect(
        seeded.appointments.allSatisfy {
          abs(localCalendar.dateComponents([.day], from: localCalendar.startOfDay(for: referenceDate),
              to: localCalendar.startOfDay(for: $0.record.startDate)).day ?? 99) <= 4
        })

      let sourceIndex = ClinicalSearchIndex(patients: seeded.patients)
      let queries = [
        SyntheticPatientScenarios.patients[0].name,
        SyntheticPatientScenarios.patients[9].name,
        "Ficha de atendimento",
      ]
      #expect(queries.allSatisfy { !sourceIndex.search($0).isEmpty })

      let backupURL = parent.appending(path: "release-solo-backup")
      let backup = try VaultBackupService().create(from: seeded.url, to: backupURL)
      _ = try VaultBackupService().verify(at: backupURL)
      let restoredURL = parent.appending(path: "release-solo-restored")
      _ = try VaultBackupService().restore(
        from: backupURL,
        to: restoredURL,
        expectedManifestSHA256: backup.manifestSHA256
      )
      let restored = try VaultReader().open(restoredURL)
      #expect(try Data(contentsOf: restoredURL.appending(path: "recordings/demo.wav")) == audio)
      let restoredIndex = ClinicalSearchIndex(patients: restored.patients)

      #expect(restored.patients.count == seeded.patients.count)
      #expect(restored.appointments.count == seeded.appointments.count)
      #expect(
        restored.patients.flatMap(\.encounters).count == seeded.patients.flatMap(\.encounters).count
      )
      #expect(
        restored.patients.flatMap(\.rawAssets).count == seeded.patients.flatMap(\.rawAssets).count)
      for patient in restored.patients {
        let wiki = try PatientWikiStore().load(for: patient)
        #expect(wiki.summaryIssue == nil)
        #expect(wiki.summary?.sources.count ?? 0 >= 3)
      }
      for query in queries {
        #expect(restoredIndex.search(query) == sourceIndex.search(query))
      }

      let exportPatient = try #require(restored.patients.first)
      let exportEncounter = try #require(exportPatient.encounters.first)
      let patientExport = try ClinicalExportService().export(
        scope: .patient(patientID: exportPatient.patientID),
        from: restored.url,
        to: parent.appending(path: "release-solo-patient-export")
      )
      let encounterExport = try ClinicalExportService().export(
        scope: .encounter(
          patientID: exportPatient.patientID,
          encounterID: exportEncounter.metadata.encounterID
        ),
        from: restored.url,
        to: parent.appending(path: "release-solo-encounter-export")
      )
      #expect(patientExport.encounterCount == 3)
      #expect(patientExport.documentCount == 1)
      #expect(encounterExport.encounterCount == 1)
      #expect(encounterExport.documentCount == 1)
    }
  }

  private func hasOverlap(_ appointments: [AppointmentSummary]) -> Bool {
    for (index, appointment) in appointments.enumerated() {
      if appointments.dropFirst(index + 1).contains(where: {
        appointment.record.status != .cancelled
          && $0.record.status != .cancelled
          && appointment.record.startDate < $0.record.endDate
          && appointment.record.endDate > $0.record.startDate
      }) {
        return true
      }
    }
    return false
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "openpep-release-synthetic-tests-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }
}
