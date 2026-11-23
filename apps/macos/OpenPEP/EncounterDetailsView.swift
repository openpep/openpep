// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct EncounterDetailsView: View {
    let patientName: String
    let encounter: EncounterMetadata
    let onCancel: () -> Void
    let onSave: (EncounterDetailsInput) throws -> Void

    @State private var modality: AppointmentModality
    @State private var consent: TelemedicineConsent
    @State private var declaredLocation: String
    @State private var participants: String
    @State private var limitations: String
    @State private var contingency: String
    @State private var errorMessage: String?

    init(patientName: String, encounter: EncounterMetadata,
         onCancel: @escaping () -> Void, onSave: @escaping (EncounterDetailsInput) throws -> Void) {
        self.patientName = patientName
        self.encounter = encounter
        self.onCancel = onCancel
        self.onSave = onSave
        _modality = State(initialValue: AppointmentModality(rawValue: encounter.modality) ?? .inPerson)
        _consent = State(initialValue: encounter.telemedicine?.consent ?? .notRecorded)
        _declaredLocation = State(initialValue: encounter.telemedicine?.declaredLocation ?? "")
        _participants = State(initialValue: encounter.telemedicine?.participants.joined(separator: ", ") ?? "")
        _limitations = State(initialValue: encounter.telemedicine?.limitations ?? "")
        _contingency = State(initialValue: encounter.telemedicine?.contingency ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fatos da telemedicina").font(.title2.weight(.semibold))
            Text(patientName).foregroundStyle(.secondary)
            Form {
                if modality == .telemedicine {
                    Section("Fatos da teleconsulta") {
                        Picker("Consentimento", selection: $consent) {
                            Text("Não registrado").tag(TelemedicineConsent.notRecorded)
                            Text("Confirmado").tag(TelemedicineConsent.confirmed)
                            Text("Recusado").tag(TelemedicineConsent.declined)
                        }
                        TextField("Localização declarada", text: $declaredLocation)
                        TextField("Participantes", text: $participants)
                            .help("Separe os participantes por vírgula.")
                        TextField("Limitações observadas", text: $limitations, axis: .vertical).lineLimit(2...4)
                        TextField("Contingência adotada", text: $contingency, axis: .vertical).lineLimit(2...4)
                        Text("Registre apenas o que foi declarado. Campos vazios ficam como não informados.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if encounter.telemedicine != nil || consent != .notRecorded
                    || [declaredLocation, participants, limitations, contingency].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    Text("Ao salvar como presencial, os fatos da teleconsulta serão retirados deste rascunho.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar detalhes") {
                    do {
                        try onSave(EncounterDetailsInput(
                            modality: modality,
                            telemedicine: modality == .telemedicine ? TelemedicineEncounterInput(
                                consent: consent, declaredLocation: declaredLocation,
                                participants: participants.split(separator: ",").map(String.init),
                                limitations: limitations, contingency: contingency
                            ) : nil
                        ))
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 540, idealHeight: 640)
    }
}

struct TelemedicineFactsView: View {
    let facts: TelemedicineEncounterMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Consentimento", value: consentLabel)
            LabeledContent("Localização declarada", value: facts.declaredLocation ?? "Não informada")
            LabeledContent("Participantes", value: facts.participants.isEmpty ? "Não informados" : facts.participants.joined(separator: ", "))
            LabeledContent("Limitações", value: facts.limitations ?? "Não informadas")
            LabeledContent("Contingência", value: facts.contingency ?? "Não informada")
        }
        .textSelection(.enabled)
    }

    private var consentLabel: String {
        switch facts.consent {
        case .confirmed: "Confirmado"
        case .declined: "Recusado"
        case .notRecorded: "Não registrado"
        }
    }
}
