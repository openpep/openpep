// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

enum ConsultationInvitation {
    static func text(for appointment: AppointmentRecord, consultationOpen: Bool) throws -> String {
        let url = try TelemedicineURLBuilder.savedLinkURL(appointment.remoteAccessURL)
        if consultationOpen {
            return "Olá, segue o link para nossa consulta: \(url.absoluteString)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = TimeZone(identifier: appointment.timeZone)
        formatter.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        return """
        Olá,

        Sua consulta está agendada para \(formatter.string(from: appointment.startDate)) (\(appointment.timeZone)).

        Para participar da teleconsulta, acesse:
        \(url.absoluteString)

        Recomendamos entrar alguns minutos antes, em um ambiente reservado, e verificar sua conexão, câmera e microfone.

        Atenciosamente,
        Equipe de atendimento
        """
    }

    static func emailContacts(for patient: PatientSummary) -> [TelemedicineContactOption] {
        TelemedicineContactResolver.options(for: patient).filter {
            // Exactly one mailbox; never permit headers, lists or mailto parameters.
            $0.type == .email && !$0.destination.contains(where: { ",;<>?&#\"".contains($0) })
        }
    }

    static func emailUnavailableReason(for patient: PatientSummary) -> String? {
        guard emailContacts(for: patient).isEmpty else { return nil }
        guard let record = patient.record, record.status == .active else {
            return "O cadastro do paciente não está ativo ou disponível."
        }
        let emails = record.contacts.filter { $0.type == .email }
        if emails.isEmpty {
            return "Não há contato do tipo E-mail neste cadastro. Em Editar dados do paciente, adicione um contato e selecione o tipo E-mail."
        }
        return "O e-mail não tem um formato utilizável. Confira o endereço no cadastro; informe apenas um endereço por contato, sem nome, espaços ou lista de destinatários."
    }

    static func validate(
        expected: AppointmentSummary, current: AppointmentSummary?,
        patient: PatientSummary?, contactID: String, expectedRecipient: String
    ) throws {
        guard let current, current.record == expected.record,
              current.record.modality == .telemedicine,
              [.scheduled, .arrived, .inProgress].contains(current.record.status),
              let patient, patient.patientID == current.record.patientID,
              emailContacts(for: patient).contains(where: {
                  $0.id == contactID && $0.destination == expectedRecipient
              }) else {
            throw VaultValidationIssue(rule: "invitation.changed", path: expected.id,
                message: "O agendamento ou contato mudou. Reabra o convite e confira o destinatário.")
        }
    }

    @MainActor
    static func attributedBody(_ text: String, link: URL) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph
        ])
        let range = (text as NSString).range(of: link.absoluteString)
        if range.location != NSNotFound {
            result.addAttributes([.link: link, .font: NSFont.boldSystemFont(ofSize: 15)], range: range)
        }
        return result
    }
}

struct EmailInvitationView: View {
    let patient: PatientSummary
    let message: String
    let onCancel: () -> Void
    let onCompose: (String, String) -> Void
    var cancelLabel = "Fechar convite"
    @State private var contactID: String

    init(patient: PatientSummary, message: String, onCancel: @escaping () -> Void,
         onCompose: @escaping (String, String) -> Void, cancelLabel: String = "Fechar convite") {
        self.patient = patient
        self.message = message
        self.onCancel = onCancel
        self.onCompose = onCompose
        self.cancelLabel = cancelLabel
        _contactID = State(initialValue: ConsultationInvitation.emailContacts(for: patient).first?.id ?? "")
    }

    private var contacts: [TelemedicineContactOption] { ConsultationInvitation.emailContacts(for: patient) }
    private var selected: TelemedicineContactOption? { contacts.first { $0.id == contactID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enviar link por e-mail").font(.title2)
            Text("Para: \(patient.displayName)").font(.headline)
            if !contacts.isEmpty {
            Picker("E-mail do paciente", selection: $contactID) {
                ForEach(contacts) { Text($0.displayValue).tag($0.id) }
            }
            }
            if let reason = ConsultationInvitation.emailUnavailableReason(for: patient) {
                Text(reason)
                    .foregroundStyle(.secondary)
            }
            ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 180, maxHeight: 300)
            Text("Abre uma composição formatada no Mail. Confira o destinatário e envie por lá. A conta Google conectada ao Meet não é usada como destinatário. Entrega não confirmada pelo OpenPEP.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(cancelLabel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Abrir e-mail") {
                    if let selected { onCompose(selected.id, selected.destination) }
                }
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 560)
    }
}
