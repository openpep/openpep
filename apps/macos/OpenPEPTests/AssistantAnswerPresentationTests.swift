// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import OpenPEP

struct AssistantAnswerPresentationTests {
    @Test func preservesClinicalValuesAndReferencesWhileRemovingMarkdown() {
        let input = "## Resultado\n**Creatinina:** 1,0 mg/dL em 01/09/2026 [F1].\n- *Ureia:* 35 mg/dL [F2].\n> Sem data em outra fonte.\n```text\nNão calcular TFG.\n```"
        let text = AssistantAnswerPresentation.plainText(input)
        #expect(AssistantAnswerPresentation.plainText("- 1,0 mmol/L [F1]") == "- 1,0 mmol/L [F1]")
        #expect(text == "Resultado\nCreatinina: 1,0 mg/dL em 01/09/2026 [F1].\n• Ureia: 35 mg/dL [F2].\nSem data em outra fonte.\nNão calcular TFG.")
    }
    @Test func onlyExistingCitationsAreSelectedWithoutRenumbering() {
        let original = syntheticAssistantAnswer()
        let answer = PatientAIAnswer(result: .init(text: "Valor [F2], repetido [F2]; inválido [F99].", model: "synthetic", responseID: "synthetic"),
            generationID: original.generationID, promptVersion: original.promptVersion, sourceText: original.sourceText,
            sourceFingerprint: original.sourceFingerprint, entries: [original.entries[0], original.entries[0]], corrections: "")
        #expect(answer.citedSourceNumbers == [2])
    }
}
