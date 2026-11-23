// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

enum WhatsAppDestination: String, CaseIterable, Identifiable {
    case app = "Aplicativo instalado"
    case web = "WhatsApp Web"
    var id: String { rawValue }
}

struct WhatsAppShare: Equatable {
    let phone: String
    let message: String
    let url: URL

    static func conversationURL(patient: PatientSummary, contactID: String, destination: WhatsAppDestination) throws -> URL {
        guard let contact = contacts(for: patient).first(where: { $0.id == contactID }) else {
            throw VaultValidationIssue(rule: "whatsapp.invalid_contact", path: "/contacts",
                message: "Escolha um telefone cadastrado da paciente com código do país.")
        }
        var components = URLComponents()
        components.scheme = destination == .app ? "whatsapp" : "https"
        components.host = destination == .app ? "send" : "web.whatsapp.com"
        components.path = destination == .app ? "" : "/send"
        components.queryItems = [URLQueryItem(name: "phone", value: String(contact.destination.dropFirst()))]
        guard let url = components.url else {
            throw VaultValidationIssue(rule: "whatsapp.invalid_url", path: "/contacts", message: "Telefone inválido.")
        }
        return url
    }

    static func contacts(for patient: PatientSummary) -> [TelemedicineContactOption] {
        TelemedicineContactResolver.options(for: patient).filter {
            $0.type == .phone && $0.destination.hasPrefix("+") &&
            $0.destination.dropFirst().first != "0"
        }
    }

    static func openIfUnchanged(
        appointment: AppointmentSummary?,
        patient: PatientSummary?,
        expectedPatientID: String,
        expectedPatientName: String,
        contactID: String,
        destination: WhatsAppDestination,
        proposal: WhatsAppShare,
        invitation: String? = nil,
        open: (URL) -> Bool
    ) throws -> Bool {
        let issuePath = appointment?.id ?? "/appointment"
        guard let appointment,
              let patient,
              appointment.record.modality == .telemedicine,
              [.scheduled, .arrived, .inProgress].contains(appointment.record.status),
              appointment.record.patientID == expectedPatientID,
              patient.patientID == expectedPatientID,
              patient.patientID == appointment.record.patientID,
              patient.displayName == expectedPatientName,
              let currentProposal = try? WhatsAppShare(
                  patient: patient,
                  contactID: contactID,
                  link: appointment.record.remoteAccessURL,
                  destination: destination,
                  invitation: invitation
              ),
              currentProposal == proposal else {
            throw VaultValidationIssue(
                rule: "whatsapp.changed",
                path: issuePath,
                message: "O agendamento ou contato mudou. Atualize a agenda e revise o compartilhamento novamente."
            )
        }
        return open(currentProposal.url)
    }

    init(patient: PatientSummary, contactID: String, link: String?, destination: WhatsAppDestination, invitation: String? = nil) throws {
        guard let contact = Self.contacts(for: patient).first(where: { $0.id == contactID }) else {
            throw VaultValidationIssue(rule: "whatsapp.invalid_contact", path: "/contacts",
                                       message: "Escolha um telefone cadastrado com + e código do país.")
        }
        let savedURL = try TelemedicineURLBuilder.savedLinkURL(link)
        guard let link, !link.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VaultValidationIssue(rule: "whatsapp.invalid_link", path: "/remote_access_url",
                                       message: "O link contém caracteres de controle. Edite o agendamento.")
        }
        phone = String(contact.destination.dropFirst())
        message = invitation ?? "Olá, segue o link para nossa consulta: \(savedURL.absoluteString)"
        var components = URLComponents()
        components.scheme = destination == .app ? "whatsapp" : "https"
        components.host = destination == .app ? "send" : "web.whatsapp.com"
        components.path = destination == .app ? "" : "/send"
        components.queryItems = [URLQueryItem(name: "phone", value: phone), URLQueryItem(name: "text", value: message)]
        // Web form decoders treat a literal plus as a space, unlike URLComponents.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let built = components.url else {
            throw VaultValidationIssue(rule: "whatsapp.invalid_url", path: "/remote_access_url",
                                       message: "Não foi possível preparar o link para o WhatsApp.")
        }
        url = built
    }
}

struct WhatsAppShareView: View {
    let patient: PatientSummary
    let link: String?
    var invitation: String? = nil
    let onCancel: () -> Void
    let onConfirm: (String, WhatsAppDestination, WhatsAppShare) -> Void
    @State private var contactID = ""
    @State private var destination: WhatsAppDestination = .app

    private var contacts: [TelemedicineContactOption] { WhatsAppShare.contacts(for: patient) }
    private var proposal: WhatsAppShare? {
        try? WhatsAppShare(patient: patient, contactID: contactID, link: link, destination: destination, invitation: invitation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compartilhar link pelo WhatsApp").font(.title2)
            Text(patient.displayName).font(.headline)
            Form {
                Picker("Telefone cadastrado", selection: $contactID) {
                    ForEach(contacts) { Text($0.displayValue).tag($0.id) }
                }
                Picker("Abrir em", selection: $destination) {
                    ForEach(WhatsAppDestination.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if let proposal {
                ScrollView {
                    Text(proposal.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 160)
                .accessibilityLabel("Prévia da mensagem")
            } else {
                Text("É necessário um link HTTPS válido e telefone cadastrado com + e código do país. Corrija o cadastro ou o agendamento.")
                    .foregroundStyle(.secondary)
            }
            Text("O telefone e o link serão enviados ao WhatsApp ao continuar e podem ficar no histórico do navegador. Confira o destinatário e pressione Enviar no WhatsApp. O OpenPEP não confirma entrega. Use somente dados sintéticos nesta versão.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Abrir composição") {
                    if let proposal { onConfirm(contactID, destination, proposal) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(proposal == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 520)
        .onAppear { contactID = contacts.first?.id ?? "" }
    }
}
