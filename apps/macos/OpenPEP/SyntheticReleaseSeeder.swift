// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct SyntheticReleaseSeeder {
  private let fileManager: FileManager
  private let cardiology: Bool
  private var scenarios: [SyntheticPatientScenario] {
    cardiology ? SyntheticCardiologyScenarios.patients : SyntheticPatientScenarios.patients
  }

  init(fileManager: FileManager = .default, cardiology: Bool = false) {
    self.fileManager = fileManager
    self.cardiology = cardiology
  }

  func seed(in parent: URL, at date: Date) throws -> VaultSummary {
    let identity = try VaultCreationIdentity.generate(at: date)
    let prefix = cardiology ? "OpenPEP-Cardiologia-Sintetica" : "OpenPEP-Ensaio-Sintetico"
    let directoryName = "\(prefix)-\(UUID().uuidString.lowercased())"
    let created = try VaultCreator(fileManager: fileManager).create(
      in: parent,
      directoryName: directoryName,
      identity: identity,
      createdAt: date
    )
    do {
      let calendar = syntheticCalendar
      let startOfToday = calendar.startOfDay(for: date)
      for (index, scenario) in scenarios.enumerated() {
        let sequence = index + 1
        let eventDate = date.addingTimeInterval(TimeInterval(sequence))
        let patient = try PatientCreator(fileManager: fileManager).createRegistered(
          in: created.url,
          identity: try PatientCreationIdentity.generate(at: eventDate),
          input: patientInput(at: index, referenceDate: date),
          createdAt: eventDate
        )

        for appointmentOrdinal in 0..<3 {
          _ = try AppointmentWriter(fileManager: fileManager).create(
            in: created.url,
            patient: patient,
            identity: try AppointmentCreationIdentity.generate(
              at: eventDate.addingTimeInterval(Double(appointmentOrdinal + 1) / 10)
            ),
            input: try appointmentInput(
              patientID: patient.patientID,
              patientIndex: index,
              ordinal: appointmentOrdinal,
              startOfToday: startOfToday,
              calendar: calendar
            ),
            createdAt: eventDate
          )
        }

        var encounterIDs: [String] = []
        for (encounterIndex, scenarioEncounter) in scenario.encounters.enumerated() {
          let encounterDate = date.addingTimeInterval(
            TimeInterval(-86_400 * scenarioEncounter.daysAgo)
          )
          let encounter = try ClinicalDraftCreator(fileManager: fileManager).create(
            in: patient,
            identity: try ClinicalDraftCreationIdentity.generate(at: encounterDate),
            appointmentID: nil,
            input: EncounterStartInput(
              modality: (index + encounterIndex).isMultiple(of: 2) ? .inPerson : .telemedicine,
              template: try ClinicalTemplateChoice.imported(
                data: Data(scenarioEncounter.body.utf8),
                fileName: "consulta-ficticia-\(padded(sequence))-\(encounterIndex + 1).md"
              ),
              telemedicine: (index + encounterIndex).isMultiple(of: 2)
                ? nil
                : TelemedicineEncounterInput(
                  consent: .confirmed,
                  declaredLocation: "Domicílio",
                  participants: [scenario.name],
                  limitations: nil,
                  contingency: "Avaliação presencial se a videochamada for insuficiente"
                )
            ),
            startedAt: encounterDate
          )
          encounterIDs.append(encounter.metadata.encounterID)
        }

        var openedPatient = try reopenPatient(withID: patient.patientID, in: created.url)
        if cardiology {
          for (documentIndex, document) in SyntheticCardiologyScenarios.documents[index].enumerated() {
            let documentDate = date.addingTimeInterval(TimeInterval(-86_400 * document.daysAgo))
            openedPatient = try reopenPatient(withID: patient.patientID, in: created.url)
            try importCardiologyDocument(
              document, patientName: scenario.name, for: openedPatient,
              deviceID: identity.deviceID, parent: parent,
              documentDate: documentDate,
              importedAt: eventDate.addingTimeInterval(Double(60 + documentIndex))
            )
          }
        } else {
          try importDocument(
            for: openedPatient,
            encounterID: encounterIDs[0],
            deviceID: identity.deviceID,
            index: index,
            parent: parent,
            importedAt: eventDate.addingTimeInterval(60)
          )
        }

        for (encounterIndex, encounterID) in encounterIDs.enumerated() {
          let encounterDate = date.addingTimeInterval(
            TimeInterval(-86_400 * scenario.encounters[encounterIndex].daysAgo)
          )
          openedPatient = try reopenPatient(withID: patient.patientID, in: created.url)
          let openedEncounter = try reopenEncounter(withID: encounterID, in: openedPatient)
          _ = try ClinicalFinalizer(fileManager: fileManager).finalize(
            patient: openedPatient,
            encounter: openedEncounter,
            identity: try FinalizationIdentity.generate(at: encounterDate.addingTimeInterval(120)),
            finalizedAt: encounterDate.addingTimeInterval(120)
          )
        }

        if index % 3 == 2 {
          let encounterDate = date.addingTimeInterval(
            TimeInterval(-86_400 * scenario.encounters[2].daysAgo)
          )
          openedPatient = try reopenPatient(withID: patient.patientID, in: created.url)
          let finalizedEncounter = try reopenEncounter(withID: encounterIDs[2], in: openedPatient)
          _ = try ClinicalAddendumWriter(fileManager: fileManager).add(
            patient: openedPatient,
            encounter: finalizedEncounter,
            identity: try AddendumIdentity.generate(at: encounterDate.addingTimeInterval(180)),
            reason: "Complemento de registro",
            body: "Sem novas informações clínicas.",
            createdAt: encounterDate.addingTimeInterval(180)
          )
        }

        openedPatient = try reopenPatient(withID: patient.patientID, in: created.url)
        try seedWiki(
          for: openedPatient,
          vaultURL: created.url,
          scenario: scenario,
          overview: cardiology ? SyntheticCardiologyScenarios.overviews[index] : nil,
          encounterIDs: encounterIDs,
          generatedAt: eventDate
        )
      }

      return try VaultReader(fileManager: fileManager).open(created.url)
    } catch {
      throw VaultValidationIssue(
        rule: "synthetic_release.incomplete",
        path: created.url.path,
        message:
          "O ensaio sintético ficou incompleto. A pasta nova foi preservada para inspeção. Detalhe: \(error.localizedDescription)"
      )
    }
  }

  /// Check digits only: these examples are not verified against any real CPF register.
  static func syntheticCPF(sequence: Int) -> String {
    var digits = String(format: "%09d", 900_000_000 + sequence).compactMap(\.wholeNumberValue)
    for count in [9, 10] {
      let sum = digits.prefix(count).enumerated().reduce(0) { $0 + $1.element * (count + 1 - $1.offset) }
      let remainder = sum % 11
      digits.append(remainder < 2 ? 0 : 11 - remainder)
    }
    return digits.map(String.init).joined()
  }

  private func patientInput(at index: Int, referenceDate: Date) -> PatientRecordInput {
    let scenario = scenarios[index]
    let sequence = index + 1
    var calendar = syntheticCalendar
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let birthDate = calendar.date(byAdding: .year, value: -scenario.age, to: referenceDate)!
    let birthFormatter = DateFormatter()
    birthFormatter.calendar = Calendar(identifier: .gregorian)
    birthFormatter.locale = Locale(identifier: "en_US_POSIX")
    birthFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    birthFormatter.dateFormat = "yyyy-MM-dd"
    let alerts: [PatientAlert] = []
    return PatientRecordInput(
      fullName: scenario.name,
      preferredName: nil,
      birthDate: birthFormatter.string(from: birthDate),
      contacts: [
        PatientContact(
          type: .phone,
          value: String(format: "+1 202-555-%04d", 100 + index),
          authorizedForCare: !index.isMultiple(of: 5)
        ),
        PatientContact(
          type: .email,
          value: "paciente\(padded(sequence))@example.invalid",
          authorizedForCare: index.isMultiple(of: 2)
        ),
      ],
      identifiers: [PatientIdentifier(type: .cpf, value: Self.syntheticCPF(sequence: sequence)),
                    PatientIdentifier(type: .other, value: "P-\(padded(sequence))")],
      alerts: alerts,
      registration: ["street": .string("Rua de Demonstração"), "number": .string("100"),
        "complement": .string("Endereço fictício - sem entrega"), "district": .string("Bela Vista"),
        "city": .string("São Paulo"), "state": .string("SP"),
        "notes": .string("Cadastro de demonstração. CPF gerado por algoritmo; não consultado nem vinculado a pessoa real.")]

    )
  }

  private func appointmentInput(
    patientID: String,
    patientIndex: Int,
    ordinal: Int,
    startOfToday: Date,
    calendar: Calendar
  ) throws -> AppointmentInput {
    // Ten appointments per day across yesterday, today and tomorrow. Separate
    // repeat visits and leave a lunch break. Exactly one deliberate pair overlaps.
    let sequence = ordinal * scenarios.count + patientIndex
    let dayOffset = sequence / 10 - 1
    let slot = sequence % 10
    let durations = appointmentDurations
    let duration = durations[slot % durations.count]
    let precedingSlots = sequence == 19 ? 8 : slot
    let minuteOffset = (0..<precedingSlots).reduce(0) { $0 + durations[$1 % durations.count] }
      + (precedingSlots >= 5 ? 60 : 0) + (sequence == 19 ? 15 : 0)
    let hourOffset = 8
    guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
      let hour = calendar.date(byAdding: .hour, value: hourOffset, to: day),
      let startsAt = calendar.date(byAdding: .minute, value: minuteOffset, to: hour),
      let endsAt = calendar.date(
        byAdding: .minute,
        value: duration,
        to: startsAt
      )
    else {
      throw VaultValidationIssue(
        rule: "synthetic_release.calendar",
        path: "/appointments",
        message: "A agenda sintética não pôde ser posicionada em torno da data escolhida."
      )
    }
    let modality: AppointmentModality =
      (patientIndex + ordinal).isMultiple(of: 2)
      ? .inPerson
      : .telemedicine
    let status: AppointmentStatus
    if dayOffset < 0 {
      status = [.completed, .completed, .noShow, .completed, .cancelled][slot % 5]
    } else if dayOffset == 0 {
      status = [.completed, .noShow, .arrived, .inProgress, .scheduled, .cancelled,
                .scheduled, .scheduled, .scheduled, .scheduled][slot]
    } else {
      status = slot == 5 ? .cancelled : .scheduled
    }
    return AppointmentInput(
      patientID: patientID,
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: "America/Sao_Paulo",
      modality: modality,
      status: status,
      location: modality == .inPerson ? ["Consultório Centro", "Consultório Jardim", "Clínica Alameda"][patientIndex % 3] : nil,
      remoteAccessURL: modality == .telemedicine
        ? "https://teleconsulta-\(padded(patientIndex + 1))-\(ordinal + 1).example.invalid/sala"
        : nil,
      administrativeNote:
        ordinal == 0 ? "Retorno" : nil
    )
  }

  private func importDocument(
    for patient: PatientSummary,
    encounterID: String,
    deviceID: String,
    index: Int,
    parent: URL,
    importedAt: Date
  ) throws {
    let staging = parent.appending(path: "demo-document-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }
    let source = staging.appending(path: "Ficha de atendimento.txt")
    let scenario = scenarios[index]
    try Data("Registro de apoio\n\nPaciente: \(scenario.name)\nOcupação: \(scenario.occupation)\n".utf8)
      .write(to: source, options: [.withoutOverwriting])
    _ = try GeneralDocumentImporter(fileManager: fileManager).importDocument(
      from: source,
      into: patient,
      encounterID: encounterID,
      deviceID: deviceID,
      identity: try RawAssetCreationIdentity.generate(at: importedAt),
      importedAt: importedAt
    )
  }

  private func importCardiologyDocument(
    _ document: SyntheticCardiologyDocument,
    patientName: String,
    for patient: PatientSummary,
    deviceID: String,
    parent: URL,
    documentDate: Date,
    importedAt: Date
  ) throws {
    let staging = parent.appending(path: "cardiology-document-\(UUID().uuidString.lowercased())")
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }
    let formatter = DateFormatter()
    formatter.calendar = syntheticCalendar
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.timeZone = syntheticCalendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: documentDate)
    let title = document.title.replacingOccurrences(of: "/", with: "-")
    let source = staging.appending(path: "\(day) - \(title).\(document.isPDF ? "pdf" : "txt")")
    let body = "DADOS INTEIRAMENTE FICTÍCIOS - TESTE DE SOFTWARE\nSEM VALIDADE CLÍNICA OU DE RECEITA\n\nPaciente: \(patientName)\nData do documento: \(day)\n\n\(document.title)\n\n\(document.body)"
    let data = document.isPDF
      ? try SyntheticCardiologyPDF.render(body)
      : Data(body.utf8)
    try data.write(to: source, options: [.withoutOverwriting])
    _ = try GeneralDocumentImporter(fileManager: fileManager).importDocument(
      from: source, into: patient, encounterID: nil, deviceID: deviceID,
      identity: try RawAssetCreationIdentity.generate(at: importedAt), importedAt: importedAt
    )
  }

  private func reopenPatient(withID patientID: String, in vaultURL: URL) throws -> PatientSummary {
    let opened = try VaultReader(fileManager: fileManager).open(vaultURL)
    guard let patient = opened.patients.first(where: { $0.patientID == patientID }) else {
      throw VaultValidationIssue(
        rule: "synthetic_release.patient_reopen",
        path: patientID,
        message: "O paciente sintético não pôde ser relido."
      )
    }
    return patient
  }

  private func reopenEncounter(withID encounterID: String, in patient: PatientSummary) throws
    -> EncounterSummary
  {
    guard
      let encounter = patient.encounters.first(where: { $0.metadata.encounterID == encounterID })
    else {
      throw VaultValidationIssue(
        rule: "synthetic_release.encounter_reopen",
        path: encounterID,
        message: "A consulta sintética não pôde ser relida."
      )
    }
    return encounter
  }

  private func seedWiki(
    for patient: PatientSummary,
    vaultURL: URL,
    scenario: SyntheticPatientScenario,
    overview: String?,
    encounterIDs: [String],
    generatedAt: Date
  ) throws {
    let context = try wikiContext(for: patient, vaultURL: vaultURL)
    let sourceByID = Dictionary(uniqueKeysWithValues: context.entries.map {
      ($0.id, PatientWikiSource(
        id: $0.id,
        path: $0.source,
        sha256: PatientAIContext.digest(Data($0.text.utf8))
      ))
    })
    let citedSources = try encounterIDs.map { encounterID -> PatientWikiSource in
      guard let source = sourceByID[encounterID], source.path.hasPrefix("content/notes/final/") else {
        throw VaultValidationIssue(
          rule: "synthetic_release.wiki_source",
          path: encounterID,
          message: "A fonte final da wiki sintética não pôde ser relida."
        )
      }
      return source
    }
    let sources = citedSources + context.entries.compactMap { entry in
      guard !encounterIDs.contains(entry.id) else { return nil }
      return sourceByID[entry.id]
    }
    _ = try PatientWikiStore(fileManager: fileManager).saveSummary(
      for: patient,
      input: PatientWikiSummaryInput(
        markdown: scenario.wiki,
        sourceFingerprint: context.fingerprint,
        model: "openpep/synthetic-scenario@1",
        generatedAt: syntheticTimestamp(generatedAt),
        sources: sources,
        overview: overview,
        exclusions: overview == nil ? nil : context.exclusions,
        promptVersion: overview == nil ? nil : PatientWikiGeneration.prompt.id
      ),
      expectedData: nil,
      expectedCorrectionsData: nil,
      validateSources: {
        let latest = try wikiContext(for: patient, vaultURL: vaultURL)
        let latestSources = try wikiSources(
          from: latest.entries,
          citedEncounterIDs: encounterIDs
        )
        guard latest.fingerprint == context.fingerprint, latestSources == sources else {
          throw VaultValidationIssue(
            rule: "synthetic_release.wiki_changed",
            path: patient.patientID,
            message: "As fontes da wiki sintética mudaram durante a gravação."
          )
        }
      }
    )
    let persisted = try PatientWikiStore(fileManager: fileManager).load(for: patient)
    guard persisted.summary?.sourceFingerprint == context.fingerprint,
      persisted.summary?.sources == sources,
      persisted.summaryIssue == nil
    else {
      throw VaultValidationIssue(
        rule: "synthetic_release.wiki_persisted",
        path: patient.patientID,
        message: "A wiki sintética não foi relida com as fontes esperadas."
      )
    }
  }

  private func wikiContext(for patient: PatientSummary, vaultURL: URL) throws
    -> (entries: [PatientHistoryEntry], fingerprint: String, exclusions: PatientWikiExclusions)
  {
    let history = try PatientHistoryReader().load(
      patientID: patient.patientID,
      vaultURL: vaultURL,
      authorizationURL: vaultURL
    )
    if cardiology {
      let context = try PatientWikiContext.make(patient: patient, entries: history.entries, corrections: "")
      return (context.entries, context.fingerprint, context.exclusions)
    }
    let context = try PatientAIContext.make(patient: patient, entries: history.entries, corrections: "")
    return (context.entries, context.fingerprint, PatientWikiExclusions())
  }

  private func wikiSources(
    from entries: [PatientHistoryEntry],
    citedEncounterIDs: [String]
  ) throws -> [PatientWikiSource] {
    let sourceByID = Dictionary(uniqueKeysWithValues: entries.map {
      ($0.id, PatientWikiSource(
        id: $0.id,
        path: $0.source,
        sha256: PatientAIContext.digest(Data($0.text.utf8))
      ))
    })
    let cited = try citedEncounterIDs.map { encounterID -> PatientWikiSource in
      guard let source = sourceByID[encounterID], source.path.hasPrefix("content/notes/final/") else {
        throw VaultValidationIssue(
          rule: "synthetic_release.wiki_source",
          path: encounterID,
          message: "A fonte final da wiki sintética não pôde ser relida."
        )
      }
      return source
    }
    return cited + entries.compactMap { entry in
      guard !citedEncounterIDs.contains(entry.id) else { return nil }
      return sourceByID[entry.id]
    }
  }

  private var syntheticCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "pt_BR")
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    return calendar
  }

  private func syntheticTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private func padded(_ value: Int) -> String {
    String(format: "%02d", value)
  }

  private let appointmentDurations = [15, 30, 45, 60, 90]

}
