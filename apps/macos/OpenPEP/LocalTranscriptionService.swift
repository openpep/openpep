// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFAudio
import Foundation
import Speech

enum LocalTranscriptionAvailability: Equatable, Sendable {
    case ready(localeIdentifier: String)
    case speechUnavailable
    case localeUnsupported(localeIdentifier: String)
    case assetsNotInstalled(localeIdentifier: String)
}

struct LocalTranscriptionDraft: Equatable, Sendable {
    let text: String
    let localeIdentifier: String
}

enum LocalTranscriptionIssue: Error, LocalizedError, Equatable, Sendable {
    case speechUnavailable
    case localeUnsupported(String)
    case assetsNotInstalled(String)
    case assetInstallationFailed(String)
    case invalidAudioFile
    case noAudioSamples
    case alreadyTranscribing
    case engineFailure

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            "A transcrição local não está disponível neste Mac. Nenhum serviço externo foi usado."
        case let .localeUnsupported(localeIdentifier):
            "A transcrição local não oferece suporte a \(localeIdentifier) neste Mac."
        case let .assetsNotInstalled(localeIdentifier):
            "Os ativos locais de \(localeIdentifier) não estão instalados. O OpenPEP não os baixou automaticamente."
        case let .assetInstallationFailed(localeIdentifier):
            "Não foi possível preparar os ativos Apple de \(localeIdentifier). Verifique a conexão e tente novamente."
        case .invalidAudioFile:
            "O arquivo de áudio importado não pôde ser aberto."
        case .noAudioSamples:
            "O arquivo importado não contém amostras de áudio para transcrever."
        case .alreadyTranscribing:
            "Já existe uma transcrição local em andamento."
        case .engineFailure:
            "A transcrição local falhou sem alterar o registro clínico."
        }
    }
}

protocol LocalTranscriptionEngine: Sendable {
    func availability(for locale: Locale) async -> LocalTranscriptionAvailability
    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String
    func cancel(operationID: UUID) async
}

struct LocalTranscriptionService: Sendable {
    static let portugueseBrazil = Locale(identifier: "pt_BR")

    private let engine: any LocalTranscriptionEngine

    init(engine: any LocalTranscriptionEngine = AppleLocalTranscriptionEngine()) {
        self.engine = engine
    }

    func availability(
        for locale: Locale = LocalTranscriptionService.portugueseBrazil
    ) async -> LocalTranscriptionAvailability {
        await engine.availability(for: locale)
    }

    func transcribeImportedAudio(
        at url: URL,
        locale: Locale = LocalTranscriptionService.portugueseBrazil
    ) async throws -> LocalTranscriptionDraft {
        try Task.checkCancellation()
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw LocalTranscriptionIssue.invalidAudioFile
        }

        let availability = await engine.availability(for: locale)
        try Task.checkCancellation()
        switch availability {
        case let .ready(localeIdentifier):
            return try await transcribeReadyFile(
                at: url,
                locale: Locale(identifier: localeIdentifier)
            )
        case .speechUnavailable:
            throw LocalTranscriptionIssue.speechUnavailable
        case let .localeUnsupported(localeIdentifier):
            throw LocalTranscriptionIssue.localeUnsupported(localeIdentifier)
        case let .assetsNotInstalled(localeIdentifier):
            throw LocalTranscriptionIssue.assetsNotInstalled(localeIdentifier)
        }
    }

    private func transcribeReadyFile(at url: URL, locale: Locale) async throws -> LocalTranscriptionDraft {
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let text = try await engine.transcribe(
                    audioAt: url,
                    locale: locale,
                    operationID: operationID
                )
                try Task.checkCancellation()
                return LocalTranscriptionDraft(
                    text: text,
                    localeIdentifier: locale.identifier(.bcp47)
                )
            } catch is CancellationError {
                await engine.cancel(operationID: operationID)
                throw CancellationError()
            } catch let issue as LocalTranscriptionIssue {
                throw issue
            } catch {
                throw LocalTranscriptionIssue.engineFailure
            }
        } onCancel: {
            Task { await engine.cancel(operationID: operationID) }
        }
    }
}

actor AppleLocalTranscriptionEngine: LocalTranscriptionEngine {
    private struct ActiveAnalysis {
        let operationID: UUID
        let analyzer: SpeechAnalyzer
    }

    private var activeAnalysis: ActiveAnalysis?

    func availability(for locale: Locale) async -> LocalTranscriptionAvailability {
        guard SpeechTranscriber.isAvailable else { return .speechUnavailable }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .localeUnsupported(localeIdentifier: locale.identifier(.bcp47))
        }

        let installedLocales = await SpeechTranscriber.installedLocales
        if let installedLocale = installedLocales.first(where: {
            $0.identifier(.bcp47) == supportedLocale.identifier(.bcp47)
        }) {
            return .ready(localeIdentifier: installedLocale.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            return .assetsNotInstalled(localeIdentifier: supportedLocale.identifier(.bcp47))
        }
        return .ready(localeIdentifier: supportedLocale.identifier(.bcp47))
    }

    func transcribe(audioAt url: URL, locale: Locale, operationID: UUID) async throws -> String {
        guard activeAnalysis == nil else { throw LocalTranscriptionIssue.alreadyTranscribing }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw LocalTranscriptionIssue.invalidAudioFile
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        activeAnalysis = ActiveAnalysis(operationID: operationID, analyzer: analyzer)
        defer {
            if activeAnalysis?.operationID == operationID {
                activeAnalysis = nil
            }
        }

        let resultTask = Task {
            try await transcriber.results.reduce(into: "") { transcript, result in
                transcript += String(result.text.characters)
            }
        }

        do {
            try Task.checkCancellation()
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw LocalTranscriptionIssue.noAudioSamples
            }
            try Task.checkCancellation()
            try await analyzer.finalizeAndFinish(through: lastSample)
            try Task.checkCancellation()
            return try await resultTask.value
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func cancel(operationID: UUID) async {
        guard let activeAnalysis, activeAnalysis.operationID == operationID else { return }
        await activeAnalysis.analyzer.cancelAndFinishNow()
    }
}
