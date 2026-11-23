// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct PatientAIAnswer {
    let result: OpenAITextResult
    let generationID: String
    let promptVersion: String
    let sourceText: String
    let sourceFingerprint: String
    let entries: [PatientHistoryEntry]
    let corrections: String
    var wikiReadingSnapshot: PatientWikiReadingSnapshot? = nil

    var citedSourceNumbers: Set<Int> {
        guard let expression = try? NSRegularExpression(pattern: #"\[F(\d+)\]"#) else { return [] }
        let text = result.text as NSString
        return Set(expression.matches(in: result.text, range: NSRange(location: 0, length: text.length)).compactMap {
            guard let number = Int(text.substring(with: $0.range(at: 1))), entries.indices.contains(number - 1) else { return nil }
            return number
        })
    }
}
