// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import OpenPEP

@Suite("DESIGN-SETTINGS-001 local settings search")
struct SettingsIndexViewTests {
    @Test("empty search shows every topic")
    func emptySearch() {
        #expect(SettingsTopic.allCases.filter { $0.matches("") }.count == SettingsTopic.allCases.count)
        #expect(SettingsTopic.allCases.filter { $0.matches("   ") }.count == SettingsTopic.allCases.count)
    }

    @Test("search ignores case and diacritics")
    func normalization() {
        #expect(SettingsTopic.appearance.matches("AUTOMATICA"))
        #expect(SettingsTopic.transcription.matches("transcricao"))
        #expect(SettingsTopic.recordings.matches("MICROFONE"))
        #expect(SettingsTopic.quickSetup.matches("configuracao rapida"))
        #expect(SettingsTopic.quickSetup.matches("primeiro uso"))
    }

    @Test("search includes setting names without leaking into unrelated topics")
    func settingNames() {
        #expect(SettingsTopic.documents.matches("CRM"))
        #expect(SettingsTopic.documents.matches("médico"))
        #expect(SettingsTopic.agenda.matches("duração padrão"))
        #expect(SettingsTopic.backup.matches("restaurar"))
        #expect(SettingsTopic.storage.matches("somente leitura"))
        #expect(!SettingsTopic.appearance.matches("restaurar"))
    }
}
