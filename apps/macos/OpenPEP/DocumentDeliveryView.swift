// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct DocumentDelivery: Identifiable {
    let id = UUID()
    let files: [URL]
}

/// Handoff only: the user completes sending in their chosen app.
struct DocumentDeliveryView: View {
    let files: [URL]
    let patient: PatientSummary?
    let onClose: () -> Void
    let onCompleted: () -> Void
    @State private var message = "Olá, seguem os documentos da sua consulta. Em caso de dúvida, entre em contato com o consultório."
    @State private var channel = PatientContactType.email
    @State private var contactID = ""
    @State private var opened = false
    @State private var error: String?
    @State private var mailService: NSSharingService?

    private var contacts: [TelemedicineContactOption] {
        guard let patient else { return [] }
        return channel == .email ? ConsultationInvitation.emailContacts(for: patient) : WhatsAppShare.contacts(for: patient)
    }
    static func validContactID(_ selected: String, available: [String]) -> String {
        available.contains(selected) ? selected : (available.first ?? "")
    }
    /// Pass the archived PDFs themselves to the sharing service, without rendering a second copy.
    static func attachmentItems(files: [URL], message: String) throws -> [Any] {
        guard !files.isEmpty else { throw CockpitError.message("Nenhum PDF foi selecionado.") }
        for file in files {
            guard file.isFileURL, file.pathExtension.lowercased() == "pdf",
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CockpitError.message("O anexo selecionado não é um arquivo PDF local.")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 5) == Data("%PDF-".utf8) else {
                throw CockpitError.message("Não foi possível conferir o PDF antes de preparar o envio.")
            }
        }
        return [message] + files.map { $0 as Any }
    }
    private var effectiveContactID: String { Self.validContactID(contactID, available: contacts.map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Enviar documentos").font(.title2.weight(.semibold))
                Spacer()
                Button("Fechar", systemImage: "xmark", action: onClose).labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
            }
            if let patient { Text(patient.displayName).font(.headline) }
            Picker("Enviar por", selection: $channel) {
                Text("E-mail").tag(PatientContactType.email)
                Text("WhatsApp").tag(PatientContactType.phone)
            }.pickerStyle(.segmented)
            Picker(channel == .email ? "E-mail" : "Telefone", selection: Binding(get: { effectiveContactID }, set: { contactID = $0 })) {
                Text("Selecionar contato").tag("")
                ForEach(contacts) { Text($0.displayValue).tag($0.id) }
            }
            if contacts.isEmpty { Text("Inclua um contato válido no cadastro do paciente.").foregroundStyle(.secondary) }
            TextField("Mensagem", text: $message, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
            Text("\(files.count) arquivo(s)").font(.callout).foregroundStyle(.secondary)
            if channel == .phone {
                Text("O WhatsApp abre com a mensagem. Anexe os arquivos que serão mostrados no Finder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if opened { Button("Já enviei", action: onCompleted) }
                Spacer()
                Button(channel == .email ? "Abrir e-mail" : "Abrir WhatsApp") { compose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!contacts.contains { $0.id == effectiveContactID } || files.isEmpty)
            }
        }.padding(24).frame(width: 520)
        .onAppear { contactID = contacts.first?.id ?? "" }
        .onChange(of: channel) { _, _ in contactID = contacts.first?.id ?? ""; opened = false; error = nil }
    }
    private func compose() {
        guard let contact = contacts.first(where: { $0.id == effectiveContactID }) else { return }
        error = nil
        let items: [Any]
        do { items = try Self.attachmentItems(files: files, message: message) }
        catch { self.error = error.localizedDescription; return }
        if channel == .email {
            guard let service = NSSharingService(named: .composeEmail) else { error = "Nenhum aplicativo de e-mail disponível."; return }
            service.recipients = [contact.destination]
            service.subject = "Documentos da consulta"
            guard service.canPerform(withItems: items) else { error = "Não foi possível preparar os anexos no e-mail."; return }
            mailService = service
            service.perform(withItems: items)
            opened = true
        } else {
            var url = URLComponents(string: "https://web.whatsapp.com/send")!
            url.queryItems = [URLQueryItem(name: "phone", value: String(contact.destination.dropFirst())), URLQueryItem(name: "text", value: message)]
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let target = url.url, NSWorkspace.shared.open(target) else { error = "Não foi possível abrir o WhatsApp."; return }
            NSWorkspace.shared.activateFileViewerSelecting(files)
            opened = true
        }
    }
}
