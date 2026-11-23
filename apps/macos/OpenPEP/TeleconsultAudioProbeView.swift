// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct TeleconsultAudioProbeView: View {
    let onClose: () -> Void
    @StateObject private var model: TeleconsultAudioProbeModel
    @State private var operation: Task<Void, Never>?

    init(onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TeleconsultAudioProbeModel())
        self.onClose = onClose
    }

    init(model: TeleconsultAudioProbeModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnóstico de áudio da teleconsulta")
                .font(.title2)
            Label("Ensaio sintético · nada é gravado", systemImage: "waveform.badge.mic")
                .font(.headline)
            Text("O OpenPEP mede, em memória, o áudio do aplicativo escolhido e do microfone. Não recebe, exibe nem armazena imagens, não salva áudio, não envia dados e não inicia transcrição.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Fonte da teleconsulta") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Aplicativo", selection: $model.selectedApplicationID) {
                        Text("Escolha um aplicativo").tag(String?.none)
                        ForEach(model.applications) { application in
                            Text(application.name).tag(Optional(application.id))
                        }
                    }
                    .disabled(configurationLocked)
                    .onChange(of: model.selectedApplicationID) {
                        model.confirmsSyntheticConsent = false
                    }

                    if model.selectedApplication?.isBrowser == true {
                        Label(
                            "O medidor pode receber áudio de outras abas e janelas deste navegador, não somente da reunião.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(
                        "Confirmo o consentimento de todas as pessoas e que este ensaio usa somente conteúdo sintético, sem dados de pacientes",
                        isOn: $model.confirmsSyntheticConsent
                    )
                    .disabled(configurationLocked)

                    HStack {
                        Button("Atualizar aplicativos") {
                            run { await model.loadApplications() }
                        }
                        .disabled(configurationLocked)

                        Spacer()

                        if model.state == .capturing {
                            Button("Parar diagnóstico", role: .destructive) {
                                operation?.cancel()
                                run { await model.stop() }
                            }
                        } else {
                            Button("Iniciar diagnóstico") {
                                run { await model.start() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canStart)
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Níveis ao vivo") {
                VStack(alignment: .leading, spacing: 12) {
                    audioMeter(
                        title: "Áudio do aplicativo",
                        systemImage: "speaker.wave.2",
                        level: model.levels.application
                    )
                    audioMeter(
                        title: "Microfone",
                        systemImage: "mic",
                        level: model.levels.microphone
                    )
                }
                .padding(.top, 4)
            }

            statusView

            HStack {
                Spacer()
                Button("Fechar") {
                    operation?.cancel()
                    Task { @MainActor in
                        await model.dismiss()
                        onClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 520)
        .task { await model.loadApplications() }
        .onDisappear {
            operation?.cancel()
            Task { @MainActor in await model.dismiss() }
        }
    }

    private var configurationLocked: Bool {
        model.state == .loadingApplications || model.state == .starting
            || model.state == .capturing || model.state == .stopping
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle:
            Label("Diagnóstico inativo", systemImage: "stop.circle")
        case .loadingApplications:
            Label("Procurando aplicativos abertos…", systemImage: "arrow.clockwise")
        case .ready:
            Label("Pronto para iniciar", systemImage: "checkmark.circle")
        case .starting:
            Label("Solicitando acesso e iniciando os medidores…", systemImage: "hourglass")
        case .capturing:
            Label("Medindo áudio agora · nada é salvo", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .stopping:
            Label("Interrompendo captura…", systemImage: "stop.circle")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func audioMeter(title: String, systemImage: String, level: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
            ProgressView(value: level, total: 1)
                .accessibilityLabel(title)
                .accessibilityValue(levelDescription(level))
            Text(levelDescription(level))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func levelDescription(_ level: Double) -> String {
        switch level {
        case 0..<0.01: "Sem sinal detectado"
        case 0..<0.1: "Sinal baixo"
        case 0..<0.5: "Sinal detectado"
        default: "Sinal alto"
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        operation?.cancel()
        operation = Task { @MainActor in await action() }
    }
}
