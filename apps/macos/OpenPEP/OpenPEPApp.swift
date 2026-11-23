// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

private struct OpenPEPSettingsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var openPEPSettings: (() -> Void)? {
        get { self[OpenPEPSettingsActionKey.self] }
        set { self[OpenPEPSettingsActionKey.self] = newValue }
    }
}

@main
struct OpenPEPApp: App {
    @FocusedValue(\.openPEPAssistant) private var openAssistant
    @FocusedValue(\.openPEPSettings) private var openSettings

    var body: some Scene {
        WindowGroup {
            // Unit tests construct their own views and inject synthetic services.
            // Avoid restoring a personal vault or reading Keychain while the test host starts.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                EmptyView()
            } else {
                ContentView()
            }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Assistente…") { openAssistant?() }
                    .keyboardShortcut("j", modifiers: .command)
                    .disabled(openAssistant == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Configurações…") {
                    openSettings?()
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(openSettings == nil)
            }
        }
    }
}
