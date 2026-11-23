// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

struct VaultSummary: Equatable, Sendable {
    let url: URL
    let manifest: VaultManifest
    let operationsManifest: OperationsManifest?
    let demoCatalog: DemoCatalog?
    let patients: [PatientSummary]
    let unavailablePatients: [UnavailablePatientSummary]
    let appointments: [AppointmentSummary]
    let unavailableAppointments: [UnavailableAppointmentSummary]
    let unmanagedPaths: [String]
    let writingAllowed: Bool
    let statusMessage: String
}

struct VaultAccessReference: Equatable, Sendable {
    let authorizationURL: URL
    let vaultURL: URL
}

struct VaultBookmarkStore {
    private static let bookmarkKey = "openpep.last-vault.authorization-bookmark"
    private static let relativePathKey = "openpep.last-vault.relative-path"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(authorizationURL: URL, vaultURL: URL) throws {
        let relativePath = try Self.relativeVaultPath(
            authorizationURL: authorizationURL,
            vaultURL: vaultURL
        )
        let bookmark = try authorizationURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(relativePath, forKey: Self.relativePathKey)
    }

    func resolve() throws -> VaultAccessReference? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
              let relativePath = defaults.string(forKey: Self.relativePathKey) else {
            return nil
        }
        var isStale = false
        let authorizationURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let vaultURL = relativePath.isEmpty
            ? authorizationURL
            : authorizationURL.appending(path: relativePath, directoryHint: .isDirectory)
        if isStale {
            try save(authorizationURL: authorizationURL, vaultURL: vaultURL)
        }
        return VaultAccessReference(
            authorizationURL: authorizationURL,
            vaultURL: vaultURL
        )
    }

    func clear() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.relativePathKey)
    }

    static func relativeVaultPath(authorizationURL: URL, vaultURL: URL) throws -> String {
        let authorizationPath = authorizationURL.standardizedFileURL.path
        let vaultPath = vaultURL.standardizedFileURL.path
        if vaultPath == authorizationPath { return "" }
        let prefix = authorizationPath.hasSuffix("/") ? authorizationPath : authorizationPath + "/"
        guard vaultPath.hasPrefix(prefix) else {
            throw VaultValidationIssue(
                rule: "bookmark.vault_outside_authorization",
                path: vaultPath,
                message: "O prontuário não está dentro da pasta autorizada."
            )
        }
        let relativePath = String(vaultPath.dropFirst(prefix.count))
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw VaultValidationIssue(
                rule: "bookmark.relative_path",
                path: relativePath,
                message: "O caminho salvo do prontuário é inválido."
            )
        }
        return relativePath
    }
}

private struct VaultRootInspection: Equatable, Sendable {
    let writingAllowed: Bool
    let unmanagedPaths: [String]
    let blockedPath: String?
}

enum VaultLayout {
    static let requiredDirectories = [
        "operations/schemas",
        "operations/snapshots/patients",
        "operations/snapshots/appointments",
        "operations/snapshots/actions",
        "operations/ledger",
        "operations/checkpoints",
        "patients",
    ]

    static let createdDirectories = requiredDirectories + ["appointments", "indexes", "backups", "recordings"]

    static let knownRootEntries = Set([
        "vault.yaml", "operations", "patients", "appointments", "indexes", "backups", "recovery", "recordings", "README.txt",
    ]).union(SNCREnvironment.allCases.map(\.registryFilename))

    static let readme = """
    OpenPEP local clinical record

    This directory contains OpenPEP data stored as regular files.
    Use an OpenPEP-compatible reader to validate vault.yaml before writing.
    """ + "\n"
}

struct VaultReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func open(_ url: URL) throws -> VaultSummary {
        var outcome: Result<VaultSummary, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                outcome = .success(try readWithinCoordinatedAccess(coordinatedURL))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let outcome else {
            throw VaultValidationIssue(
                rule: "filesystem.coordination",
                path: url.path,
                message: "A leitura coordenada não foi concluída."
            )
        }
        return try outcome.get()
    }

    /// Caller must already hold coordinated access to this vault (read or write).
    /// Reusing the reader inside a write accessor avoids a nested coordination deadlock.
    func readWithinCoordinatedAccess(_ coordinatedURL: URL) throws -> VaultSummary {
        try requireRootDirectory(coordinatedURL)
        let manifestURL = coordinatedURL.appending(path: "vault.yaml", directoryHint: .notDirectory)
        try requireManagedFile(manifestURL, relativePath: "vault.yaml")
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try VaultManifestValidator.validate(data: data, source: manifestURL.path)
        let operationsURL = coordinatedURL.appending(
            path: "operations/manifest.yaml",
            directoryHint: .notDirectory
        )
        let operationsManifest: OperationsManifest?
        if fileManager.fileExists(atPath: operationsURL.path) {
            try requireManagedFile(
                operationsURL,
                relativePath: "operations/manifest.yaml"
            )
            let operationsData = try Data(contentsOf: operationsURL, options: [.mappedIfSafe])
            let parsed = try VaultManifestValidator.validateOperations(
                data: operationsData,
                source: operationsURL.path
            )
            guard parsed.vaultID == manifest.vaultID else {
                throw VaultValidationIssue(
                    rule: "operations.vault_id_mismatch",
                    path: "/vault_id",
                    message: "O vault_id operacional diverge do manifesto da raiz."
                )
            }
            operationsManifest = parsed
        } else {
            operationsManifest = nil
        }
        let completeLayout = VaultLayout.requiredDirectories.allSatisfy { relativePath in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: coordinatedURL.appending(path: relativePath).path,
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        }
        let requiresIntegrityVerification = try containsOperationalContent(
            coordinatedURL
        )
        let rootInspection = try inspectRoot(coordinatedURL)
        let parsedDemoCatalog = try DemoCatalogReader.readIfPresent(
            vaultURL: coordinatedURL,
            expectedVaultID: manifest.vaultID,
            fileManager: fileManager
        )
        let patientInspection = PatientVaultInspector(fileManager: fileManager).inspect(
            vaultURL: coordinatedURL,
            deviceID: manifest.deviceID,
            allowsGeneratedDemoAssets: parsedDemoCatalog != nil
        )
        let appointmentInspection = AppointmentInspector(fileManager: fileManager).inspect(
            vaultURL: coordinatedURL,
            patients: patientInspection.patients
        )
        let demoCatalog: DemoCatalog?
        if let parsedDemoCatalog, patientInspection.writingAllowed {
            try DemoCatalogReader.validateBindings(
                parsedDemoCatalog,
                patients: patientInspection.patients
            )
            demoCatalog = parsedDemoCatalog
        } else {
            demoCatalog = nil
        }
        let writingAllowed = operationsManifest != nil
            && completeLayout
            && !requiresIntegrityVerification
            && rootInspection.writingAllowed
            && patientInspection.writingAllowed
            && appointmentInspection.writingAllowed
            && demoCatalog == nil
        let assetCount = patientInspection.patients.reduce(0) { $0 + $1.rawAssetCount }
        let status = if demoCatalog != nil {
            "Prontuário demonstrativo com estrutura e vínculos internos conferidos. A origem não foi autenticada; navegação somente leitura."
        } else if operationsManifest == nil {
            "Manifesto operacional ausente. Escrita bloqueada; nenhuma migração foi realizada."
        } else if requiresIntegrityVerification {
            "Conteúdo operacional existente exige verificação fora deste corte. Escrita bloqueada."
        } else if !completeLayout {
            "Manifesto válido; estrutura completa não confirmada. Escrita bloqueada."
        } else if !rootInspection.writingAllowed {
            "Caminho inseguro ou diretório desconhecido na raiz: \(rootInspection.blockedPath ?? "não identificado"). Escrita bloqueada."
        } else if !patientInspection.writingAllowed {
            patientInspection.statusMessage ?? "Conteúdo de paciente não reconhecido. Escrita bloqueada."
        } else if !patientInspection.unavailablePatients.isEmpty
                    || !appointmentInspection.unavailable.isEmpty
                    || !rootInspection.unmanagedPaths.isEmpty {
            "Prontuário legível com \(patientInspection.patients.count) paciente(s) válido(s), \(patientInspection.unavailablePatients.count) indisponível(is), \(appointmentInspection.appointments.count) agendamento(s) válido(s), \(appointmentInspection.unavailable.count) indisponível(is) e \(rootInspection.unmanagedPaths.count) arquivo(s) não gerenciado(s) preservado(s)."
        } else if patientInspection.patients.isEmpty {
            "Prontuário vazio validado e disponível."
        } else {
            "Prontuário com \(patientInspection.patients.count) paciente(s) e \(assetCount) documento(s) validado."
        }
        return VaultSummary(
            url: coordinatedURL,
            manifest: manifest,
            operationsManifest: operationsManifest,
            demoCatalog: demoCatalog,
            patients: patientInspection.patients,
            unavailablePatients: patientInspection.unavailablePatients,
            appointments: appointmentInspection.appointments,
            unavailableAppointments: appointmentInspection.unavailable,
            unmanagedPaths: rootInspection.unmanagedPaths,
            writingAllowed: writingAllowed,
            statusMessage: status
        )
    }

    private func containsOperationalContent(_ root: URL) throws -> Bool {
        let guardedDirectories = [
            "operations/ledger",
            "operations/checkpoints",
            "operations/snapshots/patients",
            "operations/snapshots/appointments",
            "operations/snapshots/actions",
        ]
        return try guardedDirectories.contains { relativePath in
            let directory = root.appending(path: relativePath, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: directory.path) else { return false }
            return try !managedDirectoryEntries(in: directory, fileManager: fileManager).isEmpty
        }
    }

    private func inspectRoot(_ root: URL) throws -> VaultRootInspection {
        var unmanagedPaths: [String] = []
        for entry in try managedDirectoryEntries(in: root, fileManager: fileManager) {
            let values = try entry.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                return VaultRootInspection(
                    writingAllowed: false,
                    unmanagedPaths: unmanagedPaths.sorted(),
                    blockedPath: entry.lastPathComponent
                )
            }
            if VaultLayout.knownRootEntries.contains(entry.lastPathComponent) {
                if ["recovery", "recordings"].contains(entry.lastPathComponent), values.isDirectory != true {
                    return VaultRootInspection(
                        writingAllowed: false,
                        unmanagedPaths: unmanagedPaths.sorted(),
                        blockedPath: entry.lastPathComponent
                    )
                }
                continue
            }
            if values.isRegularFile == true {
                unmanagedPaths.append(entry.lastPathComponent)
            } else {
                return VaultRootInspection(
                    writingAllowed: false,
                    unmanagedPaths: unmanagedPaths.sorted(),
                    blockedPath: entry.lastPathComponent
                )
            }
        }
        return VaultRootInspection(
            writingAllowed: true,
            unmanagedPaths: unmanagedPaths.sorted(),
            blockedPath: nil
        )
    }

    private func requireRootDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VaultValidationIssue(
                rule: "filesystem.root_symlink",
                path: ".",
                message: "O diretório do vault deve ser uma pasta sem link simbólico."
            )
        }
    }

    private func requireManagedFile(_ url: URL, relativePath: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VaultValidationIssue(
                rule: "filesystem.regular_file",
                path: relativePath,
                message: "O manifesto deve ser um arquivo regular sem link simbólico."
            )
        }
    }
}

struct VaultCreationIdentity: Equatable, Sendable {
    let vaultID: String
    let deviceID: String

    static func generate(at date: Date = Date()) throws -> VaultCreationIdentity {
        VaultCreationIdentity(
            vaultID: "vlt_\(try UUIDv7.generate(at: date))",
            deviceID: "dev_\(try UUIDv7.generate(at: date))"
        )
    }
}

enum VaultCreationStep: Equatable, Sendable {
    case temporaryDirectoryCreated
    case manifestWritten
    case validated
}

struct VaultCreator {
    typealias FaultInjector = (VaultCreationStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func create(
        in parentURL: URL,
        directoryName: String = "OpenPEP-Vault",
        identity: VaultCreationIdentity,
        createdAt: Date
    ) throws -> VaultSummary {
        guard !directoryName.isEmpty,
              directoryName != ".",
              directoryName != "..",
              !directoryName.contains("/") else {
            throw VaultValidationIssue(
                rule: "creation.directory_name",
                path: directoryName,
                message: "O nome do diretório é inválido."
            )
        }

        var outcome: Result<URL, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: parentURL, options: .forMerging, error: &coordinationError) { coordinatedParent in
            do {
                outcome = .success(try createUncoordinated(
                    in: coordinatedParent,
                    directoryName: directoryName,
                    identity: identity,
                    createdAt: createdAt
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let outcome else {
            throw VaultValidationIssue(
                rule: "filesystem.coordination",
                path: parentURL.path,
                message: "A escrita coordenada não foi concluída."
            )
        }
        return try VaultReader(fileManager: fileManager).open(outcome.get())
    }

    private func createUncoordinated(
        in parentURL: URL,
        directoryName: String,
        identity: VaultCreationIdentity,
        createdAt: Date
    ) throws -> URL {
        let destination = parentURL.appending(path: directoryName, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw VaultValidationIssue(
                rule: "creation.destination_exists",
                path: destination.path,
                message: "O diretório de destino já existe."
            )
        }

        let temporary = parentURL.appending(
            path: ".openpep-create-\(UUID().uuidString.lowercased())",
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
        for relativePath in VaultLayout.createdDirectories {
            try fileManager.createDirectory(
                at: temporary.appending(path: relativePath, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let manifest = manifestText(identity: identity, createdAt: createdAt)
        try Data(manifest.utf8).write(
            to: temporary.appending(path: "vault.yaml", directoryHint: .notDirectory),
            options: [.atomic]
        )
        try Data(VaultLayout.readme.utf8).write(
            to: temporary.appending(path: "README.txt", directoryHint: .notDirectory),
            options: [.atomic]
        )
        let operationsManifest = operationsManifestText(identity: identity)
        try Data(operationsManifest.utf8).write(
            to: temporary.appending(path: "operations/manifest.yaml", directoryHint: .notDirectory),
            options: [.atomic]
        )
        try faultInjector?(.manifestWritten)

        let manifestData = try Data(contentsOf: temporary.appending(path: "vault.yaml"))
        let validatedManifest = try VaultManifestValidator.validate(data: manifestData)
        let operationsData = try Data(contentsOf: temporary.appending(path: "operations/manifest.yaml"))
        let validatedOperations = try VaultManifestValidator.validateOperations(data: operationsData)
        guard validatedOperations.vaultID == validatedManifest.vaultID else {
            throw VaultValidationIssue(
                rule: "operations.vault_id_mismatch",
                path: "/vault_id",
                message: "O vault_id operacional diverge do manifesto da raiz."
            )
        }
        try faultInjector?(.validated)

        try fileManager.moveItem(at: temporary, to: destination)
        published = true
        return destination
    }

    private func manifestText(identity: VaultCreationIdentity, createdAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return """
        schema: openpep/vault@1
        vault_id: \(identity.vaultID)
        created_at: "\(formatter.string(from: createdAt))"
        protocol_version: "1.0"
        clinical_writer:
          device_id: \(identity.deviceID)
        storage_mode: local-portable
        encryption_mode: local-filevault
        hash_algorithm: sha256
        event_canonicalization: rfc8785
        """ + "\n"
    }

    private func operationsManifestText(identity: VaultCreationIdentity) -> String {
        """
        schema: openpep/operations-manifest@1
        vault_id: \(identity.vaultID)
        state: empty
        """ + "\n"
    }
}

enum UUIDv7 {
    static func generate(at date: Date) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultValidationIssue(
                rule: "identifier.random",
                path: "/",
                message: "Não foi possível gerar identificador aleatório."
            )
        }

        let milliseconds = UInt64(date.timeIntervalSince1970 * 1_000)
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> UInt64((5 - index) * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
