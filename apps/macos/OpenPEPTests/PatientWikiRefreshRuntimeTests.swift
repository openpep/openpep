// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import OpenPEP

struct PatientWikiRefreshRuntimeTests {
    @Test("source or prompt changes require one fresh wiki generation")
    func detectsSourceAndPromptChanges() {
        #expect(!PatientWikiView.needsGeneration(
            summarySourceFingerprint: nil, summaryPromptVersion: nil,
            sourceFingerprint: nil, currentPromptVersion: "synthetic-prompt"))
        #expect(PatientWikiView.needsGeneration(
            summarySourceFingerprint: nil, summaryPromptVersion: nil,
            sourceFingerprint: "source-1", currentPromptVersion: "synthetic-prompt"))
        #expect(PatientWikiView.needsGeneration(
            summarySourceFingerprint: "source-1", summaryPromptVersion: nil,
            sourceFingerprint: "source-1", currentPromptVersion: "synthetic-prompt"))
        #expect(PatientWikiView.needsGeneration(
            summarySourceFingerprint: "source-1", summaryPromptVersion: "synthetic-prompt",
            sourceFingerprint: "source-2", currentPromptVersion: "synthetic-prompt"))
        #expect(!PatientWikiView.needsGeneration(
            summarySourceFingerprint: "source-1", summaryPromptVersion: "synthetic-prompt",
            sourceFingerprint: "source-1", currentPromptVersion: "synthetic-prompt"))
    }
}
