// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct VaultBackupFile: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int
    let sha256: String
}

struct VaultBackupManifest: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let createdAt: String
    let vaultID: String
    let fileCount: Int
    let byteCount: Int
    let directories: [String]
    let files: [VaultBackupFile]
}

struct VaultBackupSummary: Equatable, Sendable {
    let packageURL: URL
    let manifestSHA256: String
    let manifest: VaultBackupManifest
}

struct VaultRestoreResult: Equatable, Sendable {
    let vaultURL: URL
    let backup: VaultBackupSummary
}

enum VaultBackupOperation: Equatable, Sendable {
    case creation
    case restoration
}

enum VaultBackupStep: Equatable, Sendable {
    case stagingCreated
    case filesCopied
    case beforePublication
    case beforeCleanup
}

struct VaultBackupService {
    typealias FaultInjector = (VaultBackupOperation, VaultBackupStep) throws -> Void

    private let fileManager: FileManager
    private let faultInjector: FaultInjector?

    init(fileManager: FileManager = .default, faultInjector: FaultInjector? = nil) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func create(from vaultURL: URL, to destinationURL: URL) throws -> VaultBackupSummary {
        try validateNewDestination(destinationURL, outside: vaultURL)
        let parentURL = destinationURL.deletingLastPathComponent()
        var outcome: Result<VaultBackupSummary, Error>?
        var coordinationError: NSError?

        NSFileCoordinator().coordinate(
            readingItemAt: vaultURL,
            options: [],
            writingItemAt: parentURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedVault, coordinatedParent in
            do {
                let coordinatedDestination = coordinatedParent.appending(
                    path: destinationURL.lastPathComponent,
                    directoryHint: .isDirectory
                )
                try validateNewDestination(coordinatedDestination, outside: coordinatedVault)
                outcome = .success(try createCoordinated(
                    from: coordinatedVault,
                    to: coordinatedDestination
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw backupIssue(
                "backup.coordination",
                destinationURL.path,
                "A criação coordenada do backup não foi concluída."
            )
        }
        return try outcome.get()
    }

    func verify(at packageURL: URL) throws -> VaultBackupSummary {
        var outcome: Result<VaultBackupSummary, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: packageURL,
            options: [],
            error: &coordinationError
        ) { coordinatedPackage in
            do {
                outcome = .success(try verifyPackage(coordinatedPackage))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw backupIssue(
                "backup.coordination",
                packageURL.path,
                "A verificação coordenada do backup não foi concluída."
            )
        }
        return try outcome.get()
    }

    func restore(
        from packageURL: URL,
        to destinationURL: URL,
        expectedManifestSHA256: String? = nil
    ) throws -> VaultRestoreResult {
        try validateNewDestination(destinationURL, outside: packageURL)
        let parentURL = destinationURL.deletingLastPathComponent()
        var outcome: Result<VaultRestoreResult, Error>?
        var coordinationError: NSError?

        NSFileCoordinator().coordinate(
            readingItemAt: packageURL,
            options: [],
            writingItemAt: parentURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedPackage, coordinatedParent in
            do {
                let coordinatedDestination = coordinatedParent.appending(
                    path: destinationURL.lastPathComponent,
                    directoryHint: .isDirectory
                )
                try validateNewDestination(coordinatedDestination, outside: coordinatedPackage)
                outcome = .success(try restoreCoordinated(
                    from: coordinatedPackage,
                    to: coordinatedDestination,
                    expectedManifestSHA256: expectedManifestSHA256
                ))
            } catch {
                outcome = .failure(error)
            }
        }

        if let coordinationError { throw coordinationError }
        guard let outcome else {
            throw backupIssue(
                "backup.coordination",
                destinationURL.path,
                "A restauração coordenada do backup não foi concluída."
            )
        }
        return try outcome.get()
    }

    private func createCoordinated(
        from vaultURL: URL,
        to destinationURL: URL
    ) throws -> VaultBackupSummary {
        let clinical = try validateClinicalVault(at: vaultURL)
        let sourceInventory = try inventory(at: vaultURL)
        let stagingURL = try newStagingURL(
            beside: destinationURL,
            prefix: ".openpep-backup-"
        )

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try faultInjector?(.creation, .stagingCreated)
            let copiedVaultURL = stagingURL.appending(path: "vault", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: copiedVaultURL, withIntermediateDirectories: false)
            try copy(sourceInventory, from: vaultURL, to: copiedVaultURL)
            try faultInjector?(.creation, .filesCopied)

            guard try inventory(at: copiedVaultURL) == sourceInventory,
                  try inventory(at: vaultURL) == sourceInventory else {
                throw backupIssue(
                    "backup.source_changed",
                    vaultURL.path,
                    "O prontuário mudou durante a criação do backup. Tente novamente."
                )
            }

            let manifest = VaultBackupManifest(
                format: "openpep-backup",
                version: 1,
                createdAt: backupTimestamp(Date()),
                vaultID: clinical.manifest.vaultID,
                fileCount: sourceInventory.files.count,
                byteCount: try totalBytes(sourceInventory.files),
                directories: sourceInventory.directories,
                files: sourceInventory.files
            )
            let manifestData = try encodeManifest(manifest)
            try manifestData.write(
                to: stagingURL.appending(path: "manifest.json", directoryHint: .notDirectory),
                options: [.withoutOverwriting]
            )
            let stagedSummary = try verifyPackage(stagingURL)
            guard stagedSummary.manifest == manifest else {
                throw backupIssue(
                    "backup.staging_mismatch",
                    stagingURL.path,
                    "A cópia temporária diverge do manifesto criado."
                )
            }

            try faultInjector?(.creation, .beforePublication)
            let refreshedStagedSummary = try verifyPackage(stagingURL)
            guard refreshedStagedSummary.manifestSHA256 == stagedSummary.manifestSHA256,
                  refreshedStagedSummary.manifest == stagedSummary.manifest,
                  try inventory(at: vaultURL) == sourceInventory else {
                throw backupIssue(
                    "backup.source_changed",
                    vaultURL.path,
                    "O prontuário mudou antes da publicação do backup. Tente novamente."
                )
            }
            _ = try validateClinicalVault(at: vaultURL)
            guard !itemExistsIncludingSymbolicLink(destinationURL) else {
                throw backupIssue(
                    "backup.destination_exists",
                    destinationURL.path,
                    "O destino passou a existir durante a criação do backup."
                )
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return VaultBackupSummary(
                packageURL: destinationURL,
                manifestSHA256: stagedSummary.manifestSHA256,
                manifest: manifest
            )
        } catch {
            try cleanupAfterFailure(
                at: stagingURL,
                operation: .creation,
                originalError: error
            )
        }
    }

    private func restoreCoordinated(
        from packageURL: URL,
        to destinationURL: URL,
        expectedManifestSHA256: String?
    ) throws -> VaultRestoreResult {
        let backup = try verifyPackage(packageURL)
        if let expectedManifestSHA256,
           backup.manifestSHA256 != expectedManifestSHA256 {
            throw backupIssue(
                "backup.fingerprint_mismatch",
                packageURL.path,
                "O pacote escolhido mudou depois da confirmação. Verifique-o novamente."
            )
        }
        let sourceVaultURL = packageURL.appending(path: "vault", directoryHint: .isDirectory)
        let sourceInventory = try inventory(at: sourceVaultURL)
        let manifestInventory = BackupInventory(
            directories: backup.manifest.directories,
            files: backup.manifest.files
        )
        guard sourceInventory == manifestInventory else {
            throw backupIssue(
                "backup.source_changed",
                packageURL.path,
                "O backup mudou antes do início da restauração. Verifique-o novamente."
            )
        }
        let stagingURL = try newStagingURL(
            beside: destinationURL,
            prefix: ".openpep-restore-"
        )

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try faultInjector?(.restoration, .stagingCreated)
            try copy(manifestInventory, from: sourceVaultURL, to: stagingURL)
            try faultInjector?(.restoration, .filesCopied)

            guard try inventory(at: stagingURL) == manifestInventory else {
                throw backupIssue(
                    "backup.restore_copy_mismatch",
                    stagingURL.path,
                    "A restauração temporária diverge do backup verificado."
                )
            }
            let restoredClinical = try validateClinicalVault(at: stagingURL)
            guard restoredClinical.manifest.vaultID == backup.manifest.vaultID else {
                throw backupIssue(
                    "backup.vault_id_mismatch",
                    stagingURL.path,
                    "O vault_id restaurado diverge do manifesto do backup."
                )
            }

            try faultInjector?(.restoration, .beforePublication)
            let refreshedBackup = try verifyPackage(packageURL)
            guard refreshedBackup.manifestSHA256 == backup.manifestSHA256,
                  expectedManifestSHA256.map({ $0 == refreshedBackup.manifestSHA256 }) ?? true,
                  refreshedBackup.manifest == backup.manifest,
                  try inventory(at: stagingURL) == manifestInventory else {
                throw backupIssue(
                    "backup.source_changed",
                    packageURL.path,
                    "O backup mudou durante a restauração. Tente novamente."
                )
            }
            guard !itemExistsIncludingSymbolicLink(destinationURL) else {
                throw backupIssue(
                    "backup.destination_exists",
                    destinationURL.path,
                    "O destino passou a existir durante a restauração."
                )
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return VaultRestoreResult(
                vaultURL: destinationURL,
                backup: VaultBackupSummary(
                    packageURL: packageURL,
                    manifestSHA256: backup.manifestSHA256,
                    manifest: backup.manifest
                )
            )
        } catch {
            try cleanupAfterFailure(
                at: stagingURL,
                operation: .restoration,
                originalError: error
            )
        }
    }

    private func verifyPackage(_ packageURL: URL) throws -> VaultBackupSummary {
        try requireSafeDirectory(packageURL)
        let entries = try significantEntries(in: packageURL)
        guard Set(entries.map(\.lastPathComponent)) == ["manifest.json", "vault"] else {
            throw backupIssue(
                "backup.package_layout",
                packageURL.path,
                "O pacote deve conter somente manifest.json e vault/."
            )
        }

        let manifestURL = packageURL.appending(path: "manifest.json", directoryHint: .notDirectory)
        try requireSafeRegularFile(manifestURL)
        let manifestValues = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard let manifestSize = manifestValues.fileSize, manifestSize <= 16 * 1_024 * 1_024 else {
            throw backupIssue(
                "backup.manifest_size",
                manifestURL.path,
                "O manifesto excede o limite de 16 MiB."
            )
        }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try decodeManifest(manifestData, source: manifestURL.path)
        let vaultURL = packageURL.appending(path: "vault", directoryHint: .isDirectory)
        let actual = try inventory(at: vaultURL)
        guard actual.directories == manifest.directories,
              actual.files == manifest.files else {
            throw backupIssue(
                "backup.inventory_mismatch",
                vaultURL.path,
                "A árvore do backup diverge do manifesto."
            )
        }
        let clinical = try validateClinicalVault(at: vaultURL)
        guard clinical.manifest.vaultID == manifest.vaultID else {
            throw backupIssue(
                "backup.vault_id_mismatch",
                vaultURL.path,
                "O vault_id copiado diverge do manifesto do backup."
            )
        }
        return VaultBackupSummary(
            packageURL: packageURL,
            manifestSHA256: digest(manifestData),
            manifest: manifest
        )
    }

    private func validateClinicalVault(at vaultURL: URL) throws -> VaultSummary {
        let summary = try VaultReader(fileManager: fileManager).open(vaultURL)
        guard summary.unavailablePatients.isEmpty else {
            throw backupIssue(
                "backup.unavailable_patients",
                vaultURL.path,
                "O prontuário possui pacientes indisponíveis e não pode gerar um backup verificado."
            )
        }
        guard summary.unavailableAppointments.isEmpty else {
            throw backupIssue(
                "backup.unavailable_appointments",
                vaultURL.path,
                "O prontuário possui agendamentos indisponíveis e não pode gerar um backup verificado."
            )
        }
        for patient in summary.patients {
            for encounter in patient.encounters {
                if case .altered = encounter.finalizationStatus {
                    throw backupIssue(
                        "backup.altered_encounter",
                        encounter.metadata.encounterID,
                        "Uma consulta possui alteração detectada e não pode integrar um backup verificado."
                    )
                }
            }
        }
        return summary
    }

    private func inventory(at rootURL: URL) throws -> BackupInventory {
        try requireSafeDirectory(rootURL)
        var directories: [String] = []
        var files: [VaultBackupFile] = []
        try inventoryDirectory(
            rootURL,
            relativeComponents: [],
            directories: &directories,
            files: &files
        )
        directories.sort()
        files.sort { $0.path < $1.path }
        return BackupInventory(directories: directories, files: files)
    }

    private func inventoryDirectory(
        _ directoryURL: URL,
        relativeComponents: [String],
        directories: inout [String],
        files: inout [VaultBackupFile]
    ) throws {
        try requireSafeDirectory(directoryURL)
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                throw backupIssue(
                    "backup.symbolic_link",
                    entry.path,
                    "O backup não segue links simbólicos."
                )
            }
            let components = relativeComponents + [entry.lastPathComponent]
            let relativePath = components.joined(separator: "/")
            if values.isDirectory == true {
                directories.append(relativePath)
                try inventoryDirectory(
                    entry,
                    relativeComponents: components,
                    directories: &directories,
                    files: &files
                )
            } else if values.isRegularFile == true {
                if entry.lastPathComponent == ".DS_Store" { continue }
                let hash = try hashRegularFile(entry)
                files.append(VaultBackupFile(
                    path: relativePath,
                    sizeBytes: hash.byteCount,
                    sha256: hash.sha256
                ))
            } else {
                throw backupIssue(
                    "backup.special_file",
                    entry.path,
                    "O cofre contém um objeto que não é arquivo regular nem diretório."
                )
            }
        }
    }

    private func copy(
        _ inventory: BackupInventory,
        from sourceRoot: URL,
        to destinationRoot: URL
    ) throws {
        try requireSafeDirectory(sourceRoot)
        try requireSafeDirectory(destinationRoot)
        for path in inventory.directories.sorted(by: directoryOrder) {
            let source = sourceRoot.appending(path: path, directoryHint: .isDirectory)
            try requireSafeDirectory(source)
            let destination = destinationRoot.appending(path: path, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            try requireSafeDirectory(destination)
        }
        for file in inventory.files {
            let source = sourceRoot.appending(path: file.path, directoryHint: .notDirectory)
            let destination = destinationRoot.appending(path: file.path, directoryHint: .notDirectory)
            try requireSafeRegularFile(source)
            guard !itemExistsIncludingSymbolicLink(destination) else {
                throw backupIssue(
                    "backup.copy_collision",
                    destination.path,
                    "A cópia encontrou um caminho de destino já existente."
                )
            }
            try fileManager.copyItem(at: source, to: destination)
            let copiedHash = try hashRegularFile(destination)
            guard copiedHash.byteCount == file.sizeBytes, copiedHash.sha256 == file.sha256 else {
                throw backupIssue(
                    "backup.copy_hash_mismatch",
                    file.path,
                    "Os bytes copiados divergem do arquivo de origem."
                )
            }
        }
    }

    private func decodeManifest(_ data: Data, source: String) throws -> VaultBackupManifest {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw backupIssue("backup.manifest_json", source, "O manifesto não contém JSON válido.")
        }
        guard let root = json as? [String: Any],
              Set(root.keys) == [
                  "format", "version", "createdAt", "vaultID", "fileCount", "byteCount",
                  "directories", "files",
              ],
              let rawFiles = root["files"] as? [[String: Any]],
              rawFiles.allSatisfy({ Set($0.keys) == ["path", "sizeBytes", "sha256"] }) else {
            throw backupIssue(
                "backup.manifest_fields",
                source,
                "O manifesto possui campos ausentes ou inesperados."
            )
        }

        let manifest: VaultBackupManifest
        do {
            manifest = try JSONDecoder().decode(VaultBackupManifest.self, from: data)
        } catch {
            throw backupIssue(
                "backup.manifest_contract",
                source,
                "O manifesto não corresponde ao contrato de backup."
            )
        }
        try validateManifest(manifest, source: source)
        return manifest
    }

    private func validateManifest(_ manifest: VaultBackupManifest, source: String) throws {
        guard manifest.format == "openpep-backup", manifest.version == 1 else {
            throw backupIssue(
                "backup.manifest_version",
                source,
                "O formato ou a versão do backup não é compatível."
            )
        }
        guard validBackupTimestamp(manifest.createdAt),
              manifest.vaultID.range(of: backupVaultIDPattern, options: .regularExpression) != nil else {
            throw backupIssue(
                "backup.manifest_identity",
                source,
                "A identidade ou a data do manifesto é inválida."
            )
        }
        guard manifest.fileCount == manifest.files.count,
              manifest.byteCount >= 0,
              manifest.byteCount == (try? totalBytes(manifest.files)) else {
            throw backupIssue(
                "backup.manifest_counts",
                source,
                "As contagens do manifesto são incoerentes."
            )
        }
        guard manifest.directories == manifest.directories.sorted(),
              manifest.files.map(\.path) == manifest.files.map(\.path).sorted(),
              Set(manifest.directories).count == manifest.directories.count,
              Set(manifest.files.map(\.path)).count == manifest.files.count else {
            throw backupIssue(
                "backup.manifest_order",
                source,
                "As listas do manifesto devem ser únicas e ordenadas."
            )
        }

        let directorySet = Set(manifest.directories)
        let fileSet = Set(manifest.files.map(\.path))
        guard directorySet.isDisjoint(with: fileSet) else {
            throw backupIssue(
                "backup.manifest_collision",
                source,
                "Um caminho aparece como arquivo e diretório."
            )
        }
        for path in manifest.directories {
            try validateRelativePath(path, source: source)
            try requireDeclaredParents(of: path, in: directorySet, source: source)
        }
        for file in manifest.files {
            try validateRelativePath(file.path, source: source)
            guard file.sizeBytes >= 0,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  file.path.split(separator: "/").last != ".DS_Store" else {
                throw backupIssue(
                    "backup.manifest_file",
                    file.path,
                    "Uma entrada de arquivo do manifesto é inválida."
                )
            }
            try requireDeclaredParents(of: file.path, in: directorySet, source: source)
        }
    }

    private func encodeManifest(_ manifest: VaultBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0a)
        return data
    }

    private func validateRelativePath(_ path: String, source: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw backupIssue(
                "backup.manifest_path",
                path.isEmpty ? source : path,
                "O manifesto contém um caminho relativo inválido."
            )
        }
    }

    private func requireDeclaredParents(
        of path: String,
        in directories: Set<String>,
        source: String
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        for count in 1..<components.count {
            let parent = components.prefix(count).joined(separator: "/")
            guard directories.contains(parent) else {
                throw backupIssue(
                    "backup.manifest_parent",
                    source,
                    "O manifesto não declara todos os diretórios pais."
                )
            }
        }
    }

    private func hashRegularFile(_ url: URL) throws -> FileHash {
        try requireSafeRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            let next = byteCount.addingReportingOverflow(chunk.count)
            guard !next.overflow else {
                throw backupIssue(
                    "backup.byte_count_overflow",
                    url.path,
                    "O tamanho total do arquivo excede o limite representável."
                )
            }
            byteCount = next.partialValue
            hasher.update(data: chunk)
        }
        return FileHash(
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func totalBytes(_ files: [VaultBackupFile]) throws -> Int {
        try files.reduce(0) { result, file in
            let next = result.addingReportingOverflow(file.sizeBytes)
            guard !next.overflow else {
                throw backupIssue(
                    "backup.byte_count_overflow",
                    file.path,
                    "O tamanho total do backup excede o limite representável."
                )
            }
            return next.partialValue
        }
    }

    private func significantEntries(in directory: URL) throws -> [URL] {
        try requireSafeDirectory(directory)
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { entry in
            guard entry.lastPathComponent == ".DS_Store" else { return true }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw backupIssue(
                    "backup.symbolic_link",
                    entry.path,
                    "O backup não segue links simbólicos."
                )
            }
            return values.isRegularFile != true
        }
    }

    private func validateNewDestination(_ destinationURL: URL, outside sourceURL: URL) throws {
        guard !destinationURL.lastPathComponent.isEmpty else {
            throw backupIssue(
                "backup.destination",
                destinationURL.path,
                "Escolha uma pasta nova para a operação."
            )
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        try requireSafeDirectoryChain(parentURL)
        guard !itemExistsIncludingSymbolicLink(destinationURL) else {
            throw backupIssue(
                "backup.destination_exists",
                destinationURL.path,
                "Escolha uma pasta nova para a operação."
            )
        }
        let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedParent = parentURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = resolvedParent.appending(
            path: destinationURL.lastPathComponent,
            directoryHint: .isDirectory
        ).standardizedFileURL
        guard !isEqualOrDescendant(resolvedDestination, of: resolvedSource) else {
            throw backupIssue(
                "backup.destination_inside_source",
                destinationURL.path,
                "O destino deve ficar fora da pasta de origem."
            )
        }
    }

    private func newStagingURL(beside destinationURL: URL, prefix: String) throws -> URL {
        let staging = destinationURL.deletingLastPathComponent().appending(
            path: "\(prefix)\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        guard !itemExistsIncludingSymbolicLink(staging) else {
            throw backupIssue(
                "backup.staging_collision",
                staging.path,
                "A pasta temporária da operação já existe."
            )
        }
        return staging
    }

    private func cleanupAfterFailure(
        at stagingURL: URL,
        operation: VaultBackupOperation,
        originalError: Error
    ) throws -> Never {
        guard itemExistsIncludingSymbolicLink(stagingURL) else { throw originalError }
        do {
            try faultInjector?(operation, .beforeCleanup)
            try fileManager.removeItem(at: stagingURL)
        } catch {
            throw backupIssue(
                "backup.cleanup_failed",
                stagingURL.path,
                "A operação falhou e a pasta temporária não pôde ser removida. Remova-a manualmente antes de tentar novamente."
            )
        }
        throw originalError
    }

    private func requireSafeDirectoryChain(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let type = try? fileManager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink,
               current.path != "/tmp",
               current.path != "/var" {
                throw backupIssue(
                    "backup.unsafe_directory",
                    current.path,
                    "O caminho contém um link simbólico."
                )
            }
            current.deleteLastPathComponent()
        }
        try requireSafeDirectory(url)
    }

    private func requireSafeDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw backupIssue(
                "backup.unsafe_directory",
                url.path,
                "Era esperado um diretório sem link simbólico."
            )
        }
    }

    private func requireSafeRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw backupIssue(
                "backup.unsafe_file",
                url.path,
                "Era esperado um arquivo regular sem link simbólico."
            )
        }
    }

    private func itemExistsIncludingSymbolicLink(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.type]) != nil
    }
}

private struct BackupInventory: Equatable {
    let directories: [String]
    let files: [VaultBackupFile]
}

private struct FileHash {
    let byteCount: Int
    let sha256: String
}

private let backupVaultIDPattern =
    "^vlt_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

private func directoryOrder(_ left: String, _ right: String) -> Bool {
    let leftDepth = left.split(separator: "/").count
    let rightDepth = right.split(separator: "/").count
    return leftDepth == rightDepth ? left < right : leftDepth < rightDepth
}

private func backupTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func validBackupTimestamp(_ value: String) -> Bool {
    guard value.hasSuffix("Z") else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isEqualOrDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
}

private func backupIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
