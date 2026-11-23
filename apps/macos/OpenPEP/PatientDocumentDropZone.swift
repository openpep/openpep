// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PatientDocumentDropZone: View {
    let patientName: String
    let isEnabled: Bool
    let onChoose: () -> Void
    let onChooseBinding: () -> Void
    let onDropFiles: ([URL]) -> Void
    @State private var isTargeted = false
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onChoose) {
                Image(systemName: "doc.badge.plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Inserir documentos — ou arraste arquivos sobre o card")
            .accessibilityLabel("Inserir documentos em \(patientName)")
            Menu {
                Button("Importar e escolher vínculo…", action: onChooseBinding)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Opções de importação")
            Spacer()
        }
        .foregroundStyle(.secondary)
        .disabled(!isEnabled)
    }
}

/// Accept Finder's public.file-url payload directly, including multi-file drops.
struct PatientFileDropModifier: ViewModifier {
    let isEnabled: Bool
    var patientName: String = "paciente selecionado"
    let onFiles: ([URL]) -> Void
    @State private var isTargeted = false

    @State private var pendingFiles: [URL] = []
    @State private var confirmsImport = false

    static func fileURL(from data: Data) -> URL? {
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
        return url
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor.opacity(isTargeted && isEnabled ? 0.7 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard isEnabled, !providers.isEmpty else { return false }
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let data: Data? = await withCheckedContinuation { continuation in
                            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                                continuation.resume(returning: data)
                            }
                        }
                        if let data, let url = Self.fileURL(from: data) {
                            urls.append(url)
                        }
                    }
                    if !urls.isEmpty { pendingFiles = urls; confirmsImport = true }
                }
                return true
            }
            .sheet(isPresented: $confirmsImport, onDismiss: { pendingFiles = [] }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Inserir documentos?").font(.title2.weight(.semibold))
                    Text(patientName).font(.headline)
                    Text("Confira o paciente antes de incluir os arquivos.").foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(pendingFiles.enumerated()), id: \.offset) { _, url in
                                Label(url.lastPathComponent, systemImage: "doc").lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                    HStack {
                        Spacer()
                        Button("Cancelar", role: .cancel) { confirmsImport = false }.keyboardShortcut(.cancelAction)
                        Button("Inserir \(pendingFiles.count) arquivo(s)") {
                            let files = pendingFiles
                            confirmsImport = false
                            onFiles(files)
                        }.buttonStyle(.borderedProminent).disabled(!isEnabled)
                    }
                }.padding(24).frame(width: 460)
            }
    }
}
