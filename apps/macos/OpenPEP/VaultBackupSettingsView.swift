// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum VaultBackupAction {
    case create, verify, restore, rehearse
}

struct VaultBackupSettingsView: View {
    let hasVault: Bool
    let history: VaultBackupHistoryEntry?
    let onAction: (VaultBackupAction) -> Void

    var body: some View {
        GroupBox("Backup e restauração") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Escolha uma pasta ou unidade externa protegida para guardar a cópia. Mantenha uma cópia independente: sincronização com Drive ou iCloud não substitui backup.")
                    .font(.callout)
                if let history {
                    LabeledContent("Última cópia conferida", value: display(history.verifiedAt))
                    LabeledContent("Conteúdo", value: "\(history.fileCount) arquivos · \(ByteCountFormatter.string(fromByteCount: Int64(history.byteCount), countStyle: .file))")
                    if let restoredAt = history.restoredAt {
                        Label("Restauração desta cópia testada em \(display(restoredAt))", systemImage: "checkmark.circle")
                    } else {
                        Label("Restauração desta cópia ainda não testada", systemImage: "arrow.counterclockwise.circle")
                    }
                    Text("Este é um registro da última operação. Ele não confirma a presença da unidade nem inclui alterações posteriores do prontuário.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nenhuma cópia verificada registrada para este prontuário neste Mac.")
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                Button("Ensaiar com dados sintéticos…") { onAction(.rehearse) }
                    .accessibilityHint("Cria 30 pacientes fictícios com agenda, consultas e documentos, faz backup e restaura em pastas novas")
                Text("A restauração cria uma pasta nova e mantém o prontuário aberto. Esta cópia não inclui chaves do Keychain e não acrescenta criptografia ao destino.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Criar backup…") { onAction(.create) }
            .disabled(!hasVault)
        Button("Verificar backup…") { onAction(.verify) }
        Button("Restaurar backup…") { onAction(.restore) }
    }

    private func display(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "pt_BR")))
    }
}
