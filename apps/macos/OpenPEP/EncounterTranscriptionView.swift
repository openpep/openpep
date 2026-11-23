// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EncounterTranscriptionView: View {
    @ObservedObject var session: EncounterTranscriptionSession
    let onClose: () -> Void
    @State private var confirmsSyntheticConsent = false
    @State private var recordsTelecall = false
    @State private var applications: [TeleconsultAudioApplication] = []
    @State private var selectedApplicationID: String?
    @State private var applicationStatus: String?
    @State private var applicationLoadFailed = false
    @State private var isLoadingApplications = false
    @State private var applicationTask: Task<Void, Never>?
    @State private var applicationLoadID: UUID?
    @State private var transcriptionMode: ConsultationTranscriptionMode = .appleLive
    @AppStorage(AITextSettings.consultationSummaryProviderKey)
    private var summaryProvider = AITextSettings.defaultConsultationSummaryProvider
    @AppStorage(AITextSettings.consultationSummaryEnabledKey)
    private var allowsOpenAISummary = false
    @AppStorage(AITextSettings.liveTranscriptionEnabledKey)
    private var allowsLiveTranscription = false
    @AppStorage(AITextSettings.consultationSummaryModelKey)
    private var summaryModel = AITextSettings.defaultConsultationSummaryModel
    @State private var summaryIntervalMinutes = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcrição · " + (session.binding?.patientName ?? "Consulta")).font(.title2)
            Text("Você pode fechar esta janela e continuar trabalhando. A gravação continua até usar Parar na faixa superior.")
                .font(.callout).foregroundStyle(.secondary)
            if session.isPrepared && !session.isBusy && session.transcript == nil {
                if session.scopeURL == nil {
                    GroupBox("Acompanhamento durante a consulta") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Transcrição", selection: $transcriptionMode) {
                                Text("Apple ao vivo neste Mac").tag(ConsultationTranscriptionMode.appleLive)
                                Text("OpenAI ao vivo").tag(ConsultationTranscriptionMode.openAILive)
                                Text("Apple após parar").tag(ConsultationTranscriptionMode.appleAfterRecording)
                            }
                            .pickerStyle(.segmented)
                            Text(transcriptionModeDescription)
                                .font(.caption).foregroundStyle(.secondary)
                            if transcriptionMode == .openAILive && !allowsLiveTranscription {
                                Label("Ative o envio de áudio em Configurações antes de iniciar.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            Picker("Resumo", selection: $summaryProvider) {
                                Text("OpenAI").tag(ProgressiveSummaryProvider.openAI.rawValue)
                                Text("Apple neste Mac").tag(ProgressiveSummaryProvider.apple.rawValue)
                            }
                            .pickerStyle(.segmented)
                            Text(summaryProvider == ProgressiveSummaryProvider.openAI.rawValue
                                 ? "Somente texto estabilizado é enviado para o resumo configurado na OpenAI."
                                 : "A Apple gera o resumo neste Mac ao encerrar a gravação.")
                                .font(.caption).foregroundStyle(.secondary)
                            if summaryProvider == ProgressiveSummaryProvider.openAI.rawValue
                                && !allowsOpenAISummary {
                                Label("Ative o envio de texto para resumo em Configurações antes de iniciar.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            if summaryProvider == ProgressiveSummaryProvider.openAI.rawValue {
                                Picker("Intervalo do resumo", selection: $summaryIntervalMinutes) {
                                    Text("1 min").tag(1)
                                    Text("3 min").tag(3)
                                    Text("4 min").tag(4)
                                    Text("5 min").tag(5)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        .disabled(session.isRecording)
                    }
                    Picker("Fonte da gravação", selection: $recordsTelecall) {
                        Text("Somente microfone").tag(false)
                        Text("Microfone e telechamada").tag(true)
                    }
                    .onChange(of: recordsTelecall) { confirmsSyntheticConsent = false }
                    if recordsTelecall {
                        HStack {
                            Picker("Aplicativo da chamada", selection: $selectedApplicationID) {
                                Text("Escolha um aplicativo").tag(String?.none)
                                ForEach(applications) { app in
                                    Text(app.name).tag(Optional(app.id))
                                }
                            }
                            .onChange(of: selectedApplicationID) { confirmsSyntheticConsent = false }
                            Button("Atualizar aplicativos", action: loadApplications)
                                .disabled(isLoadingApplications)
                        }
                        if let applicationStatus {
                            if applicationLoadFailed {
                                Label(applicationStatus, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.red)
                            } else {
                                Text(applicationStatus).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if selectedApplication?.isBrowser == true {
                            Label("Outras abas e janelas deste navegador também podem ser gravadas. Feche conteúdos alheios ao ensaio.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("O macOS pode solicitar acesso ao áudio e à gravação da tela. O OpenPEP recebe somente áudio, sem imagens.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Todos consentiram com a gravação; usarei somente falas sintéticas.",
                           isOn: $confirmsSyntheticConsent)
                    Button(recordsTelecall ? "Gravar telechamada…" : "Gravar pelo microfone…",
                           systemImage: "mic", action: chooseDestination)
                        .disabled(!confirmsSyntheticConsent || isLoadingApplications
                                  || (recordsTelecall && selectedApplication == nil)
                                  || (transcriptionMode == .openAILive && !allowsLiveTranscription)
                                  || (summaryProvider == ProgressiveSummaryProvider.openAI.rawValue
                                      && !allowsOpenAISummary))
                }
                if let url = session.scopeURL {
                    Button("Transcrever gravação") { session.transcribe(url: url) }
                }
                Button("Escolher áudio…", action: chooseAudio)
                    .disabled(summaryProvider == ProgressiveSummaryProvider.openAI.rawValue
                              && !allowsOpenAISummary)
                Text("Áudio escolhido é transcrito localmente pela Apple; a opção ao vivo se aplica somente a uma nova gravação.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.isRecording {
                Button("Parar gravação", systemImage: "stop.fill") { session.stop() }
            } else if session.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Cancelar") { session.cancel() }
                }
            }
            Text(session.status).font(.callout).textSelection(.enabled)
            if let transcript = session.transcript {
                ScrollView {
                    Text(transcript.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 180)
                if !session.saved {
                    HStack {
                        Button("Tentar guardar novamente") { session.retryPersist() }
                        Button("Salvar cópia para recuperação…", action: saveRecoveryCopy)
                    }.disabled(session.isBusy)
                }
                Text("Confira o reconhecimento. A transcrição é um documento da consulta; não substitui sua nota.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(recordingPrivacyDescription)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                if !session.isBusy && session.canReset {
                    Button("Encerrar sessão de transcrição") {
                        if session.reset() { onClose() }
                    }
                }
                Spacer()
                Button("Continuar trabalhando", action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 650, minHeight: 420)
        .onChange(of: session.isRecording) { _, recording in
            if recording { onClose() }
        }
        .onDisappear { applicationTask?.cancel() }
    }

    private var selectedApplication: TeleconsultAudioApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    private func loadApplications() {
        applicationTask?.cancel()
        let operationID = UUID()
        applicationLoadID = operationID
        confirmsSyntheticConsent = false
        selectedApplicationID = nil
        isLoadingApplications = true
        applicationStatus = "Procurando aplicativos abertos…"
        applicationLoadFailed = false
        applicationTask = Task { @MainActor in
            defer {
                if applicationLoadID == operationID { isLoadingApplications = false }
            }
            do {
                let found = try await session.availableTelecallApplications()
                try Task.checkCancellation()
                guard applicationLoadID == operationID else { return }
                applications = found
                applicationStatus = found.isEmpty
                    ? "Abra o FaceTime, Safari ou Google Chrome e atualize a lista."
                    : "Escolha o aplicativo usado na chamada sintética."
            } catch is CancellationError {
                return
            } catch {
                guard applicationLoadID == operationID, !Task.isCancelled else { return }
                applications = []
                applicationLoadFailed = true
                applicationStatus = error.localizedDescription
            }
        }
    }

    private func chooseDestination() {
        let application = recordsTelecall ? selectedApplication : nil
        guard !recordsTelecall || application != nil else { return }
        let consent = confirmsSyntheticConsent
        configureProgressive(source: recordsTelecall ? .telecall : .microphone,
                             transcriptionMode: transcriptionMode)
        let panel = NSSavePanel()
        panel.title = "Guardar gravação sintética"
        let usesWAV = recordsTelecall || transcriptionMode.isLive
        panel.allowedContentTypes = usesWAV ? [.wav] : [.mpeg4Audio]
        panel.nameFieldStringValue = "gravacao-\(UUID().uuidString.prefix(8))." + (usesWAV ? "wav" : "m4a")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let application {
                await session.startTelecallRecording(at: url, application: application, consent: consent)
            } else {
                await session.startRecording(at: url, consent: consent)
            }
        }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configureProgressive(source: .imported, transcriptionMode: .appleAfterRecording)
        session.transcribe(url: url)
        onClose()
    }

    private func configureProgressive(
        source: ConsultationCaptureSource,
        transcriptionMode: ConsultationTranscriptionMode
    ) {
        let provider = ProgressiveSummaryProvider(rawValue: summaryProvider) ?? .openAI
        session.configureProgressive(.init(
            source: source,
            transcriptionMode: transcriptionMode,
            summaryIntervalSeconds: summaryIntervalMinutes * 60,
            summaryProvider: provider,
            summaryModel: provider == .openAI ? summaryModel : nil
        ))
    }

    private var transcriptionModeDescription: String {
        switch transcriptionMode {
        case .appleLive:
            "O áudio é reconhecido neste Mac durante a gravação. Na primeira vez, o macOS pode baixar os ativos Apple de português."
        case .openAILive:
            "O áudio será enviado para transcrição ao vivo na OpenAI após você iniciar."
        case .appleAfterRecording:
            "O áudio fica no Mac e é transcrito pela Apple depois de parar a gravação."
        }
    }

    private var recordingPrivacyDescription: String {
        switch transcriptionMode {
        case .appleLive:
            "Até 60 minutos · gravação e reconhecimento permanecem neste Mac."
        case .openAILive:
            "Até 60 minutos · o arquivo permanece no destino escolhido e o áudio é enviado à OpenAI durante a captura."
        case .appleAfterRecording:
            "Até 60 minutos · processamento local após parar. O áudio permanece no destino escolhido."
        }
    }

    private func saveRecoveryCopy() {
        guard let transcript = session.transcript else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcricao.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcript.text.write(to: url, atomically: true, encoding: .utf8)
            session.markRecovered()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct EncounterRecordingStatusView: View {
    @ObservedObject var session: EncounterTranscriptionSession
    let onShow: () -> Void
    let onReturn: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let binding = session.binding {
            HStack(spacing: 12) {
                Image(systemName: session.isRecording ? "mic.fill" : "waveform")
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: session.isRecording && !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(binding.patientName).font(.callout.weight(.semibold))
                    Text(session.status).font(.caption).lineLimit(2)
                }
                if session.isRecording, let start = session.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .monospacedDigit().accessibilityLabel("Gravação: \(seconds) segundos")
                    }
                    Button("Parar", systemImage: "stop.fill") { session.stop() }
                }
                Spacer(minLength: 0)
                Button("Consulta", action: onReturn)
                Button("Ver transcrição…", action: onShow)
                if !session.isBusy && session.canReset {
                    Button { _ = session.reset() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar sessão de transcrição")
                }
            }
            .padding(10).background(.bar)
        }
    }
}
