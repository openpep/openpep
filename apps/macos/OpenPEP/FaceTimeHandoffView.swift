// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct FaceTimeHandoffView: View {
    let patientName: String
    let contacts: [TelemedicineContactOption]
    let onCancel: () -> Void
    let onConfirm: (TelemedicineContactOption) -> Void

    @State private var selectedContactID: String

    init(
        patientName: String,
        contacts: [TelemedicineContactOption],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (TelemedicineContactOption) -> Void
    ) {
        self.patientName = patientName
        self.contacts = contacts
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedContactID = State(initialValue: contacts.first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "video.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Abrir FaceTime")
                        .font(.title2.weight(.semibold))
                    Text("Confirme o destinatário antes de continuar.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section("Paciente") {
                    LabeledContent("Nome", value: patientName)
                }

                Section("Destinatário") {
                    Picker("Contato assistencial", selection: $selectedContactID) {
                        ForEach(contacts) { contact in
                            Text("\(contact.typeLabel) · \(contact.displayValue)")
                                .tag(contact.id)
                        }
                    }
                    .accessibilityHint("Escolhe o telefone ou e-mail que será enviado ao FaceTime")
                }

                Section {
                    Label(
                        "O macOS abrirá o FaceTime e pedirá sua confirmação. O OpenPEP não saberá se a chamada conectou ou foi atendida.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Abrir FaceTime") {
                    guard let contact = contacts.first(where: { $0.id == selectedContactID }) else { return }
                    onConfirm(contact)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedContactID.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 390)
    }
}
