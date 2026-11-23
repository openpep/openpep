// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct DraftTrashView: View {
    let patients: [PatientSummary]
    let onClose: () -> Void
    let onRestore: (PatientSummary, EncounterSummary) throws -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lixeira de rascunhos").font(.title2.weight(.semibold))
            if patients.allSatisfy({ $0.trashedEncounters.isEmpty }) {
                ContentUnavailableView("Lixeira vazia", systemImage: "trash",
                    description: Text("Rascunhos excluídos com conteúdo aparecerão aqui."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(patients, id: \.patientID) { patient in
                            ForEach(patient.trashedEncounters, id: \.metadata.encounterID) { encounter in
                                GroupBox {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(patient.displayName).font(.headline)
                                            if let date = ISO8601DateFormatter().date(from: encounter.metadata.startedAt) {
                                                Text(date, format: .dateTime.day().month().year().hour().minute())
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(preview(encounter))
                                                .lineLimit(3).textSelection(.enabled)
                                        }
                                        Spacer()
                                        Button("Restaurar") {
                                            do { try onRestore(patient, encounter); errorMessage = nil }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }
                            }
                        }
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Fechar", action: onClose).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(minWidth: 600, idealWidth: 720, minHeight: 420, idealHeight: 580)
    }
    private func preview(_ encounter: EncounterSummary) -> String {
        if let page = try? LinearConsultationPage(body: encounter.draft.body),
           !page.consultation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return page.consultation
        }
        return "Rascunho com campos, fatos ou documentos associados."
    }

}
