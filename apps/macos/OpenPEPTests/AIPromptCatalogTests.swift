// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import OpenPEP

@Suite("AI-PROMPTS-001 built-in prompt catalog")
struct AIPromptCatalogTests {
    @Test("catalog identities and ordered layers are explicit")
    func catalogStructure() {
        let prompts = AIPromptCatalog.all
        #expect(prompts.count == 7)
        #expect(Set(prompts.map(\.id)).count == prompts.count)
        #expect(prompts.allSatisfy { !$0.id.isEmpty && !$0.layers.isEmpty })
        #expect(prompts.allSatisfy { prompt in
            prompt.layers.contains { $0.kind == .task }
                && prompt.layers.contains { $0.kind == .contract }
                && prompt.instructions == prompt.layers.map(\.text).joined(separator: "\n")
        })
        for prompt in prompts {
            #expect(AIPromptCatalog.definition(id: prompt.id) == prompt)
        }
        #expect(AIPromptCatalog.definition(id: "openpep/unknown@1") == nil)
        #expect(AIPromptCatalog.definition(id: "openpep/patient-history-question-openai-pt-BR@2") != nil)
        #expect(AIPromptCatalog.patientWiki.id == "openpep/patient-wiki-pt-BR@4")
        #expect(AIPromptCatalog.patientWiki.instructions.contains("20 palavras"))
        #expect(AIPromptCatalog.patientWiki.instructions.contains("socialHistory"))
        #expect(AIPromptCatalog.definition(id: "openpep/patient-wiki-pt-BR@2").map { digest($0.instructions) }
            == "01f7069243bdfdec52edfa6ee5880478da19205f18f4ac29168449b0d4323c89")
        #expect(AIPromptCatalog.definition(id: "openpep/patient-wiki-pt-BR@1")?.purpose == .patientWiki)
        #expect(AIPromptCatalog.definition(id: "openpep/patient-wiki-pt-BR@1")?.instructions.contains("duas frases") == true)
        #expect(AIPromptCatalog.definition(id: "openpep/patient-wiki-pt-BR@1").map { digest($0.instructions) }
            == "8b99ed4de148678fee6fa346acbc1ee5baf1346b4a7a07ae4efdb1ac8f7e9138")
        #expect(AIPromptCatalog.definition(id: "openpep/patient-wiki-pt-BR@3").map { digest($0.instructions) }
            == "c1e8660eaeec7d8192d346a91fe44e88b104590f6c25c34161b70c54dba1b0db")
        #expect(AIPromptCatalog.patientHistoryOpenAI.instructions.contains("120 palavras"))
        #expect(AIPromptCatalog.patientHistoryOpenAI.instructions.contains("sem Markdown"))
        #expect(AIPromptCatalog.patientHistoryOpenAI.id == "openpep/patient-history-question-openai-pt-BR@4")
        #expect(AIPromptCatalog.patientHistoryOpenAI.instructions.contains("Se fornecidos"))
        #expect(AIPromptCatalog.patientHistoryOpenAI.instructions.contains("fonte soberana"))
        #expect(AIPromptCatalog.definition(id: "openpep/patient-history-question-openai-pt-BR@3").map { digest($0.instructions) }
            == "f504901dee2fc1919e93d52c50fa4a05df46ca6e18bb81bf7c8d353cb5cc8de9")
        #expect(AIPromptCatalog.definition(id: "openpep/patient-history-question-openai-pt-BR@1").map { digest($0.instructions) }
            == "210b574a8b2fb00c029f7da23305fbf53b806bf10db44daaf5c06f4feaca1ae2")
    }

    @Test("versioned instruction bytes remain explicit")
    func defaultInstructionDigests() {
        let expected = [
            "openpep/consultation-summary-pt-BR@1": "b420c2a690f4dbf47a50cc50cf0f89507323af346452b072762625b0d40078df",
            "openpep/progressive-consultation-summary-pt-BR@5": "d82c6a4f2aa06a1155d4bef36b9d11c87227a7f51a08ab0d327442884f0903a5",
            "openpep/final-consultation-summary-apple-pt-BR@1": "7b6ccd2d67a72244845d56dd0cc7e0dd1ff4af4732dd7d160f8ad2629910678e",
            "openpep/patient-history-question-apple-pt-BR@1": "38e7ac42701ebeb7dae2492315f386453f427b5b9014dc60256a870ba34a7f55",
            "openpep/patient-history-question-openai-pt-BR@4": "539f7081042deb6fb151fef5e9c07cb8288f2d1b3b3429ba41221ac51244dcad",
            "openpep/patient-wiki-pt-BR@4": "6dc83ea11d70b18fbc5777572eabea49a03dfc22799ea5618417476c84a353cd",
        ]
        #expect(Dictionary(uniqueKeysWithValues: AIPromptCatalog.all.filter { $0.purpose != .assistantIntent }.map {
            ($0.id, digest($0.instructions))
        }) == expected)
    }

    @Test("effective snapshot is recoverable without credentials")
    func snapshot() {
        let prompt = AIPromptCatalog.patientHistoryOpenAI
        let snapshot = prompt.snapshot(
            engine: "openai/responses",
            model: "synthetic-model",
            parameters: ["response_format": "text"]
        )
        #expect(snapshot.promptID == prompt.id)
        #expect(snapshot.purpose == .patientHistoryQuestion)
        #expect(snapshot.profileRevision == AIPromptCatalog.builtinProfileRevision)
        #expect(snapshot.instructions == prompt.instructions)
        #expect(snapshot.engine == "openai/responses")
        #expect(snapshot.model == "synthetic-model")
        #expect(snapshot.parameters == ["response_format": "text"])
        #expect(!snapshot.instructions.localizedCaseInsensitiveContains("api key"))
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
