// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

enum EncounterRemoteLinkAction { case enter, whatsApp, email }

struct EncounterRemoteLinkView: View {
    let patientName: String
    let appointmentLabel: String?
    let preparationIssue: String?
    @ObservedObject var controller: GoogleMeetIntegrationController
    let onCancel: () -> Void
    let onSave: (String) throws -> Void
    let onPerform: (String, EncounterRemoteLinkAction) throws -> Void
    @State private var link: String
    @State private var ready: Bool
    @State private var attempted = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showsSharing = false

    init(patientName: String, initialLink: String?, appointmentLabel: String? = nil, preparationIssue: String? = nil,
         controller: GoogleMeetIntegrationController, onCancel: @escaping () -> Void,
         onSave: @escaping (String) throws -> Void,
         onPerform: @escaping (String, EncounterRemoteLinkAction) throws -> Void) {
        self.patientName = patientName; self.appointmentLabel = appointmentLabel; self.preparationIssue = preparationIssue
        self.controller = controller; self.onCancel = onCancel
        self.onSave = onSave; self.onPerform = onPerform
        _link = State(initialValue: initialLink ?? "")
        _ready = State(initialValue: initialLink.flatMap { try? TelemedicineURLBuilder.savedLinkURL($0) } != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Videochamada").font(.title2.weight(.semibold))
                    Text(patientName).foregroundStyle(.secondary)
                    if let appointmentLabel {
                        Label(appointmentLabel, systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Fechar", systemImage: "xmark", action: onCancel)
                    .labelStyle(.iconOnly).buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .disabled(controller.state == .creating)
            }
            if ready {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Link pronto e vinculado à consulta", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(link).font(.callout).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } else if errorMessage == nil {
                ProgressView("Preparando o link…").controlSize(.small)
            }
            HStack(spacing: 14) {
                Button(action: copyLink) { card(copied ? "Copiado" : "Copiar", icon: "doc.on.doc") }
                Button { perform(.enter) } label: { card("Entrar", icon: "video") }
                Button { showsSharing = true } label: { card("Enviar", icon: "paperplane") }
                    .confirmationDialog("Enviar link", isPresented: $showsSharing) {
                        Button("WhatsApp…") { perform(.whatsApp) }
                        Button("E-mail…") { perform(.email) }
                    }
            }
            .buttonStyle(.plain).disabled(!ready)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if !link.isEmpty && !ready { Text(link).font(.caption).textSelection(.enabled) }
                Button("Tentar novamente") { Task { await prepare() } }
                    .disabled(controller.state == .creating)
            }
        }
        .padding(28).frame(width: 580)
        .task {
            guard !attempted else { return }
            attempted = true
            if !ready { await prepare() }
        }
    }

    private func card(_ title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .contentShape(Rectangle())
    }

    @MainActor private func prepare() async {
        errorMessage = nil
        if let preparationIssue { errorMessage = preparationIssue; return }
        if link.isEmpty {
            guard controller.canCreate else {
                errorMessage = "Conecte sua conta em Configurações → Videochamada."
                return
            }
            guard let url = await controller.createSpace() else {
                errorMessage = "Não foi possível criar a sala. Confira a conexão e tente novamente."
                return
            }
            link = url.absoluteString
        }
        // A failed local save retries this same room, never creates a replacement.
        do { try onSave(link); ready = true }
        catch { errorMessage = error.localizedDescription }
    }

    private func copyLink() {
        guard ready else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(link, forType: .string)
    }
    private func perform(_ action: EncounterRemoteLinkAction) {
        do { try onPerform(link, action) }
        catch { errorMessage = error.localizedDescription }
    }
}
