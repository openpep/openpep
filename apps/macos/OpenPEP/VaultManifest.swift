// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Yams

enum YAMLValue: Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int)
    case string(String)
    case sequence([YAMLValue])
    case mapping([String: YAMLValue])
}

struct VaultManifest: Equatable, Sendable {
    let schema: String
    let vaultID: String
    let createdAt: String
    let protocolVersion: String
    let deviceID: String
    let storageMode: String
    let encryptionMode: String
    let hashAlgorithm: String
    let eventCanonicalization: String
}

struct OperationsManifest: Equatable, Sendable {
    let schema: String
    let vaultID: String
    let state: String
}

enum PatientStatus: String, Equatable, Sendable {
    case active
    case archived
}

enum PatientContactType: String, Equatable, Sendable, CaseIterable {
    case phone
    case email
}

struct PatientContact: Equatable, Sendable, Identifiable {
    let type: PatientContactType
    let value: String
    let authorizedForCare: Bool

    var id: String { "\(type.rawValue):\(value)" }
}

enum PatientIdentifierType: String, Equatable, Sendable, CaseIterable {
    case cpf
    case other
}

struct PatientIdentifier: Equatable, Sendable, Identifiable {
    let type: PatientIdentifierType
    let value: String

    var id: String { "\(type.rawValue):\(value)" }
}

enum PatientAlertType: String, Equatable, Sendable, CaseIterable {
    case allergy
    case critical
}

struct PatientAlert: Equatable, Sendable, Identifiable {
    let type: PatientAlertType
    let description: String
    let source: String
    let recordedAt: String

    var id: String { "\(type.rawValue):\(recordedAt):\(description)" }
}

struct PatientRecord: Equatable, Sendable {
    let schema: String
    let patientID: String
    let status: PatientStatus
    let fullName: String?
    let preferredName: String?
    let birthDate: String?
    let contacts: [PatientContact]
    let identifiers: [PatientIdentifier]
    let alerts: [PatientAlert]
    let createdAt: String
    let updatedAt: String
    let archivedAt: String?
    let extensions: [String: YAMLValue]
}

struct RawAssetMetadata: Equatable, Sendable {
    let schema: String
    let assetID: String
    let patientID: String
    let encounterID: String?
    let mediaType: String
    let fileExtension: String
    let originalName: String
    let sizeBytes: Int
    let sha256: String
    let source: String
    let deviceID: String
    let importedAt: String
    let quarantineState: String
    let inspectionResult: String
    let extensions: [String: YAMLValue]
}

struct MarkdownFrontmatterDocument: Equatable, Sendable {
    let metadata: YAMLValue
    let frontmatter: String
    let body: String
}

struct VaultValidationIssue: Error, Equatable, LocalizedError, Sendable {
    let rule: String
    let path: String
    let message: String

    var errorDescription: String? {
        "\(message) [\(rule) em \(path)]"
    }
}

enum VaultManifestValidator {
    static let maximumBytes = 256 * 1024
    static let maximumDepth = 12

    private static let keyPattern = "^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"
    private static let vaultIDPattern =
        "^vlt_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let deviceIDPattern =
        "^dev_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let patientIDPattern =
        "^pt_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let appointmentIDPattern =
        "^appt_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let encounterIDPattern =
        "^enc_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let assetIDPattern =
        "^asset_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    private static let sha256Pattern = "^[0-9a-f]{64}$"
    private static let integerPattern = "^[+-]?(?:0|[1-9][0-9]*)$"
    private static let floatPattern =
        "^[+-]?(?:(?:[0-9][0-9_]*\\.[0-9_]*|[0-9][0-9_]*[eE][+-]?[0-9]+|\\.[0-9_]+)(?:[eE][+-]?[0-9]+)?|\\.(?:inf|Inf|INF|nan|NaN|NAN))$"

    static func validate(data: Data, source: String = "vault.yaml") throws -> VaultManifest {
        try validateSchema(parse(data: data, source: source))
    }

    static func validateOperations(
        data: Data,
        source: String = "operations/manifest.yaml"
    ) throws -> OperationsManifest {
        try validateOperationsSchema(parse(data: data, source: source))
    }

    static func validatePatient(
        data: Data,
        source: String = "patient.yaml"
    ) throws -> PatientRecord {
        try validatePatientSchema(parse(data: data, source: source))
    }

    static func validateAppointment(
        data: Data,
        source: String = "appointment.yaml"
    ) throws -> AppointmentRecord {
        try validateAppointmentSchema(parse(data: data, source: source))
    }

    static func validateRawAssetSidecar(
        data: Data,
        source: String = "asset.meta.md"
    ) throws -> RawAssetMetadata {
        guard data.count <= maximumBytes else {
            throw issue("yaml.maximum_size", "/", "O sidecar excede \(maximumBytes) bytes.")
        }
        guard !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0x0d }),
              text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.utf8),
              text.hasPrefix("---\n"),
              text.hasSuffix("---\n") else {
            throw issue(
                "raw_asset.frontmatter",
                "/",
                "O sidecar deve conter somente frontmatter YAML em UTF-8, NFC e LF."
            )
        }

        let yaml = String(text.dropFirst(4).dropLast(4))
        return try validateRawAssetSchema(parse(data: Data(yaml.utf8), source: source))
    }

    static func parseMarkdownDocument(
        data: Data,
        source: String
    ) throws -> MarkdownFrontmatterDocument {
        guard !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0x0d }),
              text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.utf8),
              text.hasPrefix("---\n") else {
            throw issue(
                "clinical_document.frontmatter",
                "/",
                "O documento deve usar frontmatter, UTF-8, NFC e LF."
            )
        }

        let contentStart = text.index(text.startIndex, offsetBy: 4)
        guard let closing = text.range(of: "---\n", range: contentStart..<text.endIndex),
              closing.lowerBound == contentStart || text[text.index(before: closing.lowerBound)] == "\n" else {
            throw issue(
                "clinical_document.frontmatter",
                "/",
                "O frontmatter não possui delimitador final."
            )
        }

        let frontmatter = String(text[contentStart..<closing.lowerBound])
        return MarkdownFrontmatterDocument(
            metadata: try parse(data: Data(frontmatter.utf8), source: source),
            frontmatter: frontmatter,
            body: String(text[closing.upperBound...])
        )
    }

    private static func parse(data: Data, source: String) throws -> YAMLValue {
        guard data.count <= maximumBytes else {
            throw issue("yaml.maximum_size", "/", "O YAML excede \(maximumBytes) bytes.")
        }
        guard !data.starts(with: [0xef, 0xbb, 0xbf]) else {
            throw issue("yaml.bom", "/", "UTF-8 BOM não é permitido.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw issue("yaml.utf8", "/", "O arquivo não contém UTF-8 válido.")
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0x0d }) else {
            throw issue("yaml.line_endings", "/", "Somente quebras de linha LF são permitidas.")
        }
        guard text.precomposedStringWithCanonicalMapping.utf8.elementsEqual(text.utf8) else {
            throw issue("yaml.unicode_nfc", "/", "O texto deve usar Unicode NFC.")
        }

        let syntaxIssues = inspectForbiddenSyntax(in: text)
        if let syntaxIssue = syntaxIssues.first(where: { $0.rule == "yaml.alias" })
            ?? syntaxIssues.first(where: { $0.rule == "yaml.anchor" })
            ?? syntaxIssues.first(where: { $0.rule == "yaml.tag" }) {
            throw syntaxIssue
        }

        let root = try parseRoot(text: text, source: source)
        return try normalize(root, path: "/", depth: 1)
    }

    private static func parseRoot(text: String, source: String) throws -> Node {
        do {
            var documents = try Yams.compose_all(yaml: text, Resolver.basic)
            guard let root = documents.next() else {
                if let error = documents.error {
                    throw error
                }
                throw issue("yaml.syntax.empty", "/", "O YAML está vazio.")
            }
            if documents.next() != nil {
                throw issue("yaml.syntax.multiple_docs", "/", "Somente um documento YAML é permitido.")
            }
            if let error = documents.error {
                throw error
            }
            _ = source
            return root
        } catch let error as VaultValidationIssue {
            throw error
        } catch let error as YamlError {
            if case let .duplicatedKeysInMapping(_, context) = error {
                let position = duplicateKeyPosition(in: text)
                throw issue(
                    "yaml.syntax.duplicate_key",
                    position.map { "line:\($0.line):column:\($0.column)" }
                        ?? "line:\(context.mark.line):column:\(context.mark.column)",
                    "O YAML contém chave duplicada."
                )
            }
            throw issue("yaml.syntax.parse", "/", "O YAML não pôde ser analisado.")
        } catch {
            throw issue("yaml.syntax.parse", "/", "O YAML não pôde ser analisado.")
        }
    }

    private struct MappingFrame {
        let indentation: Int
        let path: String
    }

    private static func inspectForbiddenSyntax(in text: String) -> [VaultValidationIssue] {
        var issues: [VaultValidationIssue] = []
        var frames: [MappingFrame] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let content = prefixBeforeComment(in: line)
            let indentation = content.prefix(while: { $0 == " " }).count
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            while let last = frames.last, last.indentation >= indentation {
                frames.removeLast()
            }

            let parentPath = frames.last?.path ?? "/"
            var itemPath = parentPath
            var value = trimmed
            if let separator = mappingSeparator(in: trimmed) {
                var key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("- ") {
                    key.removeFirst(2)
                }
                itemPath = append(parentPath, unquote(key))
                value = String(trimmed[trimmed.index(after: separator)...])
                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    frames.append(MappingFrame(indentation: indentation, path: itemPath))
                }
            }

            for indicator in forbiddenIndicators(in: value) {
                switch indicator {
                case "*":
                    issues.append(issue("yaml.alias", itemPath, "Aliases YAML não são permitidos."))
                case "&":
                    issues.append(issue("yaml.anchor", itemPath, "Anchors YAML não são permitidos."))
                case "!":
                    issues.append(issue("yaml.tag", itemPath, "Tags YAML explícitas não são permitidas."))
                default:
                    break
                }
            }
        }

        return issues
    }

    private static func duplicateKeyPosition(in text: String) -> (line: Int, column: Int)? {
        var frames: [MappingFrame] = []
        var keysByParent: [String: Set<String>] = [:]

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let content = prefixBeforeComment(in: line)
            let indentation = content.prefix(while: { $0 == " " }).count
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let separator = mappingSeparator(in: trimmed) else { continue }

            while let last = frames.last, last.indentation >= indentation {
                frames.removeLast()
            }
            let parentPath = frames.last?.path ?? "/"
            var key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("- ") {
                key.removeFirst(2)
            }
            key = unquote(key)
            if keysByParent[parentPath, default: []].contains(key) {
                return (offset + 1, indentation + 1)
            }
            keysByParent[parentPath, default: []].insert(key)

            let value = trimmed[trimmed.index(after: separator)...]
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                frames.append(MappingFrame(indentation: indentation, path: append(parentPath, key)))
            }
        }

        return nil
    }

    private static func mappingSeparator(in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if quote == "\"", escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if quote == nil, character == ":" {
                return index
            }
        }
        return nil
    }

    private static func prefixBeforeComment(in text: String) -> String {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if quote == "\"", escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if quote == nil,
               character == "#",
               index == text.startIndex || text[text.index(before: index)].isWhitespace {
                return String(text[..<index])
            }
        }
        return text
    }

    private static func forbiddenIndicators(in text: String) -> [Character] {
        var result: [Character] = []
        var quote: Character?
        var escaped = false
        var previous: Character?
        let tokenBoundaries = " [{,:\t"

        for character in text {
            if quote == "\"", escaped {
                escaped = false
                previous = character
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                previous = character
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                previous = character
                continue
            }
            if quote == nil,
               character == "*" || character == "&" || character == "!",
               previous == nil || tokenBoundaries.contains(previous!) {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    private static func normalize(_ node: Node, path: String, depth: Int) throws -> YAMLValue {
        let isCollection = node.mapping != nil || node.sequence != nil
        if isCollection && depth > maximumDepth {
            throw issue("yaml.maximum_depth", path, "A profundidade máxima é \(maximumDepth).")
        }

        switch node {
        case .alias:
            throw issue("yaml.alias", path, "Aliases YAML não são permitidos.")
        case let .scalar(scalar):
            return try normalizeScalar(scalar, path: path)
        case let .sequence(sequence):
            return .sequence(try sequence.enumerated().map { index, item in
                try normalize(item, path: append(path, String(index)), depth: depth + 1)
            })
        case let .mapping(mapping):
            var result: [String: YAMLValue] = [:]
            for (index, pair) in mapping.enumerated() {
                guard case let .scalar(keyNode) = pair.key else {
                    throw issue("yaml.string_key", append(path, "<key:\(index)>"), "Todas as chaves devem ser strings.")
                }
                let key = keyNode.string
                let itemPath = append(path, key)
                if key == "<<" {
                    throw issue("yaml.merge_key", itemPath, "Merge keys YAML não são permitidas.")
                }
                guard matches(key, pattern: keyPattern) else {
                    throw issue("yaml.key_format", itemPath, "Chaves devem usar ASCII snake_case.")
                }
                result[key] = try normalize(pair.value, path: itemPath, depth: depth + 1)
            }
            return .mapping(result)
        }
    }

    private static func normalizeScalar(_ scalar: Node.Scalar, path: String) throws -> YAMLValue {
        let text = scalar.string
        guard scalar.style == .plain else {
            return .string(text)
        }
        switch text {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "null": return .null
        default: break
        }
        if matches(text, pattern: floatPattern) {
            throw issue("yaml.float", path, "Números de ponto flutuante não são permitidos.")
        }
        if matches(text, pattern: integerPattern), let integer = Int(text) {
            return .integer(integer)
        }
        return .string(text)
    }

    private static func validateSchema(_ value: YAMLValue) throws -> VaultManifest {
        guard case let .mapping(root) = value else {
            throw issue("schema.type", "/", "O manifesto deve ser um mapa.")
        }

        let rootFields = [
            "schema", "vault_id", "created_at", "protocol_version", "clinical_writer",
            "storage_mode", "encryption_mode", "hash_algorithm", "event_canonicalization",
        ]
        try rejectUnknownFields(in: root, allowed: Set(rootFields), path: "/")
        for field in rootFields where root[field] == nil {
            throw issue("schema.required", append("/", field), "O campo obrigatório está ausente.")
        }

        let schema = try string(root, "schema")
        let vaultID = try string(root, "vault_id")
        let createdAt = try string(root, "created_at")
        let protocolVersion = try string(root, "protocol_version")
        let storageMode = try string(root, "storage_mode")
        let encryptionMode = try string(root, "encryption_mode")
        let hashAlgorithm = try string(root, "hash_algorithm")
        let eventCanonicalization = try string(root, "event_canonicalization")

        try require(schema == "openpep/vault@1", rule: "schema.const", path: "/schema")
        try require(matches(vaultID, pattern: vaultIDPattern), rule: "schema.pattern", path: "/vault_id")
        try require(isUTCDate(createdAt), rule: "schema.pattern", path: "/created_at")
        try require(protocolVersion == "1.0", rule: "schema.const", path: "/protocol_version")
        try require(storageMode == "local-portable", rule: "schema.const", path: "/storage_mode")
        try require(encryptionMode == "local-filevault", rule: "schema.const", path: "/encryption_mode")
        try require(hashAlgorithm == "sha256", rule: "schema.const", path: "/hash_algorithm")
        try require(eventCanonicalization == "rfc8785", rule: "schema.const", path: "/event_canonicalization")

        guard case let .mapping(writer)? = root["clinical_writer"] else {
            throw issue("schema.type", "/clinical_writer", "clinical_writer deve ser um mapa.")
        }
        try rejectUnknownFields(in: writer, allowed: ["device_id"], path: "/clinical_writer")
        guard writer["device_id"] != nil else {
            throw issue("schema.required", "/clinical_writer/device_id", "O campo obrigatório está ausente.")
        }
        let deviceID = try string(writer, "device_id", basePath: "/clinical_writer")
        try require(matches(deviceID, pattern: deviceIDPattern), rule: "schema.pattern", path: "/clinical_writer/device_id")

        return VaultManifest(
            schema: schema,
            vaultID: vaultID,
            createdAt: createdAt,
            protocolVersion: protocolVersion,
            deviceID: deviceID,
            storageMode: storageMode,
            encryptionMode: encryptionMode,
            hashAlgorithm: hashAlgorithm,
            eventCanonicalization: eventCanonicalization
        )
    }

    private static func validateOperationsSchema(_ value: YAMLValue) throws -> OperationsManifest {
        guard case let .mapping(root) = value else {
            throw issue("schema.type", "/", "O manifesto operacional deve ser um mapa.")
        }

        let fields = ["schema", "vault_id", "state"]
        try rejectUnknownFields(in: root, allowed: Set(fields), path: "/")
        for field in fields where root[field] == nil {
            throw issue("schema.required", append("/", field), "O campo obrigatório está ausente.")
        }

        let schema = try string(root, "schema")
        let vaultID = try string(root, "vault_id")
        let state = try string(root, "state")
        try require(schema == "openpep/operations-manifest@1", rule: "schema.const", path: "/schema")
        try require(matches(vaultID, pattern: vaultIDPattern), rule: "schema.pattern", path: "/vault_id")
        try require(state == "empty", rule: "schema.const", path: "/state")
        return OperationsManifest(schema: schema, vaultID: vaultID, state: state)
    }

    private static func validatePatientSchema(_ value: YAMLValue) throws -> PatientRecord {
        guard case let .mapping(root) = value else {
            throw issue("schema.type", "/", "O cadastro deve ser um mapa.")
        }
        let fields = [
            "schema", "patient_id", "status", "full_name", "preferred_name",
            "birth_date", "contacts", "identifiers", "alerts", "created_at",
            "updated_at", "archived_at",
        ]
        try rejectUnknownFields(in: root, allowed: Set(fields), path: "/")
        for field in fields where root[field] == nil {
            throw issue("schema.required", append("/", field), "O campo obrigatório está ausente.")
        }

        let schema = try string(root, "schema")
        let patientID = try string(root, "patient_id")
        let statusValue = try string(root, "status")
        let fullName = try optionalString(root, "full_name", maximum: 200)
        let preferredName = try optionalString(root, "preferred_name", maximum: 120)
        let birthDate = try optionalString(root, "birth_date", maximum: 10)
        let createdAt = try string(root, "created_at")
        let updatedAt = try string(root, "updated_at")
        let archivedAt = try optionalString(root, "archived_at", maximum: 40)

        try require(schema == "openpep/patient@1", rule: "schema.const", path: "/schema")
        try require(matches(patientID, pattern: patientIDPattern), rule: "schema.pattern", path: "/patient_id")
        guard let status = PatientStatus(rawValue: statusValue) else {
            throw issue("schema.enum", "/status", "O estado do paciente não é permitido.")
        }
        if let birthDate {
            try require(isCalendarDate(birthDate), rule: "schema.format", path: "/birth_date")
        }
        try require(isUTCDate(createdAt), rule: "schema.format", path: "/created_at")
        try require(isUTCDate(updatedAt), rule: "schema.format", path: "/updated_at")
        if let archivedAt {
            try require(isUTCDate(archivedAt), rule: "schema.format", path: "/archived_at")
        }
        try require(timestamp(updatedAt) >= timestamp(createdAt), rule: "patient.updated_before_created", path: "/updated_at")
        if status == .active, archivedAt != nil {
            throw issue("patient.active_with_archived_at", "/archived_at", "Paciente ativo deve ter archived_at nulo.")
        }
        if status == .archived, archivedAt == nil {
            throw issue("patient.archived_without_timestamp", "/archived_at", "Paciente arquivado deve ter archived_at.")
        }
        if let archivedAt {
            try require(timestamp(archivedAt) >= timestamp(createdAt), rule: "patient.archived_before_created", path: "/archived_at")
        }

        let contacts = try sequence(root, "contacts", maximum: 20).enumerated().map { index, value in
            guard case let .mapping(item) = value else {
                throw issue("schema.type", "/contacts/\(index)", "O contato deve ser um mapa.")
            }
            try rejectUnknownFields(in: item, allowed: ["type", "value", "authorized_for_care"], path: "/contacts/\(index)")
            let typeValue = try string(item, "type", basePath: "/contacts/\(index)")
            guard let type = PatientContactType(rawValue: typeValue) else {
                throw issue("schema.enum", "/contacts/\(index)/type", "O tipo de contato não é permitido.")
            }
            let contactValue = try nonEmptyString(item, "value", maximum: 254, basePath: "/contacts/\(index)")
            guard case let .boolean(authorized)? = item["authorized_for_care"] else {
                throw issue("schema.type", "/contacts/\(index)/authorized_for_care", "A autorização deve ser booleana.")
            }
            return PatientContact(type: type, value: contactValue, authorizedForCare: authorized)
        }

        let identifiers = try sequence(root, "identifiers", maximum: 20).enumerated().map { index, value in
            guard case let .mapping(item) = value else {
                throw issue("schema.type", "/identifiers/\(index)", "O identificador deve ser um mapa.")
            }
            try rejectUnknownFields(in: item, allowed: ["type", "value"], path: "/identifiers/\(index)")
            let typeValue = try string(item, "type", basePath: "/identifiers/\(index)")
            guard let type = PatientIdentifierType(rawValue: typeValue) else {
                throw issue("schema.enum", "/identifiers/\(index)/type", "O tipo de identificador não é permitido.")
            }
            return PatientIdentifier(
                type: type,
                value: try nonEmptyString(item, "value", maximum: 120, basePath: "/identifiers/\(index)")
            )
        }

        let alerts = try sequence(root, "alerts", maximum: 100).enumerated().map { index, value in
            guard case let .mapping(item) = value else {
                throw issue("schema.type", "/alerts/\(index)", "O alerta deve ser um mapa.")
            }
            try rejectUnknownFields(in: item, allowed: ["type", "description", "source", "recorded_at"], path: "/alerts/\(index)")
            let typeValue = try string(item, "type", basePath: "/alerts/\(index)")
            guard let type = PatientAlertType(rawValue: typeValue) else {
                throw issue("schema.enum", "/alerts/\(index)/type", "O tipo de alerta não é permitido.")
            }
            let recordedAt = try string(item, "recorded_at", basePath: "/alerts/\(index)")
            try require(isUTCDate(recordedAt), rule: "schema.format", path: "/alerts/\(index)/recorded_at")
            return PatientAlert(
                type: type,
                description: try nonEmptyString(item, "description", maximum: 500, basePath: "/alerts/\(index)"),
                source: try nonEmptyString(item, "source", maximum: 200, basePath: "/alerts/\(index)"),
                recordedAt: recordedAt
            )
        }

        let extensions = root.filter { $0.key.hasPrefix("x_") }
        return PatientRecord(
            schema: schema,
            patientID: patientID,
            status: status,
            fullName: fullName,
            preferredName: preferredName,
            birthDate: birthDate,
            contacts: contacts,
            identifiers: identifiers,
            alerts: alerts,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt,
            extensions: extensions
        )
    }

    private static func validateAppointmentSchema(_ value: YAMLValue) throws -> AppointmentRecord {
        guard case let .mapping(root) = value else {
            throw issue("schema.type", "/", "O agendamento deve ser um mapa.")
        }
        let fields = [
            "schema", "appointment_id", "patient_id", "starts_at", "ends_at",
            "time_zone", "modality", "status", "location", "remote_access_url",
            "administrative_note", "encounter_id", "created_at", "updated_at",
        ]
        try rejectUnknownFields(in: root, allowed: Set(fields), path: "/")
        for field in fields where root[field] == nil {
            throw issue("schema.required", append("/", field), "O campo obrigatório está ausente.")
        }

        let schema = try string(root, "schema")
        let appointmentID = try string(root, "appointment_id")
        let patientID = try string(root, "patient_id")
        let startsAt = try string(root, "starts_at")
        let endsAt = try string(root, "ends_at")
        let timeZone = try nonEmptyString(root, "time_zone", maximum: 100)
        let modalityValue = try string(root, "modality")
        let statusValue = try string(root, "status")
        let location = try optionalString(root, "location", maximum: 200)
        let remoteAccessURL = try optionalString(root, "remote_access_url", maximum: 2048)
        let administrativeNote = try optionalString(root, "administrative_note", maximum: 500)
        let createdAt = try string(root, "created_at")
        let updatedAt = try string(root, "updated_at")

        try require(schema == "openpep/appointment@1", rule: "schema.const", path: "/schema")
        try require(matches(appointmentID, pattern: appointmentIDPattern), rule: "schema.pattern", path: "/appointment_id")
        try require(matches(patientID, pattern: patientIDPattern), rule: "schema.pattern", path: "/patient_id")
        try require(isUTCDate(startsAt), rule: "schema.format", path: "/starts_at")
        try require(isUTCDate(endsAt), rule: "schema.format", path: "/ends_at")
        guard TimeZone(identifier: timeZone) != nil else {
            throw issue("appointment.invalid_time_zone", "/time_zone", "O fuso IANA não está disponível.")
        }
        guard let modality = AppointmentModality(rawValue: modalityValue) else {
            throw issue("schema.enum", "/modality", "A modalidade não é permitida.")
        }
        guard let status = AppointmentStatus(rawValue: statusValue) else {
            throw issue("schema.enum", "/status", "O estado não é permitido.")
        }
        if modality == .inPerson, remoteAccessURL != nil {
            throw issue("schema.type", "/remote_access_url", "Agendamento presencial não aceita link remoto.")
        }
        if modality == .telemedicine, location != nil {
            throw issue("schema.type", "/location", "Teleconsulta não aceita local presencial.")
        }
        if let remoteAccessURL {
            try require(remoteAccessURL.hasPrefix("https://"), rule: "schema.pattern", path: "/remote_access_url")
        }
        let encounterID: String?
        if root["encounter_id"] == .null {
            encounterID = nil
        } else {
            encounterID = try string(root, "encounter_id")
            try require(
                matches(encounterID!, pattern: encounterIDPattern),
                rule: "schema.pattern",
                path: "/encounter_id"
            )
        }
        try require(isUTCDate(createdAt), rule: "schema.format", path: "/created_at")
        try require(isUTCDate(updatedAt), rule: "schema.format", path: "/updated_at")
        try require(timestamp(endsAt) > timestamp(startsAt), rule: "appointment.invalid_interval", path: "/ends_at")
        try require(timestamp(updatedAt) >= timestamp(createdAt), rule: "appointment.updated_before_created", path: "/updated_at")

        return AppointmentRecord(
            schema: schema,
            appointmentID: appointmentID,
            patientID: patientID,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZone: timeZone,
            modality: modality,
            status: status,
            location: location,
            remoteAccessURL: remoteAccessURL,
            administrativeNote: administrativeNote,
            encounterID: encounterID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            extensions: root.filter { $0.key.hasPrefix("x_") }
        )
    }

    private static func validateRawAssetSchema(_ value: YAMLValue) throws -> RawAssetMetadata {
        guard case let .mapping(root) = value else {
            throw issue("raw_asset.type", "/", "O sidecar deve ser um mapa.")
        }

        let fields = [
            "schema", "asset_id", "patient_id", "encounter_id", "media_type",
            "file_extension", "original_name", "size_bytes", "sha256", "source",
            "actor_id", "device_id", "imported_at", "quarantine_state",
            "inspection_result",
        ]
        let allowed = Set(fields)
        for key in root.keys.sorted() where !allowed.contains(key) && !key.hasPrefix("x_") {
            throw issue("raw_asset.unknown_field", append("/", key), "O campo não é permitido.")
        }
        for field in fields where root[field] == nil {
            throw issue("raw_asset.missing_field", append("/", field), "O campo obrigatório está ausente.")
        }

        let schema = try string(root, "schema")
        let assetID = try string(root, "asset_id")
        let patientID = try string(root, "patient_id")
        let mediaType = try string(root, "media_type")
        let fileExtension = try string(root, "file_extension")
        let originalName = try string(root, "original_name")
        guard case let .integer(sizeBytes)? = root["size_bytes"] else {
            throw issue("raw_asset.type", "/size_bytes", "size_bytes deve ser um inteiro.")
        }
        let sha256 = try string(root, "sha256")
        let source = try string(root, "source")
        let deviceID = try string(root, "device_id")
        let importedAt = try string(root, "imported_at")
        let quarantineState = try string(root, "quarantine_state")
        let inspectionResult = try string(root, "inspection_result")

        let encounterID = try optionalEncounterIdentifier(root["encounter_id"])
        guard root["actor_id"] == .null else {
            throw issue("raw_asset.const", "/actor_id", "MAC-002 exige actor_id nulo.")
        }

        try require(schema == "openpep/raw-asset@1", rule: "raw_asset.const", path: "/schema")
        try require(matches(assetID, pattern: assetIDPattern), rule: "raw_asset.pattern", path: "/asset_id")
        try require(matches(patientID, pattern: patientIDPattern), rule: "raw_asset.pattern", path: "/patient_id")
        try require(matches(sha256, pattern: sha256Pattern), rule: "raw_asset.pattern", path: "/sha256")
        try require(matches(deviceID, pattern: deviceIDPattern), rule: "raw_asset.pattern", path: "/device_id")
        try require(isUTCDate(importedAt), rule: "raw_asset.pattern", path: "/imported_at")

        let isExactTextFixture = mediaType == "text/plain"
            && fileExtension == "txt"
            && originalName == SyntheticRawFixtureContract.fileName
            && sizeBytes == SyntheticRawFixtureContract.sizeBytes
            && sha256 == SyntheticRawFixtureContract.sha256
            && source == "file_import"
            && quarantineState == "not_required_synthetic_fixture"
            && inspectionResult == "exact_fixture_match"
        let isGeneratedDemoFixture = ["text/plain", "application/pdf"].contains(mediaType)
            && fileExtension == (mediaType == "application/pdf" ? "pdf" : "txt")
            && originalName.hasSuffix(".\(fileExtension)")
            && originalName.localizedCaseInsensitiveContains("sintetic")
            && sizeBytes > 0
            && source == "fixture_generation"
            && quarantineState == "not_required_synthetic_fixture"
            && inspectionResult == "generated_demo_fixture"
            && root["x_fixture_profile"] == .string("cardiology_demo_v1")
        let allowedGeneralTypes: Set<String> = [
            "application/pdf|pdf",
            "image/png|png",
            "image/jpeg|jpg",
            "image/jpeg|jpeg",
            "text/plain|txt",
        ]
        let isGeneralImport = allowedGeneralTypes.contains("\(mediaType)|\(fileExtension)")
            && !originalName.isEmpty
            && originalName.utf8.count <= 255
            && !originalName.contains("/")
            && !originalName.contains("\\")
            && sizeBytes > 0
            && sizeBytes <= 25 * 1_024 * 1_024
            && source == "file_import"
            && quarantineState == "not_scanned"
            && inspectionResult == "allowed_type_and_signature"
        let isOpaqueImport = mediaType == "application/octet-stream"
            && matches(fileExtension, pattern: "^[a-z0-9]{1,32}$")
            && !originalName.isEmpty && originalName.utf8.count <= 255
            && !originalName.contains("/") && !originalName.contains("\\")
            && sizeBytes >= 0 && sizeBytes <= 25 * 1_024 * 1_024
            && source == "file_import" && quarantineState == "not_scanned"
            && inspectionResult == "opaque_file"
        try require(
            isExactTextFixture || isGeneratedDemoFixture || isGeneralImport || isOpaqueImport,
            rule: "raw_asset.profile",
            path: "/"
        )

        return RawAssetMetadata(
            schema: schema,
            assetID: assetID,
            patientID: patientID,
            encounterID: encounterID,
            mediaType: mediaType,
            fileExtension: fileExtension,
            originalName: originalName,
            sizeBytes: sizeBytes,
            sha256: sha256,
            source: source,
            deviceID: deviceID,
            importedAt: importedAt,
            quarantineState: quarantineState,
            inspectionResult: inspectionResult,
            extensions: root.filter { $0.key.hasPrefix("x_") }
        )
    }

    private static func rejectUnknownFields(
        in map: [String: YAMLValue],
        allowed: Set<String>,
        path: String
    ) throws {
        for key in map.keys.sorted() where !allowed.contains(key) && !key.hasPrefix("x_") {
            throw issue("schema.additionalProperties", append(path, key), "O campo não é permitido.")
        }
    }

    private static func string(
        _ map: [String: YAMLValue],
        _ key: String,
        basePath: String = "/"
    ) throws -> String {
        guard case let .string(value)? = map[key] else {
            throw issue("schema.type", append(basePath, key), "O campo deve ser uma string.")
        }
        return value
    }

    private static func nonEmptyString(
        _ map: [String: YAMLValue],
        _ key: String,
        maximum: Int,
        basePath: String = "/"
    ) throws -> String {
        let value = try string(map, key, basePath: basePath)
        guard !value.isEmpty, value.count <= maximum else {
            throw issue("schema.length", append(basePath, key), "O texto possui tamanho inválido.")
        }
        return value
    }

    private static func optionalString(
        _ map: [String: YAMLValue],
        _ key: String,
        maximum: Int
    ) throws -> String? {
        if map[key] == .null { return nil }
        let value = try string(map, key)
        guard !value.isEmpty, value.count <= maximum else {
            throw issue("schema.length", append("/", key), "O texto possui tamanho inválido.")
        }
        return value
    }

    private static func optionalEncounterIdentifier(_ value: YAMLValue?) throws -> String? {
        if value == .null { return nil }
        guard case let .string(identifier)? = value,
              matches(identifier, pattern: encounterIDPattern)
        else {
            throw issue(
                "raw_asset.pattern",
                "/encounter_id",
                "encounter_id deve ser nulo ou um identificador de atendimento válido."
            )
        }
        return identifier
    }

    private static func sequence(
        _ map: [String: YAMLValue],
        _ key: String,
        maximum: Int
    ) throws -> [YAMLValue] {
        guard case let .sequence(value)? = map[key] else {
            throw issue("schema.type", append("/", key), "O campo deve ser uma lista.")
        }
        guard value.count <= maximum else {
            throw issue("schema.maxItems", append("/", key), "A lista excede o limite permitido.")
        }
        return value
    }

    private static func require(_ condition: Bool, rule: String, path: String) throws {
        guard condition else {
            throw issue(rule, path, "O valor não atende ao contrato do manifesto.")
        }
    }

    private static func isUTCDate(_ value: String) -> Bool {
        guard value.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func isCalendarDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil && formatter.string(from: formatter.date(from: value)!) == value
    }

    private static func timestamp(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? .distantPast
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func append(_ path: String, _ component: String) -> String {
        let escaped = component.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return path == "/" ? "/\(escaped)" : "\(path)/\(escaped)"
    }

    private static func issue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
        VaultValidationIssue(rule: rule, path: path, message: message)
    }
}
