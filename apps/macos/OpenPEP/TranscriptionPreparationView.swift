// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone synthetic laboratory; no access to patients, notes or the clinical vault.
struct TranscriptionPreparationView: View {
    let onClose: () -> Void
    @State private var confirmsSynthetic = false
    @State private var task: Task<Void, Never>?
    @State private var text = ""
    @State private var status = "Escolha um áudio fictício para testar o reconhecimento local em português."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Laboratório de transcrição local").font(.title2)
            Text("Preparação experimental · somente áudio sintético")
                .font(.headline)
            Text("O arquivo será processado no Mac. Não há gravação de microfone, captura do FaceTime, envio à nuvem nem inserção no prontuário. O áudio original não será copiado ou apagado pelo OpenPEP.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Confirmo que o áudio é fictício e não contém dados de pacientes", isOn: $confirmsSynthetic)
                .disabled(task != nil)
            HStack {
                Button("Escolher áudio e transcrever…", action: chooseAudio)
                    .disabled(!confirmsSynthetic || task != nil)
                if task != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancelar transcrição") { task?.cancel() }
                }
            }
            Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text.isEmpty ? "O resultado aparecerá aqui para inspeção." : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            .accessibilityLabel("Resultado experimental da transcrição")
            Text("Confira omissões, nomes, números e negações. Este ensaio não valida a qualidade clínica. O resultado não é guardado; fechar descarta o texto desta tela.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Fechar") { discard(); onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 480)
        .onDisappear { discard() }
    }

    @MainActor
    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "Escolher áudio sintético"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = panel.runModal()
        confirmsSynthetic = false
        guard response == .OK, let url = panel.url else { return }
        text = ""
        status = "Verificando modelo local e transcrevendo…"
        task = Task { @MainActor in
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted { url.stopAccessingSecurityScopedResource() }
                task = nil
            }
            do {
                let draft = try await LocalTranscriptionService().transcribeImportedAudio(at: url)
                try Task.checkCancellation()
                text = draft.text
                status = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Nenhuma fala reconhecida. Confira o áudio sintético e tente novamente."
                    : "Transcrição local concluída (\(draft.localeIdentifier)). Resultado não salvo."
            } catch is CancellationError {
                status = "Transcrição cancelada. Nenhum resultado foi salvo."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func discard() {
        task?.cancel()
        text = ""
        confirmsSynthetic = false
    }
}
