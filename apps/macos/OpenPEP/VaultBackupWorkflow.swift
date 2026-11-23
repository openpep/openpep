// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

struct VaultBackupWorkflowResult: Sendable {
    let backup: VaultBackupSummary
    let didRestore: Bool
    let message: String
    let revealURL: URL?
}

/// Native choices and confirmations; filesystem validation lives in VaultBackupService.
@MainActor
struct VaultBackupWorkflow {
    func run(_ action: VaultBackupAction, currentVaultURL: URL?) async throws -> VaultBackupWorkflowResult? {
        switch action {
        case .create:
            guard let currentVaultURL else { return nil }
            return try await create(from: currentVaultURL)
        case .verify, .restore:
            return try await inspectOrRestore(action, currentVaultURL: currentVaultURL)
        case .rehearse:
            return try await rehearse(outside: currentVaultURL)
        }
    }

    private func create(from vaultURL: URL) async throws -> VaultBackupWorkflowResult? {
        guard let parent = chooseDirectory(
            title: "Onde guardar o backup?",
            message: "Escolha uma pasta ou unidade externa protegida, fora do prontuário. A cópia não acrescenta criptografia ao destino.",
            prompt: "Escolher destino"
        ) else { return nil }
        let granted = parent.startAccessingSecurityScopedResource()
        defer { if granted { parent.stopAccessingSecurityScopedResource() } }
        let destination = parent.appending(path: "backup-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try requireOutside(destination, source: vaultURL)
        guard confirm(title: "Criar backup do prontuário?", message:
            "Origem: \(vaultURL.path)\nDestino: \(destination.path)\n\nTodos os arquivos regulares serão copiados e conferidos, inclusive conteúdo não gerenciado. A restauração desta cópia ainda precisará ser testada.",
            action: "Criar backup") else { return nil }
        let backup = try await Task.detached(priority: .userInitiated) {
            try VaultBackupService().create(from: vaultURL, to: destination)
        }.value
        return VaultBackupWorkflowResult(
            backup: backup, didRestore: false,
            message: "Backup criado e verificado: \(backup.manifest.fileCount) arquivos. Restauração ainda não testada. Pasta: \(backup.packageURL.path)",
            revealURL: backup.packageURL
        )
    }

    private func inspectOrRestore(_ action: VaultBackupAction, currentVaultURL: URL?) async throws -> VaultBackupWorkflowResult? {
        guard let package = chooseDirectory(
            title: action == .verify ? "Verificar backup" : "Restaurar backup",
            message: "Escolha a pasta de backup que contém manifest.json e vault.",
            prompt: "Escolher backup", canCreate: false
        ) else { return nil }
        let sourceGranted = package.startAccessingSecurityScopedResource()
        defer { if sourceGranted { package.stopAccessingSecurityScopedResource() } }
        let verified = try await Task.detached(priority: .userInitiated) {
            try VaultBackupService().verify(at: package)
        }.value
        if action == .verify {
            return VaultBackupWorkflowResult(
                backup: verified, didRestore: false,
                message: "Backup conferido agora: \(verified.manifest.fileCount) arquivos. A conferência dos hashes não substitui o teste de restauração. Origem: \(package.path)",
                revealURL: nil
            )
        }
        guard let parent = chooseDirectory(
            title: "Onde restaurar o prontuário?",
            message: "Uma pasta nova será criada. O prontuário aberto será mantido.",
            prompt: "Escolher destino"
        ) else { return nil }
        let destinationGranted = parent.startAccessingSecurityScopedResource()
        defer { if destinationGranted { parent.stopAccessingSecurityScopedResource() } }
        let destination = parent.appending(path: "restaurado-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try requireOutside(destination, source: package)
        if let currentVaultURL { try requireOutside(destination, source: currentVaultURL) }
        guard confirm(title: "Restaurar em uma pasta nova?", message:
            "Backup: \(package.path)\nProntuário: \(verified.manifest.vaultID)\nCópia de: \(verified.manifest.createdAt)\nDestino: \(destination.path)\n\nA cópia será verificada novamente e a pasta restaurada será validada. Ela não será aberta automaticamente para edição.",
            action: "Restaurar") else { return nil }
        let restored = try await Task.detached(priority: .userInitiated) {
            try VaultBackupService().restore(from: package, to: destination, expectedManifestSHA256: verified.manifestSHA256)
        }.value
        return VaultBackupWorkflowResult(
            backup: restored.backup, didRestore: true,
            message: "Restauração concluída e conferida em \(restored.vaultURL.path). O prontuário aberto foi mantido. Para usar a cópia, escolha essa pasta em Abrir prontuário.",
            revealURL: restored.vaultURL
        )
    }

    private func rehearse(outside currentVaultURL: URL?) async throws -> VaultBackupWorkflowResult? {
        guard let parent = chooseDirectory(
            title: "Ensaiar backup e restauração",
            message: "Escolha onde criar 10 pacientes fictícios com consultas, documentos e agenda preenchida, seu backup e a restauração. O ensaio não usa o prontuário aberto.",
            prompt: "Escolher destino"
        ) else { return nil }
        let granted = parent.startAccessingSecurityScopedResource()
        defer { if granted { parent.stopAccessingSecurityScopedResource() } }
        let root = parent.appending(path: "ensaio-backup-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        if let currentVaultURL { try requireOutside(root, source: currentVaultURL) }
        guard confirm(title: "Executar o ensaio sintético?", message:
            "Destino: \(root.path)\n\nSerão criados 10 pacientes sintéticos com agenda em torno de hoje, consultas e documentos, uma cópia verificada e uma restauração em pasta separada. As pastas ficarão disponíveis para inspeção. Não use seus contatos para enviar mensagens ou iniciar chamadas.",
            action: "Executar ensaio") else { return nil }
        let restored = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            do {
                let now = Date()
                let original = try SyntheticReleaseSeeder().seed(in: root, at: now)
                let backup = try VaultBackupService().create(from: original.url, to: root.appending(path: "backup", directoryHint: .isDirectory))
                let restored = try VaultBackupService().restore(from: backup.packageURL, to: root.appending(path: "restaurado", directoryHint: .isDirectory))
                let reopened = try VaultReader().open(restored.vaultURL)
                guard reopened.manifest == original.manifest,
                      ClinicalSearchIndex(patients: reopened.patients) == ClinicalSearchIndex(patients: original.patients) else {
                    throw VaultValidationIssue(rule: "backup.rehearsal_mismatch", path: root.path,
                                               message: "O prontuário restaurado diverge da origem sintética.")
                }
                return restored
            } catch {
                throw VaultValidationIssue(rule: "backup.rehearsal_failed", path: root.path,
                                           message: "O ensaio falhou. As pastas sintéticas criadas foram preservadas para inspeção. \(error.localizedDescription)")
            }
        }.value
        return VaultBackupWorkflowResult(
            backup: restored.backup, didRestore: true,
            message: "Ensaio concluído: 10 pacientes fictícios com agenda, consultas e documentos foram copiados, restaurados e reabertos. Isso não testa o backup do seu prontuário atual. Abra a pasta restaurado para explorar. Pastas: \(root.path)",
            revealURL: root
        )
    }

    private func chooseDirectory(title: String, message: String, prompt: String, canCreate: Bool = true) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requireOutside(_ destination: URL, source: URL) throws {
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw VaultValidationIssue(rule: "backup.destination_inside_source", path: destination.path,
                                       message: "Escolha um destino fora do prontuário e da cópia de origem.")
        }
    }
}
