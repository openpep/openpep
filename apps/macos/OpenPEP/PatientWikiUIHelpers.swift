// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI

/// A presentation-only section parsed from the persisted wiki Markdown.
/// The stored page remains the source of truth; this type only controls its
/// compact, topic-by-topic reading layout.
struct PatientWikiDisplaySection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let text: String
    let sourceLabels: [String]
    let isOverview: Bool
}

enum PatientWikiMarkdownPresentation {
    static func sections(summary: PatientWikiSummary) -> [PatientWikiDisplaySection] {
        let parsed = parse(summary.markdown)
        guard let overviewIndex = parsed.firstIndex(where: { $0.isOverview }) else {
            let base = summary.overview ?? summary.markdown
            let text = withSourceLabels(base, labels: sourceLabels(in: summary.markdown))
            return text.isEmpty ? [] : [PatientWikiDisplaySection(id: "overview", title: "Resumo breve",
                text: text, sourceLabels: sourceLabels(in: text), isOverview: true)]
        }

        var result = parsed
        let parsedOverview = parsed[overviewIndex]
        let overviewText = withSourceLabels(summary.overview ?? parsedOverview.text,
            labels: parsedOverview.sourceLabels)
        result[overviewIndex] = PatientWikiDisplaySection(
            id: parsedOverview.id,
            title: parsedOverview.title,
            text: overviewText,
            sourceLabels: unique(parsedOverview.sourceLabels + sourceLabels(in: overviewText)),
            isOverview: true
        )
        return result.filter { !$0.text.isEmpty || $0.isOverview }
    }

    /// Parses the small Markdown subset produced by PatientWikiGeneration and
    /// remains readable for legacy summaries without a heading.
    static func parse(_ markdown: String) -> [PatientWikiDisplaySection] {
        var title = "Resumo breve"
        var isOverview = true
        var lines: [String] = []
        var sections: [PatientWikiDisplaySection] = []
        var usedIDs = Set<String>()

        func appendSection() {
            let text = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                lines.removeAll(keepingCapacity: true)
                return
            }
            let id: String
            if isOverview {
                id = "overview"
            } else {
                let base = "topic-" + slug(title)
                var candidate = base
                var suffix = 2
                while usedIDs.contains(candidate) {
                    candidate = "\(base)-\(suffix)"
                    suffix += 1
                }
                id = candidate
            }
            usedIDs.insert(id)
            sections.append(PatientWikiDisplaySection(id: id, title: title,
                text: text, sourceLabels: sourceLabels(in: text), isOverview: isOverview))
            lines.removeAll(keepingCapacity: true)
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("# ") {
                appendSection()
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                isOverview = title.caseInsensitiveCompare("Resumo breve") == .orderedSame
            } else if line.hasPrefix("## ") {
                appendSection()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                isOverview = false
            } else {
                lines.append(line)
            }
        }
        appendSection()

        // A legacy page can start with a level-two heading. Treat the first
        // such item as the compact overview only when no explicit overview
        // heading exists, preserving all other topics.
        if !sections.contains(where: { $0.isOverview }), let first = sections.first {
            sections[0] = PatientWikiDisplaySection(id: "overview", title: "Resumo breve",
                text: first.text, sourceLabels: first.sourceLabels, isOverview: true)
        }
        return sections
    }

    private static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        let value = folded.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "secao" : value
    }

    static func sourceLabels(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\[F([0-9]+)\]"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return unique(expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).dropFirst().dropLast()
        }.map(String.init))
    }

    static func cleanSourceLabels(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[F[0-9]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withSourceLabels(_ text: String, labels: [String]) -> String {
        let existing = Set(sourceLabels(in: text))
        let missing = labels.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
            + missing.map { "[\($0)]" }.joined(separator: " ")
    }

    private static func unique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }
}

/// Renders wiki prose with small, keyboard-accessible inline source links.
/// The custom URL scheme never leaves the process: PatientWikiInlineText
/// intercepts it and presents the verified local source in the parent view.
struct PatientWikiInlineText: View {
    let text: String
    let sourceEntries: [String: PatientHistoryEntry]
    let onOpenSource: (PatientHistoryEntry) -> Void
    var body: some View {
        PatientWikiSourceText(attributedText: Self.attributed(text: text, activeLabels: Set(sourceEntries.keys))) { url in
            guard url.scheme == Self.urlScheme, let host = url.host,
                  let entry = sourceEntries[host.uppercased()] else { return }
            onOpenSource(entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint("As referências sublinhadas abrem o trecho correspondente.")
    }

    private static let urlScheme = "openpep-source"

    static func attributed(text: String, activeLabels: Set<String>) -> AttributedString {
        guard let expression = try? NSRegularExpression(pattern: #"\[F([0-9]+)\]"#) else {
            return parsed(text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return parsed(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let labelRange = Range(match.range(at: 1), in: text) else { continue }
            if cursor < matchRange.lowerBound { result += parsed(String(text[cursor..<matchRange.lowerBound])) }
            let label = "F" + text[labelRange]
            var marker = AttributedString("[\(label)]")
            marker.font = .caption.weight(.semibold)
            if activeLabels.contains(label) {
                marker.foregroundColor = .accentColor
                marker.underlineStyle = .single
                marker.link = URL(string: "\(urlScheme)://\(label)")
            } else {
                marker.foregroundColor = .secondary
            }
            result += marker
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex { result += parsed(String(text[cursor...])) }
        return result
    }

    private static func parsed(_ text: String) -> AttributedString {
        let sanitized = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        return (try? AttributedString(markdown: sanitized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// AppKit supplies precise link hit testing, selection and keyboard navigation.
/// Cursor rectangles cover only links, rather than the surrounding prose.
struct PatientWikiSourceText: NSViewRepresentable {
    let attributedText: AttributedString
    let onOpen: (URL) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> SourceTextView {
        let view = SourceTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: SourceTextView, context: Context) {
        context.coordinator.onOpen = onOpen
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let text = NSMutableAttributedString(string: "")
        for run in attributedText.runs {
            let value = String(attributedText[run.range].characters)
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            let italic = run.inlinePresentationIntent?.contains(.emphasized) == true
            var font = run.link != nil ? NSFont.preferredFont(forTextStyle: .caption1) : NSFont.preferredFont(forTextStyle: .body)
            if strong { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link = run.link { attributes[.link] = link }
            text.append(NSAttributedString(string: value, attributes: attributes))
        }
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
        view.window?.invalidateCursorRects(for: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SourceTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = view.textContainer,
              let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void
        init(onOpen: @escaping (URL) -> Void) { self.onOpen = onOpen }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { onOpen(url) }
            return true // Never allow external navigation from source text.
        }
    }

    final class SourceTextView: NSTextView {
        override func resetCursorRects() {
            super.resetCursorRects()
            guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
            layout.ensureLayout(for: container)
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { link, range, _ in
                guard link != nil else { return }
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    var rect = rect
                    rect.origin.x += self.textContainerOrigin.x
                    rect.origin.y += self.textContainerOrigin.y
                    self.addCursorRect(rect, cursor: .pointingHand)
                }
            }
        }
    }
}

struct PatientWikiCorrectionConfirmationView: View {
    let markdown: String
    let onCancel: () -> Void
    let onConfirm: (Set<Int>) -> Void
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conferir correções incorporadas").font(.headline)
            Text("Confira o resumo atualizado e marque somente as linhas que ele incorporou. As demais continuam orientando as próximas atualizações.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            Toggle(line, isOn: Binding(get: { selected.contains(index) }, set: { checked in
                                if checked { selected.insert(index) } else { selected.remove(index) }
                            })).toggleStyle(.checkbox)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirmar incorporação e remover selecionadas") { onConfirm(selected) }
                    .disabled(selected.isEmpty)
            }
        }.padding(24).frame(minWidth: 520, minHeight: 320)
    }
}

struct PatientWikiSummaryView: View {
    let summary: PatientWikiSummary
    let sourceEntries: [String: PatientHistoryEntry]
    let onOpenSource: (PatientHistoryEntry) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedIDs: Set<String>

    init(summary: PatientWikiSummary, sourceEntries: [String: PatientHistoryEntry],
         onOpenSource: @escaping (PatientHistoryEntry) -> Void) {
        self.summary = summary
        self.sourceEntries = sourceEntries
        self.onOpenSource = onOpenSource
        let sections = PatientWikiMarkdownPresentation.sections(summary: summary)
        _expandedIDs = State(initialValue: Set(sections.filter(\.isOverview).map(\.id)))
    }

    private var sections: [PatientWikiDisplaySection] {
        PatientWikiMarkdownPresentation.sections(summary: summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sections) { section in
                let expanded = expandedIDs.contains(section.id)
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        toggle(section)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .frame(width: 18, height: 24)
                            Text(section.title)
                                .font(section.isOverview ? .headline.weight(.semibold) : .body.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(expanded ? "Expandido" : "Recolhido")
                    .accessibilityHint("Clique para mostrar ou ocultar o conteúdo.")
                    if expanded {
                        PatientWikiInlineText(text: section.text, sourceEntries: sourceEntries,
                            onOpenSource: onOpenSource)
                            .padding(.top, 3)
                            .padding(.bottom, 8)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toggle(_ section: PatientWikiDisplaySection) {
        let update = {
            if expandedIDs.contains(section.id) { expandedIDs.remove(section.id) }
            else { expandedIDs.insert(section.id) }
        }
        if reduceMotion { update() }
        else { withAnimation(.easeInOut(duration: 0.2), update) }
    }
}

enum PatientWikiProfessionalIdentity {
    /// The profile configured for the Solo session is the only identity used
    /// for a wiki review/export. There is intentionally no free-form field.
    static var displayName: String {
        let profile = DoctorProfileStore.load()
        let name = profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        let registration = profile.registration.trimmingCharacters(in: .whitespacesAndNewlines)
        return [name, registration].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static var isConfigured: Bool { !displayName.isEmpty }
}
