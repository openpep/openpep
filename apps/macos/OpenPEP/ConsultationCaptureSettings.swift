// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum ConsultationCaptureSettings {
    static let sourceKey = "openpep.consultation.capture-source"
    static let transcriptionModeKey = "openpep.consultation.transcription-mode"
    static let summaryIntervalMinutesKey = "openpep.consultation.summary-interval-minutes"
    static let recordingFolderBookmarkKey = "openpep.consultation.recording-folder-bookmark"
    static let recordingFolderDisplayPathKey = "openpep.consultation.recording-folder-display-path"
    static let telecallApplicationBundleIdentifierKey = "openpep.consultation.telecall-application-bundle-id"
    static let telecallApplicationNameKey = "openpep.consultation.telecall-application-name"
    static let consentModeKey = "openpep.consultation.recording-consent-mode"

    static let defaultSource = ConsultationCaptureSourcePreference.microphone.rawValue
    static let defaultTranscriptionMode = ConsultationTranscriptionMode.appleLive.rawValue
    static let defaultSummaryIntervalMinutes = 3
    static let defaultConsentMode = ConsultationRecordingConsentMode.confirmVerbal.rawValue

    /// Resolve each capture against its own vault; never reuse another vault's bookmark.
    static func recordingFolder(in vault: URL, fileManager: FileManager = .default) throws -> URL {
        let root = vault.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("recordings", isDirectory: true)
        if let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ConsultationCaptureSettingsIssue.recordingFolderUnavailable
        }
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              folder.resolvingSymlinksInPath() == folder, fileManager.isWritableFile(atPath: folder.path) else {
            throw ConsultationCaptureSettingsIssue.recordingFolderUnavailable
        }
        return folder
    }

    static func recordingFolder() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: recordingFolderBookmarkKey) else {
            return nil
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            try saveRecordingFolder(url)
        }
        return url
    }

    static func saveRecordingFolder(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: recordingFolderBookmarkKey)
        defaults.set(url.path, forKey: recordingFolderDisplayPathKey)
    }

    static func clearRecordingFolder() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: recordingFolderBookmarkKey)
        defaults.removeObject(forKey: recordingFolderDisplayPathKey)
    }

    static func newRecordingURL(in folder: URL, usesWAV: Bool, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let ext = usesWAV ? "wav" : "m4a"
        return folder.appendingPathComponent("consulta-\(formatter.string(from: date))-\(suffix).\(ext)")
    }
}

enum ConsultationCaptureSourcePreference: String, CaseIterable, Identifiable {
    case microphone
    case telecall

    var id: String { rawValue }
    var label: String {
        switch self {
        case .microphone: "Microfone deste Mac"
        case .telecall: "Microfone e telechamada"
        }
    }
}

enum ConsultationRecordingConsentMode: String, CaseIterable, Identifiable {
    case confirmVerbal
    case requireRecordedTerm

    var id: String { rawValue }
    var label: String {
        switch self {
        case .confirmVerbal: "Consentimento verbal, sem termo"
        case .requireRecordedTerm: "Termo obtido previamente"
        }
    }

    var guidance: String {
        switch self {
        case .confirmVerbal:
            "Obtenha o consentimento verbal dos participantes antes de clicar no microfone."
        case .requireRecordedTerm:
            "Obtenha e guarde o termo aplicável antes de clicar no microfone."
        }
    }

}

enum ConsultationCaptureSettingsIssue: LocalizedError {
    case recordingFolderMissing
    case recordingFolderUnavailable
    case telecallApplicationMissing
    case telecallApplicationUnavailable

    var errorDescription: String? {
        switch self {
        case .recordingFolderMissing:
            "Abra ou crie um prontuário para guardar os áudios dentro dele."
        case .recordingFolderUnavailable:
            "Não foi possível acessar a pasta recordings do prontuário. Confira a permissão de escrita e se ela é uma pasta local, sem atalho simbólico."
        case .telecallApplicationMissing:
            "Escolha em Configurações o aplicativo usado nas telechamadas."
        case .telecallApplicationUnavailable:
            "O aplicativo configurado para a telechamada não está aberto. Abra-o e tente novamente."
        }
    }
}
