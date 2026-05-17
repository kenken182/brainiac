//
//  MarkdownBlocks.swift
//  Mindflow — shared block-level markdown renderer for chat bubbles, memory
//  transcripts, gbrain page bodies, and reference views.
//
//  Splits a markdown string into paragraph / heading / list / fenced-code
//  blocks, then renders each as a distinct SwiftUI view with appropriate
//  styling. Inline markdown (**bold**, *italic*, `code`, [links](url)) is
//  still parsed within each block via AttributedString.
//
//  Why not just AttributedString(markdown:)? Apple's inline-only mode collapses
//  blank lines to a single line-break, and the block-aware `.full` mode renders
//  poorly inside SwiftUI Text (no real paragraph spacing, no list indentation).
//  This view gives us proper visual separation between paragraphs + native
//  bullet / heading / code-block styling, which is what users expect.
//

import SwiftUI

enum MarkdownBlock: Hashable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case bulletList([AttributedString])
    case numberedList([AttributedString])
    case codeBlock(String)
}

extension MarkdownBlock {
    /// Inline-markdown parser for the body of one block. Preserves whitespace
    /// (single `\n` inside a paragraph) and renders **bold**, *italic*,
    /// `code`, [links](url). Falls back to plain text on parse failure.
    static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Split a full markdown string into typed blocks. Splits on blank lines
    /// (`\n\n`) for paragraph boundaries, then sniffs each chunk for heading
    /// (`# `, `## `, `### `), list (`- `, `* `, `1. `), and fenced code
    /// (```` ``` ````) patterns.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let chunks = text.components(separatedBy: "\n\n")
        for raw in chunks {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }

            if chunk.hasPrefix("```") && chunk.hasSuffix("```") && chunk.count > 6 {
                var inner = String(chunk.dropFirst(3).dropLast(3))
                if let nl = inner.firstIndex(of: "\n") {
                    inner = String(inner[inner.index(after: nl)...])
                }
                blocks.append(.codeBlock(inner.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            if chunk.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: parseInline(String(chunk.dropFirst(4)))))
                continue
            }
            if chunk.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: parseInline(String(chunk.dropFirst(3)))))
                continue
            }
            if chunk.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: parseInline(String(chunk.dropFirst(2)))))
                continue
            }

            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let nonEmpty = lines.filter { !$0.isEmpty }

            if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
                blocks.append(.bulletList(nonEmpty.map { parseInline(String($0.dropFirst(2))) }))
                continue
            }

            if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }) {
                let items = nonEmpty.map { line -> AttributedString in
                    let stripped = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    return parseInline(stripped)
                }
                blocks.append(.numberedList(items))
                continue
            }

            blocks.append(.paragraph(parseInline(chunk)))
        }
        return blocks
    }
}

/// Renders a markdown string as block-level SwiftUI views. Heading sizes scale
/// up from `baseSize`; list markers and code blocks inherit `color`. An
/// optional `onOpenURL` handler is attached to the SwiftUI environment so
/// caller-defined schemes (e.g. `brainiac://`) can route through to in-app
/// navigation instead of opening in the browser.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let baseSize: CGFloat
    let color: Color
    let spacing: CGFloat
    let onOpenURL: ((URL) -> OpenURLAction.Result)?

    init(
        _ text: String,
        baseSize: CGFloat = 14,
        color: Color = .primary,
        spacing: CGFloat = 10,
        onOpenURL: ((URL) -> OpenURLAction.Result)? = nil
    ) {
        self.blocks = MarkdownBlock.parse(text)
        self.baseSize = baseSize
        self.color = color
        self.spacing = spacing
        self.onOpenURL = onOpenURL
    }

    init(
        blocks: [MarkdownBlock],
        baseSize: CGFloat = 14,
        color: Color = .primary,
        spacing: CGFloat = 10,
        onOpenURL: ((URL) -> OpenURLAction.Result)? = nil
    ) {
        self.blocks = blocks
        self.baseSize = baseSize
        self.color = color
        self.spacing = spacing
        self.onOpenURL = onOpenURL
    }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        if let onOpenURL {
            stack.environment(\.openURL, OpenURLAction(handler: onOpenURL))
        } else {
            stack
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.system(size: baseSize))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 4 : 2)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(color.opacity(0.55))
                        Text(item)
                            .foregroundStyle(color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: baseSize))
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(color.opacity(0.55))
                            .monospacedDigit()
                        Text(item)
                            .foregroundStyle(color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: baseSize))
                }
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(size: max(baseSize - 1, 10), design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.05))
                )
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 5
        case 2: return baseSize + 3
        default: return baseSize + 1
        }
    }
}
