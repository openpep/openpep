// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct DocumentImportContext: Identifiable, Sendable {
    let id = UUID()
    let patientID: String
    let patientName: String
    let vaultURL: URL
    let vaultID: String
    let patientRecord: PatientRecord?
    let items: [DocumentImportBatchItem]
    let encounters: [EncounterSummary]
    let preferredEncounterID: String?
    let allowsChangingEncounter: Bool

    var urls: [URL] { items.map(\.sourceURL) }
}

struct DocumentImportView: View {
    let context: DocumentImportContext
    let errorMessage: String?
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: (String?) -> Void

    @State private var encounterID: String

    init(
        context: DocumentImportContext,
        errorMessage: String?,
        isImporting: Bool,
        onCancel: @escaping () -> Void,
        onImport: @escaping (String?) -> Void
    ) {
        self.context = context
        self.errorMessage = errorMessage
        self.isImporting = isImporting
        self.onCancel = onCancel
        self.onImport = onImport
        _encounterID = State(initialValue: context.preferredEncounterID ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(errorMessage == nil ? "Importar documentos" : "Concluir importação")
                        .font(.title2.weight(.semibold))
                    Text(context.patientName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Cópia local", systemImage: "doc.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                GroupBox(errorMessage == nil ? "Arquivos selecionados" : "Arquivos pendentes") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(context.urls, id: \.standardizedFileURL) { url in
                                Label(url.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                                    .help(url.lastPathComponent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 180)
                }

                Picker("Vincular a", selection: $encounterID) {
                    Text("Somente ao paciente").tag("")
                    ForEach(context.encounters, id: \.metadata.encounterID) { encounter in
                        Text("Consulta de \(displayDate(encounter.metadata.startedAt))")
                            .tag(encounter.metadata.encounterID)
                    }
                }
                .accessibilityHint("O vínculo não altera o conteúdo nem o estado da consulta")
                .disabled(!context.allowsChangingEncounter || isImporting)

                Label(
                    "Arquivos de qualquer formato, até 25 MiB por arquivo. Os originais serão copiados para o prontuário.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Text("A verificação de formato não comprova autenticidade clínica nem ausência de malware.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if isImporting {
                    ProgressView("Copiando e verificando…")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityLabel("Erro de importação: \(errorMessage)")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)
            Divider()

            HStack {
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Spacer()
                Button(errorMessage == nil ? "Importar documentos" : "Tentar novamente") {
                    onImport(encounterID.isEmpty ? nil : encounterID)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
            .padding(18)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
        .interactiveDismissDisabled(isImporting)
    }

    private func displayDate(_ timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: date)
    }
}
