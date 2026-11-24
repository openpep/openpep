// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct RawAssetSummary: Equatable, Sendable {
    let assetID: String
    let encounterID: String?
    let originalName: String
    let importedAt: String
    let mediaType: String
    let fileExtension: String
    let sizeBytes: Int
    let sha256: String
    let source: String
    let inspectionResult: String
    let originalURL: URL
}

struct PatientSummary: Equatable, Sendable {
    let patientID: String
    let url: URL
    let record: PatientRecord?
    let rawAssets: [RawAssetSummary]
    let encounters: [EncounterSummary]
    let trashedRawAssets: [RawAssetSummary]
    let trashedEncounters: [EncounterSummary]

    init(
        patientID: String,
        url: URL,
        record: PatientRecord?,
        rawAssets: [RawAssetSummary],
        encounters: [EncounterSummary],
        trashedRawAssets: [RawAssetSummary] = [],
        trashedEncounters: [EncounterSummary] = []
    ) {
        self.patientID = patientID
        self.url = url
        self.record = record
        self.rawAssets = rawAssets
        self.encounters = encounters
        self.trashedRawAssets = trashedRawAssets
        self.trashedEncounters = trashedEncounters
    }

    var rawAssetCount: Int { rawAssets.count }
    var displayName: String {
        guard let record else { return patientID }
        return record.preferredName ?? record.fullName ?? "Paciente sem nome"
    }
    var isArchived: Bool { record?.status == .archived }

    func age(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        PatientAge.years(fromStorage: record?.birthDate, on: date, calendar: calendar)
    }
}

struct PatientRecordInput: Equatable, Sendable {
    let fullName: String
    let preferredName: String?
    let birthDate: String?
    let contacts: [PatientContact]
    let identifiers: [PatientIdentifier]
    let alerts: [PatientAlert]
    var registration: [String: YAMLValue]? = nil

    func normalized() -> PatientRecordInput {
        PatientRecordInput(
            fullName: normalizedRequired(fullName),
            preferredName: normalizedOptional(preferredName),
            birthDate: normalizedOptional(birthDate),
            contacts: contacts.compactMap { contact in
                let value = normalizedRequired(contact.value)
                return value.isEmpty ? nil : PatientContact(
                    type: contact.type,
                    value: value,
                    authorizedForCare: contact.authorizedForCare
                )
            },
            identifiers: identifiers.compactMap { identifier in
                let value = normalizedRequired(identifier.value)
                return value.isEmpty ? nil : PatientIdentifier(type: identifier.type, value: value)
            },
            alerts: alerts.compactMap { alert in
                let description = normalizedRequired(alert.description)
                let source = normalizedRequired(alert.source)
                return description.isEmpty ? nil : PatientAlert(
                    type: alert.type,
                    description: description,
                    source: source.isEmpty ? "Não informada" : source,
                    recordedAt: alert.recordedAt
                )
            },
            registration: registration
        )
    }

    private func normalizedRequired(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedRequired(value)
        return normalized.isEmpty ? nil : normalized
    }
}

enum PatientDateText {
    static func displayValue(fromStorage value: String?) -> String {
        guard let value, let date = storageFormatter.date(from: value) else { return "" }
        return displayFormatter.string(from: date)
    }

    static func storageValue(fromDisplay value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = displayFormatter.date(from: trimmed) else { return nil }
        guard displayFormatter.string(from: date) == trimmed else { return nil }
        return storageFormatter.string(from: date)
    }

    static func isValidDisplayValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || storageValue(fromDisplay: trimmed) != nil
    }

    private static var storageFormatter: DateFormatter {
        formatter(format: "yyyy-MM-dd", locale: "en_US_POSIX")
    }

    private static var displayFormatter: DateFormatter {
        formatter(format: "dd/MM/yyyy", locale: "pt_BR")
    }

    private static func formatter(format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}

enum PatientAge {
    static func years(
        fromStorage value: String?,
        on referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let birthDate = calendar.date(from: DateComponents(
                  calendar: calendar,
                  year: year,
                  month: month,
                  day: day
              )),
              birthDate <= referenceDate else {
            return nil
        }
        return calendar.dateComponents([.year], from: birthDate, to: referenceDate).year
    }

    static func label(for years: Int) -> String {
        years == 1 ? "1 ano" : "\(years) anos"
    }
}

enum PatientInputText {
    static func asciiDigits(_ value: String, limit: Int? = nil) -> String {
        let scalars = value.unicodeScalars.filter { (48...57).contains($0.value) }
        let digits = String(String.UnicodeScalarView(scalars))
        guard let limit else { return digits }
        return String(digits.prefix(limit))
    }

    static func date(_ value: String) -> String {
        grouped(asciiDigits(value, limit: 8), lengths: [2, 2, 4], separator: "/")
    }

    static func cpf(_ value: String) -> String {
        let digits = asciiDigits(value, limit: 11)
        let first = String(digits.prefix(3))
        let second = String(digits.dropFirst(3).prefix(3))
        let third = String(digits.dropFirst(6).prefix(3))
        let check = String(digits.dropFirst(9).prefix(2))
        var result = first
        if !second.isEmpty { result += ".\(second)" }
        if !third.isEmpty { result += ".\(third)" }
        if !check.isEmpty { result += "-\(check)" }
        return result
    }

    static func brazilianPhone(_ value: String) -> String {
        let digits = asciiDigits(value, limit: 11)
        guard !digits.isEmpty else { return "" }
        let area = String(digits.prefix(2))
        let subscriber = String(digits.dropFirst(2))
        var result = "(\(area)"
        guard area.count == 2 else { return result }
        result += ")"
        guard !subscriber.isEmpty else { return result }
        let firstLength = digits.count == 11 ? 5 : 4
        let first = String(subscriber.prefix(firstLength))
        let second = String(subscriber.dropFirst(firstLength).prefix(4))
        result += " \(first)"
        if !second.isEmpty { result += "-\(second)" }
        return result
    }

    private static func grouped(_ value: String, lengths: [Int], separator: String) -> String {
        var groups: [String] = []
        var start = value.startIndex
        for length in lengths where start < value.endIndex {
            let end = value.index(start, offsetBy: length, limitedBy: value.endIndex) ?? value.endIndex
            groups.append(String(value[start..<end]))
            start = end
        }
        return groups.joined(separator: separator)
    }
}

enum PatientCPF {
    static func isStructurallyValid(_ value: String) -> Bool {
        let digits = PatientInputText.asciiDigits(value)
        guard digits.count == 11, Set(digits).count > 1 else { return false }
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count == 11 else { return false }
        return checkDigit(for: Array(numbers.prefix(9)), weights: Array(stride(from: 10, through: 2, by: -1))) == numbers[9]
            && checkDigit(for: Array(numbers.prefix(10)), weights: Array(stride(from: 11, through: 2, by: -1))) == numbers[10]
    }

    private static func checkDigit(for numbers: [Int], weights: [Int]) -> Int {
        let remainder = zip(numbers, weights).reduce(0) { $0 + ($1.0 * $1.1) } % 11
        return remainder < 2 ? 0 : 11 - remainder
    }
}

enum PatientPhoneText {
    static func brazilianNumber(fromStorage value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = PatientInputText.asciiDigits(trimmed)
        if trimmed.hasPrefix("+55"), (12...13).contains(digits.count) {
            return PatientInputText.brazilianPhone(String(digits.dropFirst(2)))
        }
        if !trimmed.hasPrefix("+") && digits.count <= 11 {
            return PatientInputText.brazilianPhone(digits)
        }
        return nil
    }

    static func storageValue(fromBrazilianNumber value: String) -> String {
        let formatted = PatientInputText.brazilianPhone(value)
        return formatted.isEmpty ? "" : "+55 \(formatted)"
    }
}

struct PatientInspection: Equatable, Sendable {
    let patients: [PatientSummary]
    let unavailablePatients: [UnavailablePatientSummary]
    let writingAllowed: Bool
    let statusMessage: String?
}

enum PatientSearch {
    static func matches(_ patient: PatientSummary, query: String) -> Bool {
        let rawQuery = query
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return true }
        let values = [
            patient.patientID,
            patient.record?.fullName,
            patient.record?.preferredName,
        ].compactMap { $0 }.map(normalize)
        if values.contains(where: { $0.contains(query) }) { return true }

        let cpfQuery = PatientInputText.asciiDigits(rawQuery)
        guard !cpfQuery.isEmpty else { return false }
        return (patient.record?.identifiers ?? []).contains { identifier in
            identifier.type == .cpf
                && PatientInputText.asciiDigits(identifier.value).contains(cpfQuery)
        }
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum PatientDuplicateDetector {
    static func candidates(
        for input: PatientRecordInput,
        among patients: [PatientSummary],
        excluding patientID: String? = nil
    ) -> [PatientSummary] {
        let normalized = input.normalized()
        let name = PatientSearch.normalize(normalized.fullName)
        let cpfs = Set(normalized.identifiers.compactMap { identifier -> String? in
            guard identifier.type == .cpf else { return nil }
            let digits = PatientInputText.asciiDigits(identifier.value)
            return digits.isEmpty ? nil : digits
        })
        return patients.filter { patient in
            guard patient.patientID != patientID, let record = patient.record else { return false }
            let existingCPFs = Set(record.identifiers.compactMap { identifier -> String? in
                guard identifier.type == .cpf else { return nil }
                let digits = PatientInputText.asciiDigits(identifier.value)
                return digits.isEmpty ? nil : digits
            })
            if !cpfs.isDisjoint(with: existingCPFs) { return true }

            guard !name.isEmpty else { return false }
            guard let fullName = record.fullName,
                  PatientSearch.normalize(fullName) == name else { return false }
            if let birthDate = normalized.birthDate, let existingBirthDate = record.birthDate {
                return birthDate == existingBirthDate
            }
            return true
        }
    }
}

struct UnavailablePatientSummary: Equatable, Sendable {
    let patientID: String?
    let relativePath: String
    let rule: String
}

enum PatientLayout {
    static let directories = [".openpep", "content", "raw", "wiki"]
    static let manifest = "patient.yaml"
}

enum SyntheticRawFixtureContract {
    static let fileName = "openpep-synthetic-raw.txt"
    static let marker = "OPENPEP_SYNTHETIC_FIXTURE_V1\n"
    static let sizeBytes = 85
    static let sha256 = "4aeb1d1faf00d45866a96552b2ae7cdfdd2eff6ccfae75d09c57e2af66a33576"
}

enum OpenPEPIdentifier {
    private static let uuidV7 =
        "[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"

    static func isPatient(_ value: String) -> Bool {
        matches(value, pattern: "^pt_\(uuidV7)$")
    }

    static func isAppointment(_ value: String) -> Bool {
        matches(value, pattern: "^appt_\(uuidV7)$")
    }

    static func isAsset(_ value: String) -> Bool {
        matches(value, pattern: "^asset_\(uuidV7)$")
    }

    static func isEncounter(_ value: String) -> Bool {
        matches(value, pattern: "^enc_\(uuidV7)$")
    }

    static func isNote(_ value: String) -> Bool {
        matches(value, pattern: "^note_\(uuidV7)$")
    }

    static func isUser(_ value: String) -> Bool {
        matches(value, pattern: "^usr_\(uuidV7)$")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        // ICU's `$` also matches before a final newline; identifiers never contain line breaks.
        !value.contains(where: \.isNewline) && value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct PatientCreationIdentity: Equatable, Sendable {
    let patientID: String

    static func generate(at date: Date = Date()) throws -> PatientCreationIdentity {
        PatientCreationIdentity(patientID: "pt_\(try UUIDv7.generate(at: date))")
    }
}

enum PatientCreationStep: Equatable, Sendable {
    case temporaryDirectoryCreated
    case directoriesCreated
    case manifestWritten
}

struct PatientCreator {
    typealias FaultInjector = (PatientCreationStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func create(in vaultURL: URL, identity: PatientCreationIdentity) throws -> PatientSummary {
        try create(in: vaultURL, identity: identity, record: nil)
    }

    func createRegistered(
        in vaultURL: URL,
        identity: PatientCreationIdentity,
        input: PatientRecordInput,
        createdAt: Date = Date()
    ) throws -> PatientSummary {
        let timestamp = patientTimestamp(createdAt)
        let normalized = input.normalized()
        let record = PatientRecord(
            schema: "openpep/patient@1",
            patientID: identity.patientID,
            status: .active,
            fullName: normalized.fullName.isEmpty ? nil : normalized.fullName,
            preferredName: normalized.preferredName,
            birthDate: normalized.birthDate,
            contacts: normalized.contacts,
            identifiers: normalized.identifiers,
            alerts: normalized.alerts,
            createdAt: timestamp,
            updatedAt: timestamp,
            archivedAt: nil,
            extensions: normalized.registration.map { ["x_openpep_registration": .mapping($0)] } ?? [:]
        )
        return try create(in: vaultURL, identity: identity, record: record)
    }

    private func create(
        in vaultURL: URL,
        identity: PatientCreationIdentity,
        record: PatientRecord?
    ) throws -> PatientSummary {
        guard OpenPEPIdentifier.isPatient(identity.patientID) else {
            throw issue("patient.invalid_id", identity.patientID, "O patient_id não é seguro.")
        }

        let patientsURL = vaultURL.appending(path: "patients", directoryHint: .isDirectory)
        var outcome: Result<PatientSummary, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: patientsURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedPatients in
            do {
                outcome = .success(try createUncoordinated(
                    in: coordinatedPatients,
                    identity: identity,
                    record: record
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", patientsURL.path, "A criação coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func createUncoordinated(
        in patientsURL: URL,
        identity: PatientCreationIdentity,
        record: PatientRecord?
    ) throws -> PatientSummary {
        let patientsValues = try patientsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard patientsValues.isDirectory == true, patientsValues.isSymbolicLink != true else {
            throw issue("filesystem.directory", patientsURL.path, "patients deve ser um diretório sem link simbólico.")
        }
        let destination = patientsURL.appending(path: identity.patientID, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw issue("patient.destination_exists", destination.path, "O paciente já existe.")
        }

        let temporary = patientsURL.appending(
            path: ".openpep-patient-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        var published = false
        defer {
            if !published, fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        try faultInjector?(.temporaryDirectoryCreated)
        for relativePath in PatientLayout.directories {
            try fileManager.createDirectory(
                at: temporary.appending(path: relativePath, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }
        try faultInjector?(.directoriesCreated)
        if let record {
            let data = try PatientRecordCodec.encode(record)
            _ = try VaultManifestValidator.validatePatient(data: data)
            try data.write(
                to: temporary.appending(path: PatientLayout.manifest),
                options: [.withoutOverwriting]
            )
            try faultInjector?(.manifestWritten)
        }

        try fileManager.moveItem(at: temporary, to: destination)
        published = true
        return PatientSummary(
            patientID: identity.patientID,
            url: destination,
            record: record,
            rawAssets: [],
            encounters: []
        )
    }
}

enum PatientUpdateStep: Equatable, Sendable {
    case temporaryManifestWritten
}

struct PatientEditor {
    typealias FaultInjector = (PatientUpdateStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func update(
        patient: PatientSummary,
        input: PatientRecordInput,
        status: PatientStatus? = nil,
        updatedAt: Date = Date()
    ) throws -> PatientRecord {
        guard let current = patient.record else {
            throw issue("patient.registration_required", patient.patientID, "O paciente opaco não pode ser editado neste corte.")
        }
        let targetStatus = status ?? current.status
        let timestamp = patientTimestamp(updatedAt)
        let normalized = input.normalized()
        let updated = PatientRecord(
            schema: current.schema,
            patientID: current.patientID,
            status: targetStatus,
            fullName: normalized.fullName.isEmpty ? nil : normalized.fullName,
            preferredName: normalized.preferredName,
            birthDate: normalized.birthDate,
            contacts: normalized.contacts,
            identifiers: normalized.identifiers,
            alerts: normalized.alerts,
            createdAt: current.createdAt,
            updatedAt: timestamp,
            archivedAt: targetStatus == .archived ? (current.archivedAt ?? timestamp) : nil,
            extensions: current.extensions.merging(
                normalized.registration.map { ["x_openpep_registration": YAMLValue.mapping($0)] } ?? [:],
                uniquingKeysWith: { _, new in new }
            )
        )
        let manifestURL = patient.url.appending(path: PatientLayout.manifest)
        var outcome: Result<PatientRecord, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: manifestURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedManifest in
            do {
                outcome = .success(try updateUncoordinated(
                    updated,
                    at: coordinatedManifest,
                    expectedRecord: current
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", manifestURL.path, "A edição coordenada não foi concluída.")
        }
        let saved = try outcome.get()
        PatientClinicalChange.post(for: patient)
        return saved
    }

    func restoreStatus(
        patient: PatientSummary,
        expectedCurrentRecord: PatientRecord,
        previousStatus: PatientStatus,
        restoredAt: Date = Date()
    ) throws -> PatientRecord {
        guard patient.record == expectedCurrentRecord,
              expectedCurrentRecord.patientID == patient.patientID,
              expectedCurrentRecord.status == .archived,
              expectedCurrentRecord.archivedAt != nil,
              previousStatus == .active else {
            throw issue(
                "patient.restore_status",
                patient.patientID,
                "Somente o arquivamento atual de um paciente ativo pode ser desfeito."
            )
        }
        let restored = PatientRecord(
            schema: expectedCurrentRecord.schema,
            patientID: expectedCurrentRecord.patientID,
            status: previousStatus,
            fullName: expectedCurrentRecord.fullName,
            preferredName: expectedCurrentRecord.preferredName,
            birthDate: expectedCurrentRecord.birthDate,
            contacts: expectedCurrentRecord.contacts,
            identifiers: expectedCurrentRecord.identifiers,
            alerts: expectedCurrentRecord.alerts,
            createdAt: expectedCurrentRecord.createdAt,
            updatedAt: patientTimestamp(restoredAt),
            archivedAt: nil,
            extensions: expectedCurrentRecord.extensions
        )
        let manifestURL = patient.url.appending(path: PatientLayout.manifest)
        var outcome: Result<PatientRecord, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: manifestURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedManifest in
            do {
                outcome = .success(try updateUncoordinated(
                    restored,
                    at: coordinatedManifest,
                    expectedRecord: expectedCurrentRecord
                ))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", manifestURL.path, "A restauração coordenada não foi concluída.")
        }
        let saved = try outcome.get()
        PatientClinicalChange.post(for: patient)
        return saved
    }

    private func updateUncoordinated(
        _ record: PatientRecord,
        at manifestURL: URL,
        expectedRecord: PatientRecord
    ) throws -> PatientRecord {
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw issue("filesystem.regular_file", manifestURL.path, "patient.yaml deve ser arquivo regular sem link simbólico.")
        }
        try requireExpectedRecord(expectedRecord, at: manifestURL)
        let data = try PatientRecordCodec.encode(record)
        let validated = try VaultManifestValidator.validatePatient(data: data)
        let temporary = manifestURL.deletingLastPathComponent().appending(
            path: ".openpep-patient-\(UUID().uuidString.lowercased()).yaml"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        try faultInjector?(.temporaryManifestWritten)
        try requireExpectedRecord(expectedRecord, at: manifestURL)
        _ = try fileManager.replaceItemAt(manifestURL, withItemAt: temporary)
        let reopened = try VaultManifestValidator.validatePatient(
            data: Data(contentsOf: manifestURL),
            source: manifestURL.path
        )
        guard reopened == validated else {
            throw issue("patient.reopen_mismatch", manifestURL.path, "O cadastro reaberto diverge da escrita validada.")
        }
        return reopened
    }

    private func requireExpectedRecord(_ expected: PatientRecord, at manifestURL: URL) throws {
        let live = try VaultManifestValidator.validatePatient(
            data: Data(contentsOf: manifestURL),
            source: manifestURL.path
        )
        guard live == expected else {
            throw issue(
                "patient.revision_conflict",
                manifestURL.path,
                "O cadastro mudou desde a última leitura. Reabra antes de salvar."
            )
        }
    }
}

enum PatientRecordCodec {
    static func encode(_ record: PatientRecord) throws -> Data {
        var lines = [
            "schema: openpep/patient@1",
            "patient_id: \(record.patientID)",
            "status: \(record.status.rawValue)",
            "full_name: \(try optionalScalar(record.fullName))",
            "preferred_name: \(try optionalScalar(record.preferredName))",
            "birth_date: \(try optionalScalar(record.birthDate))",
        ]
        try appendContacts(record.contacts, to: &lines)
        try appendIdentifiers(record.identifiers, to: &lines)
        try appendAlerts(record.alerts, to: &lines)
        lines.append("created_at: \(try scalar(record.createdAt))")
        lines.append("updated_at: \(try scalar(record.updatedAt))")
        lines.append("archived_at: \(try optionalScalar(record.archivedAt))")
        for key in record.extensions.keys.sorted() {
            guard let value = record.extensions[key] else { continue }
            lines.append("\(key): \(try jsonScalar(value))")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func appendContacts(_ contacts: [PatientContact], to lines: inout [String]) throws {
        guard !contacts.isEmpty else { lines.append("contacts: []"); return }
        lines.append("contacts:")
        for contact in contacts {
            lines.append("  - type: \(contact.type.rawValue)")
            lines.append("    value: \(try scalar(contact.value))")
            lines.append("    authorized_for_care: \(contact.authorizedForCare)")
        }
    }

    private static func appendIdentifiers(_ identifiers: [PatientIdentifier], to lines: inout [String]) throws {
        guard !identifiers.isEmpty else { lines.append("identifiers: []"); return }
        lines.append("identifiers:")
        for identifier in identifiers {
            lines.append("  - type: \(identifier.type.rawValue)")
            lines.append("    value: \(try scalar(identifier.value))")
        }
    }

    private static func appendAlerts(_ alerts: [PatientAlert], to lines: inout [String]) throws {
        guard !alerts.isEmpty else { lines.append("alerts: []"); return }
        lines.append("alerts:")
        for alert in alerts {
            lines.append("  - type: \(alert.type.rawValue)")
            lines.append("    description: \(try scalar(alert.description))")
            lines.append("    source: \(try scalar(alert.source))")
            lines.append("    recorded_at: \(try scalar(alert.recordedAt))")
        }
    }

    private static func optionalScalar(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try scalar(value)
    }

    private static func scalar(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw issue("patient.encoding", "/", "O texto não pôde ser codificado.")
        }
        return encoded
    }

    private static func jsonScalar(_ value: YAMLValue) throws -> String {
        let object = foundationValue(value)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw issue("patient.encoding", "/", "A extensão não pôde ser codificada.")
        }
        return encoded
    }

    private static func foundationValue(_ value: YAMLValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .boolean(value): value
        case let .integer(value): value
        case let .string(value): value
        case let .sequence(value): value.map(foundationValue)
        case let .mapping(value): value.mapValues(foundationValue)
        }
    }
}

private func patientTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

struct RawAssetCreationIdentity: Equatable, Sendable, Codable {
    let assetID: String

    static func generate(at date: Date = Date()) throws -> RawAssetCreationIdentity {
        RawAssetCreationIdentity(assetID: "asset_\(try UUIDv7.generate(at: date))")
    }
}

struct RawAssetImportResult: Equatable, Sendable {
    let assetID: String
    let originalURL: URL
    let sidecarURL: URL
    let sha256: String
}

enum RawAssetImportStep: Equatable, Sendable {
    case temporaryFilesWritten
    case originalPublished
}

struct RawAssetImporter {
    typealias FaultInjector = (RawAssetImportStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func importFixture(
        from sourceURL: URL,
        into patient: PatientSummary,
        deviceID: String,
        identity: RawAssetCreationIdentity,
        importedAt: Date
    ) throws -> RawAssetImportResult {
        guard OpenPEPIdentifier.isPatient(patient.patientID) else {
            throw issue("patient.invalid_id", patient.patientID, "O patient_id não é seguro.")
        }
        guard OpenPEPIdentifier.isAsset(identity.assetID) else {
            throw issue("raw_asset.invalid_id", identity.assetID, "O asset_id não é seguro.")
        }

        let rawURL = patient.url.appending(path: "raw", directoryHint: .isDirectory)
        var outcome: Result<RawAssetImportResult, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            writingItemAt: rawURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedSource, coordinatedRaw in
            do {
                outcome = .success(try importUncoordinated(
                    from: coordinatedSource,
                    into: coordinatedRaw,
                    patientID: patient.patientID,
                    deviceID: deviceID,
                    identity: identity,
                    importedAt: importedAt
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw issue("filesystem.coordination", rawURL.path, "A importação coordenada não foi concluída.")
        }
        return try outcome.get()
    }

    private func importUncoordinated(
        from sourceURL: URL,
        into rawURL: URL,
        patientID: String,
        deviceID: String,
        identity: RawAssetCreationIdentity,
        importedAt: Date
    ) throws -> RawAssetImportResult {
        let rawValues = try rawURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rawValues.isDirectory == true, rawValues.isSymbolicLink != true else {
            throw issue("filesystem.directory", rawURL.path, "raw deve ser um diretório sem link simbólico.")
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        try validateFixture(data: data, sourceURL: sourceURL)

        let components = utcDateComponents(importedAt)
        let yearURL = rawURL.appending(path: components.year, directoryHint: .isDirectory)
        let monthURL = yearURL.appending(path: components.month, directoryHint: .isDirectory)
        let originalName = "\(identity.assetID).txt"
        let sidecarName = "\(identity.assetID).meta.md"
        let originalURL = monthURL.appending(path: originalName, directoryHint: .notDirectory)
        let sidecarURL = monthURL.appending(path: sidecarName, directoryHint: .notDirectory)
        guard !fileManager.fileExists(atPath: originalURL.path),
              !fileManager.fileExists(atPath: sidecarURL.path) else {
            throw issue("raw_asset.destination_exists", identity.assetID, "O arquivo de destino já existe.")
        }

        let temporary = rawURL.appending(
            path: ".openpep-import-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let temporaryOriginal = temporary.appending(path: originalName, directoryHint: .notDirectory)
        let temporarySidecar = temporary.appending(path: sidecarName, directoryHint: .notDirectory)
        var originalPublished = false
        var sidecarPublished = false
        defer {
            if !sidecarPublished, fileManager.fileExists(atPath: sidecarURL.path) {
                try? fileManager.removeItem(at: sidecarURL)
            }
            if !originalPublished || !sidecarPublished,
               fileManager.fileExists(atPath: originalURL.path) {
                try? fileManager.removeItem(at: originalURL)
            }
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        try data.write(to: temporaryOriginal, options: [.withoutOverwriting])
        let sidecar = sidecarText(
            patientID: patientID,
            deviceID: deviceID,
            assetID: identity.assetID,
            importedAt: importedAt
        )
        let sidecarData = Data(sidecar.utf8)
        try sidecarData.write(to: temporarySidecar, options: [.withoutOverwriting])
        _ = try VaultManifestValidator.validateRawAssetSidecar(data: sidecarData)
        try requireHash(of: temporaryOriginal, equals: SyntheticRawFixtureContract.sha256)
        try faultInjector?(.temporaryFilesWritten)

        try fileManager.createDirectory(at: monthURL, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: originalURL.path),
              !fileManager.fileExists(atPath: sidecarURL.path) else {
            throw issue("raw_asset.destination_exists", identity.assetID, "O arquivo de destino já existe.")
        }
        try fileManager.moveItem(at: temporaryOriginal, to: originalURL)
        originalPublished = true
        try faultInjector?(.originalPublished)
        try fileManager.moveItem(at: temporarySidecar, to: sidecarURL)
        sidecarPublished = true

        try requireHash(of: originalURL, equals: SyntheticRawFixtureContract.sha256)
        _ = try VaultManifestValidator.validateRawAssetSidecar(
            data: Data(contentsOf: sidecarURL),
            source: sidecarURL.path
        )
        return RawAssetImportResult(
            assetID: identity.assetID,
            originalURL: originalURL,
            sidecarURL: sidecarURL,
            sha256: SyntheticRawFixtureContract.sha256
        )
    }

    private func validateFixture(data: Data, sourceURL: URL) throws {
        guard sourceURL.lastPathComponent == SyntheticRawFixtureContract.fileName,
              sourceURL.pathExtension == "txt" else {
            throw issue("raw_asset.fixture_name", sourceURL.lastPathComponent, "A entrada não é a fixture autorizada.")
        }
        guard data.count == SyntheticRawFixtureContract.sizeBytes,
              String(data: data, encoding: .utf8)?.hasPrefix(SyntheticRawFixtureContract.marker) == true,
              sha256(data) == SyntheticRawFixtureContract.sha256 else {
            throw issue("raw_asset.fixture_mismatch", sourceURL.lastPathComponent, "Os bytes não correspondem à fixture sintética.")
        }
    }

    private func sidecarText(
        patientID: String,
        deviceID: String,
        assetID: String,
        importedAt: Date
    ) -> String {
        """
        ---
        schema: openpep/raw-asset@1
        asset_id: \(assetID)
        patient_id: \(patientID)
        encounter_id: null
        media_type: text/plain
        file_extension: txt
        original_name: \(SyntheticRawFixtureContract.fileName)
        size_bytes: \(SyntheticRawFixtureContract.sizeBytes)
        sha256: \(SyntheticRawFixtureContract.sha256)
        source: file_import
        actor_id: null
        device_id: \(deviceID)
        imported_at: "\(utcTimestamp(importedAt))"
        quarantine_state: not_required_synthetic_fixture
        inspection_result: exact_fixture_match
        ---
        """ + "\n"
    }

    private func utcDateComponents(_ date: Date) -> (year: String, month: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return (
            String(format: "%04d", components.year!),
            String(format: "%02d", components.month!)
        )
    }

    private func utcTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func requireHash(of url: URL, equals expected: String) throws {
        let actual = sha256(try Data(contentsOf: url, options: [.mappedIfSafe]))
        guard actual == expected else {
            throw issue("raw_asset.hash_mismatch", url.lastPathComponent, "O SHA-256 do original diverge do sidecar.")
        }
    }
}

struct PatientVaultInspector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspect(
        vaultURL: URL,
        deviceID: String,
        allowsGeneratedDemoAssets: Bool = false
    ) -> PatientInspection {
        do {
            let patientsRoot = vaultURL.appending(path: "patients", directoryHint: .isDirectory)
            try requireDirectory(patientsRoot)
            let patientURLs = try children(of: patientsRoot)
            var patients: [PatientSummary] = []
            var unavailablePatients: [UnavailablePatientSummary] = []
            for patientURL in patientURLs {
                do {
                    patients.append(try inspectPatient(
                        patientURL,
                        deviceID: deviceID,
                        allowsGeneratedDemoAssets: allowsGeneratedDemoAssets
                    ))
                } catch let validationIssue as VaultValidationIssue {
                    let candidateID = patientURL.lastPathComponent
                    unavailablePatients.append(UnavailablePatientSummary(
                        patientID: OpenPEPIdentifier.isPatient(candidateID) ? candidateID : nil,
                        relativePath: "patients/\(candidateID)",
                        rule: validationIssue.rule
                    ))
                } catch {
                    unavailablePatients.append(UnavailablePatientSummary(
                        patientID: nil,
                        relativePath: "patients/\(patientURL.lastPathComponent)",
                        rule: "filesystem.unreadable"
                    ))
                }
            }
            patients.sort { $0.patientID < $1.patientID }
            unavailablePatients.sort { $0.relativePath < $1.relativePath }
            let statusMessage = unavailablePatients.isEmpty
                ? nil
                : "\(unavailablePatients.count) paciente(s) indisponível(is); os pacientes válidos permanecem acessíveis."
            return PatientInspection(
                patients: patients,
                unavailablePatients: unavailablePatients,
                writingAllowed: true,
                statusMessage: statusMessage
            )
        } catch {
            return PatientInspection(
                patients: [],
                unavailablePatients: [],
                writingAllowed: false,
                statusMessage: "O contêiner de pacientes não pôde ser inspecionado. Escrita bloqueada no vault."
            )
        }
    }

    private func inspectPatient(
        _ patientURL: URL,
        deviceID: String,
        allowsGeneratedDemoAssets: Bool
    ) throws -> PatientSummary {
        try requireDirectory(patientURL)
        let patientID = patientURL.lastPathComponent
        guard OpenPEPIdentifier.isPatient(patientID) else {
            throw issue("patient.invalid_id", patientID, "O diretório de paciente não usa um ID válido.")
        }

        let entries = try children(of: patientURL)
        let entryNames = Set(entries.map(\.lastPathComponent))
        let allowedEntries = Set(PatientLayout.directories + [PatientLayout.manifest])
        guard Set(PatientLayout.directories).isSubset(of: entryNames), entryNames.isSubset(of: allowedEntries) else {
            throw issue("patient.layout", patientID, "A estrutura do paciente não corresponde ao MAC-002.")
        }
        for relativePath in PatientLayout.directories {
            try requireDirectory(patientURL.appending(path: relativePath, directoryHint: .isDirectory))
        }
        let internalURL = patientURL.appending(path: ".openpep", directoryHint: .isDirectory)
        let internalEntries = try children(of: internalURL)
        let internalNames = Set(internalEntries.map(\.lastPathComponent))
        let allowedInternalNames = Set([DemoCatalogReader.directoryMarkerName, "audit.ndjson"])
        guard internalNames.isSubset(of: allowedInternalNames) else {
            throw issue("patient.unsupported_content", ".openpep", "O diretório contém dados fora deste corte.")
        }
        for entry in internalEntries { try requireRegularFile(entry) }
        if internalNames.contains(DemoCatalogReader.directoryMarkerName) {
            guard allowsGeneratedDemoAssets,
                  try Data(contentsOf: internalURL.appending(path: DemoCatalogReader.directoryMarkerName))
                    == DemoCatalogReader.directoryMarkerData else {
                throw issue("patient.unsupported_content", ".openpep", "O marcador demonstrativo não é válido neste vault.")
            }
        }

        let manifestURL = patientURL.appending(path: PatientLayout.manifest)
        let record: PatientRecord?
        if fileManager.fileExists(atPath: manifestURL.path) {
            try requireRegularFile(manifestURL)
            let candidate = try VaultManifestValidator.validatePatient(
                data: Data(contentsOf: manifestURL),
                source: manifestURL.path
            )
            guard candidate.patientID == patientID else {
                throw issue("patient.patient_id_mismatch", "/patient_id", "O patient_id diverge do diretório.")
            }
            record = candidate
        } else {
            record = nil
        }

        let allEncounters = try ClinicalContentInspector(fileManager: fileManager).inspect(
            contentURL: patientURL.appending(path: "content", directoryHint: .isDirectory),
            patientID: patientID
        )
        let rawURL = patientURL.appending(path: "raw", directoryHint: .isDirectory)
        let allRawAssets = try inspectRaw(
            rawURL,
            patientID: patientID,
            deviceID: deviceID,
            encounterIDs: Set(allEncounters.map(\.metadata.encounterID)),
            allowsGeneratedDemoAssets: allowsGeneratedDemoAssets
        )
        for encounter in allEncounters {
            try ClinicalDocumentValidator.bindAISource(
                draft: encounter.draft.metadata,
                encounterID: encounter.metadata.encounterID,
                assets: allRawAssets
            )
        }
        let trashedEncounterIDs = Set(allEncounters.compactMap { encounter in
            encounter.metadata.trashedAt != nil && encounter.finalizationStatus == .draft
                ? encounter.metadata.encounterID
                : nil
        })
        let encounters = allEncounters.filter { !trashedEncounterIDs.contains($0.metadata.encounterID) }
        let trashedEncounters = allEncounters.filter { trashedEncounterIDs.contains($0.metadata.encounterID) }
        let rawAssets = allRawAssets.filter { asset in
            asset.encounterID.map(trashedEncounterIDs.contains) != true
        }
        let trashedRawAssets = allRawAssets.filter { asset in
            asset.encounterID.map(trashedEncounterIDs.contains) == true
        }
        return PatientSummary(
            patientID: patientID,
            url: patientURL,
            record: record,
            rawAssets: rawAssets,
            encounters: encounters,
            trashedRawAssets: trashedRawAssets,
            trashedEncounters: trashedEncounters
        )
    }

    private func inspectRaw(
        _ rawURL: URL,
        patientID: String,
        deviceID: String,
        encounterIDs: Set<String>,
        allowsGeneratedDemoAssets: Bool
    ) throws -> [RawAssetSummary] {
        var assets: [RawAssetSummary] = []
        for yearURL in try children(of: rawURL) {
            try requireDirectory(yearURL)
            guard yearURL.lastPathComponent.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else {
                throw issue("raw_asset.year", yearURL.lastPathComponent, "O ano do caminho é inválido.")
            }
            for monthURL in try children(of: yearURL) {
                try requireDirectory(monthURL)
                let month = monthURL.lastPathComponent
                guard let monthNumber = Int(month), (1...12).contains(monthNumber), month.count == 2 else {
                    throw issue("raw_asset.month", month, "O mês do caminho é inválido.")
                }
                assets.append(contentsOf: try inspectMonth(
                    monthURL,
                    year: yearURL.lastPathComponent,
                    month: month,
                    patientID: patientID,
                    deviceID: deviceID,
                    encounterIDs: encounterIDs,
                    allowsGeneratedDemoAssets: allowsGeneratedDemoAssets
                ))
            }
        }
        return assets.sorted { $0.importedAt < $1.importedAt }
    }

    private func inspectMonth(
        _ monthURL: URL,
        year: String,
        month: String,
        patientID: String,
        deviceID: String,
        encounterIDs: Set<String>,
        allowsGeneratedDemoAssets: Bool
    ) throws -> [RawAssetSummary] {
        let entries = try children(of: monthURL)
        let sidecars = entries.filter { $0.lastPathComponent.hasSuffix(".meta.md") }
        let originals = entries.filter { !$0.lastPathComponent.hasSuffix(".meta.md") }
        guard entries.count == originals.count + sidecars.count,
              originals.count == sidecars.count else {
            throw issue("raw_asset.pair", monthURL.path, "Original e sidecar devem formar pares completos.")
        }

        var summaries: [RawAssetSummary] = []
        for originalURL in originals {
            try requireRegularFile(originalURL)
            let assetID = originalURL.deletingPathExtension().lastPathComponent
            guard OpenPEPIdentifier.isAsset(assetID) else {
                throw issue("raw_asset.invalid_id", assetID, "O nome do arquivo não usa um asset_id válido.")
            }
            let sidecarURL = monthURL.appending(path: "\(assetID).meta.md", directoryHint: .notDirectory)
            try requireRegularFile(sidecarURL)
            let metadata = try VaultManifestValidator.validateRawAssetSidecar(
                data: Data(contentsOf: sidecarURL),
                source: sidecarURL.path
            )
            guard metadata.assetID == assetID,
                  metadata.patientID == patientID,
                  metadata.deviceID == deviceID,
                  metadata.encounterID.map(encounterIDs.contains) ?? true,
                  metadata.fileExtension == originalURL.pathExtension.lowercased(),
                  metadata.importedAt.hasPrefix("\(year)-\(month)-"),
                  fileManager.fileExists(atPath: originalURL.path),
                  (try Data(contentsOf: originalURL).count) == metadata.sizeBytes,
                  sha256(try Data(contentsOf: originalURL, options: [.mappedIfSafe])) == metadata.sha256 else {
                throw issue("raw_asset.binding", assetID, "O original e o sidecar não correspondem.")
            }
            if metadata.inspectionResult == "generated_demo_fixture" {
                guard allowsGeneratedDemoAssets else {
                    throw issue("raw_asset.demo_profile", assetID, "O arquivo demonstrativo exige o catálogo correspondente.")
                }
                let data = try Data(contentsOf: originalURL, options: [.mappedIfSafe])
                if metadata.mediaType == "application/pdf" {
                    guard data.starts(with: Data("%PDF-".utf8)) else {
                        throw issue("raw_asset.pdf_header", assetID, "O PDF demonstrativo não possui cabeçalho válido.")
                    }
                } else {
                    guard let text = String(data: data, encoding: .utf8),
                          text.hasPrefix(DemoCatalogReader.disclaimer) else {
                        throw issue("raw_asset.demo_marker", assetID, "A transcrição não possui o marcador sintético.")
                    }
                }
            }
            summaries.append(RawAssetSummary(
                assetID: metadata.assetID,
                encounterID: metadata.encounterID,
                originalName: metadata.originalName,
                importedAt: metadata.importedAt,
                mediaType: metadata.mediaType,
                fileExtension: metadata.fileExtension,
                sizeBytes: metadata.sizeBytes,
                sha256: metadata.sha256,
                source: metadata.source,
                inspectionResult: metadata.inspectionResult,
                originalURL: originalURL
            ))
        }
        return summaries
    }

    private func children(of directory: URL) throws -> [URL] {
        try managedDirectoryEntries(in: directory, fileManager: fileManager)
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw issue("filesystem.directory", url.path, "Era esperado um diretório sem link simbólico.")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw issue("filesystem.regular_file", url.path, "Era esperado um arquivo regular.")
        }
    }
}

func managedDirectoryEntries(
    in directory: URL,
    fileManager: FileManager = .default
) throws -> [URL] {
    let entries = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    return try entries.filter { entry in
        guard entry.lastPathComponent == ".DS_Store" else { return true }
        let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile != true || values.isSymbolicLink == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func issue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
