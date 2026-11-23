// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Formatting only; values and source numbers are never shortened or rewritten.
enum AssistantAnswerPresentation {
    static func plainText(_ text: String) -> String {
        let blocks = ClinicalTextPresentation.clean(text).components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }.map {
            $0.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
        guard let parsed = try? AttributedString(markdown: blocks,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return blocks }
        return String(parsed.characters).components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"^\s*[-*+]\s+(?=[A-Za-zÀ-ÿ])"#, with: "• ", options: .regularExpression)
        }.joined(separator: "\n")
    }
}
