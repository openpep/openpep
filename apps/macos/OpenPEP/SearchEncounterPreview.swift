// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct SearchEncounterPreview: Identifiable {
    let patientID: String
    let patientName: String
    let encounter: EncounterSummary
    var id: String { encounter.metadata.encounterID }
}

struct SearchEncounterPreviewView: View {
    let preview: SearchEncounterPreview
    let canWrite: Bool
    let onClose: () -> Void
    let onAddendum: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.patientName).font(.title2.weight(.semibold))
                    Text(preview.encounter.metadata.startedAt.prefix(10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar", action: onClose).keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch preview.encounter.finalizationStatus {
                    case .draft:
                        Label("Rascunho salvo", systemImage: "square.and.pencil").foregroundStyle(.secondary)
                        ClinicalFormattedText(text: preview.encounter.draft.body)
                    case let .verified(finalization):
                        Label("Consulta finalizada", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                        ClinicalFormattedText(text: finalization.finalNote.body)
                        ForEach(finalization.addenda, id: \.metadata.addendumID) { addendum in
                            Divider()
                            Text("Adendo · \(addendum.metadata.createdAt.prefix(10))").font(.headline)
                            Text(addendum.metadata.reason).foregroundStyle(.secondary)
                            ClinicalFormattedText(text: addendum.body)
                        }
                    case .altered:
                        Label("A consulta precisa de verificação. O conteúdo não será exibido.", systemImage: "exclamationmark.shield")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if preview.encounter.finalizationStatus == .draft {
                    Button("Retomar rascunho", action: onResume).disabled(!canWrite)
                } else if case .verified = preview.encounter.finalizationStatus {
                    Button("Criar adendo…", action: onAddendum).disabled(!canWrite)
                }
            }
        }.padding(24).frame(minWidth: 740, idealWidth: 960, minHeight: 580, idealHeight: 760)
    }
}
