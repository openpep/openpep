// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// One reviewed document, one explicit certificate operation. The caller archives exact bytes.
struct LocalDocumentSigningView: View {
    let document: PreparedClinicalDocument
    let onSigned: (PreparedClinicalDocument) async throws -> Void
    let onClose: () -> Void
    @State private var renderer = CockpitPDFRenderer()
    @State private var preparation: LocalPDFSignaturePreparation?
    @State private var identities: [LocalPDFSigner.Identity] = []
    @State private var selected = ""
    @State private var signed: PreparedClinicalDocument?
    @State private var confirming = false
    @State private var busy = false
    @State private var confirmsDiscard = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Assinar · " + document.title).font(.title2); Spacer(); Button("Fechar") { if signed == nil { onClose() } else { confirmsDiscard = true } }.disabled(busy) }
            Text("Ensaio sintético · certificado local / VIDaaS Connect").foregroundStyle(.secondary)
            ClinicalPDFPreview(data: signed?.data ?? preparation?.pdf ?? document.data)
                .id(SNCRRegistry.hash(signed?.data ?? preparation?.pdf ?? document.data)).frame(minHeight: 420)
            Picker("Certificado", selection: $selected) {
                Text("Selecionar certificado").tag("")
                ForEach(identities) { Text($0.name).tag($0.id) }
            }.disabled(busy || signed != nil)
            HStack {
                Button("Atualizar certificados") { loadIdentities() }.disabled(busy || signed != nil)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(signed == nil ? "Assinar…" : "Tentar guardar PDF") {
                    if signed == nil { confirming = true } else { save() }
                }.buttonStyle(.borderedProminent).disabled(busy || preparation == nil || selected.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(24).frame(minWidth: 600, idealWidth: 800, minHeight: 700)
        .interactiveDismissDisabled(busy || signed != nil)
        .task {
            do { preparation = try await renderer.prepareSignature(document.data); loadIdentities() }
            catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Fechar sem guardar o PDF assinado?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Descartar esta cópia", role: .destructive, action: onClose)
        } message: { Text("A guarda não foi concluída. Fechar descarta esta cópia da assinatura; você pode continuar e tentar guardar novamente.") }
        .confirmationDialog("Assinar o PDF exibido com o certificado selecionado?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Confirmar assinatura") { sign() }
        } message: { Text("O VIDaaS pode solicitar autorização. A operação não será repetida automaticamente.") }
    }
    private func loadIdentities() {
        do { identities = try LocalPDFSigner.identities(); error = identities.isEmpty ? "Abra o VIDaaS Connect e atualize a lista de certificados." : nil }
        catch { self.error = error.localizedDescription }
    }
    private func sign() {
        guard let preparation, let identity = identities.first(where: { $0.id == selected }) else { return }
        busy = true; error = nil
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) { try LocalPDFSigner.sign(preparation, with: identity) }.value
                try LocalPDFSigner.verifyPDF(data, certificate: identity.certificate)
                signed = try PreparedClinicalDocument(title: document.title, data: data, sourceText: document.sourceText,
                    professional: document.professional, doctorIdentity: document.doctorIdentity, createdAt: document.createdAt)
                busy = false; save()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    private func save() {
        guard let signed else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await onSigned(signed); onClose() }
            catch { self.error = "O PDF assinado permanece nesta janela. Tente guardar novamente. " + error.localizedDescription }
        }
    }
}
