// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct ConsultationCaptureSettingsTests {
    @Test func recordingNameIsUniqueAndUsesRequestedContainer() {
        let folder = URL(fileURLWithPath: "/tmp/audio-sintetico", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = ConsultationCaptureSettings.newRecordingURL(in: folder, usesWAV: true, date: date)
        let second = ConsultationCaptureSettings.newRecordingURL(in: folder, usesWAV: true, date: date)

        #expect(first.deletingLastPathComponent() == folder)
        #expect(first.pathExtension == "wav")
        #expect(first.lastPathComponent.hasPrefix("consulta-2023-11-14-"))
        #expect(first != second)
    }

    @Test func recordingFoldersStayInsideTheirVaultAndRejectLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for vault in [first, second] { try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false) }
        let one = try ConsultationCaptureSettings.recordingFolder(in: first)
        let two = try ConsultationCaptureSettings.recordingFolder(in: second)
        #expect(one != two)
        #expect(one.deletingLastPathComponent() == first.resolvingSymlinksInPath())
        let audio = one.appendingPathComponent("kept.wav")
        try Data("synthetic audio".utf8).write(to: audio)
        #expect(try ConsultationCaptureSettings.recordingFolder(in: first) == one)
        #expect(try Data(contentsOf: audio) == Data("synthetic audio".utf8))
        try FileManager.default.removeItem(at: two)
        try FileManager.default.createSymbolicLink(at: two, withDestinationURL: one)
        #expect(throws: (any Error).self) { try ConsultationCaptureSettings.recordingFolder(in: second) }
    }

    @Test func sideMouseButtonsFollowBrowserHistoryConvention() {
        #expect(MouseHistoryDirection(buttonNumber: 3) == .back)
        #expect(MouseHistoryDirection(buttonNumber: 4) == .forward)
        #expect(MouseHistoryDirection(buttonNumber: 2) == nil)
        #expect(MouseHistoryDirection(buttonNumber: 5) == nil)
    }
}
