// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct AddendumContext: Identifiable {
    let patientID: String
    let encounterID: String

    var id: String { encounterID }
}

struct AddendumView: View {
    let patientName: String
    let isSaving: Bool
    let errorMessage: String?
    let requiresAuthentication: Bool
    let authenticationMessage: String
    let onCancel: () -> Void
    let onSave: (String, String) -> Void

    @State private var reason = ""
    @State private var addendumText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Novo adendo", systemImage: "text.badge.plus")
                    .font(.title2.weight(.semibold))
                Text(patientName)
                    .font(.headline)
                Text("O adendo será um novo artefato. A nota final não será modificada.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Motivo da correção")
                        .font(.headline)
                    TextField("Descreva por que este adendo é necessário", text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2...4)
                        .accessibilityHint("Obrigatório; descreve por que o adendo foi criado")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Texto do adendo")
                        .font(.headline)
                    Text("Registre apenas a informação que complementa ou corrige a nota final.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $addendumText)
                        .font(.body)
                        .frame(minHeight: 210)
                        .padding(6)
                        .background(.background)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .accessibilityLabel("Texto do adendo")
                }
            }

            Label(authenticationMessage, systemImage: requiresAuthentication ? "lock.shield" : "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("Erro: \(errorMessage)")
            }

            HStack {
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                if isSaving {
                    ProgressView(requiresAuthentication ? "Autenticando e salvando…" : "Salvando…")
                        .controlSize(.small)
                }
                Button(requiresAuthentication ? "Autenticar e criar adendo" : "Criar adendo") {
                    onSave(reason, addendumText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || addendumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 560)
    }
}
