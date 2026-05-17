//
//  ReferenceDetailView.swift
//  Mindflow — read-only view for an immutable session reference page (media/{slug}).
//
//  References are the per-session record — the immutable "what was actually
//  said" trail that topic pages cite. Visually distinct from topic pages (which
//  are re-rolled, editorial syntheses): no neighbor chips, no Open questions,
//  no inline citations to chase. The view lays out:
//    - Header: session date, anchor (URL), topics
//    - Conversation transcript
//    - Voice-noted asides (if any)
//    - Anchor metadata (screenshot, page title, session id)
//

import SwiftUI

struct ReferenceDetailView: View {
    /// Just the leaf slug, e.g. "2026-05-16-stripe-rate-limits". The view
    /// prepends the `media/` directory when fetching from gbrain.
    let slug: String

    @Environment(AppCore.self) private var appCore

    @State private var loading: Bool = true
    @State private var rawMarkdown: String? = nil
    @State private var parsed: ParsedReference? = nil

    var body: some View {
        Group {
            if loading {
                loadingState
            } else if let parsed {
                ScrollView {
                    content(parsed)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ContentUnavailableView(
                    "Reference not found",
                    systemImage: "doc.questionmark",
                    description: Text("`media/\(normalizedSlug)` couldn't be loaded.")
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: slug) { await load() }
    }

    @ViewBuilder
    private func content(_ ref: ParsedReference) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(ref)
            // Reference body is the article digest with conversation woven in.
            // Render as flowing prose — paragraphs and ## subheadings.
            digestBody(ref.body)
        }
    }

    @ViewBuilder
    private func digestBody(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(splitParagraphs(body).enumerated()), id: \.offset) { _, para in
                paragraph(para)
            }
        }
    }

    @ViewBuilder
    private func paragraph(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("## ") {
            Text(String(trimmed.dropFirst(3)))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("### ") {
            Text(String(trimmed.dropFirst(4)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.mfAccent.opacity(0.4))
                    .frame(width: 3)
                Text(.init(String(trimmed.dropFirst(2))))
                    .italic()
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let items = trimmed.components(separatedBy: "\n").compactMap { line -> String? in
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("- ") { return String(l.dropFirst(2)) }
                if l.hasPrefix("* ") { return String(l.dropFirst(2)) }
                return nil
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(.init(item))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text(.init(trimmed))
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func header(_ ref: ParsedReference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.below.ecg")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Session record")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
                Spacer()
            }
            Text(ref.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                if !ref.dateString.isEmpty {
                    Text(ref.dateString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let url = ref.sourceURL, !url.isEmpty {
                    Link(destination: URL(string: url) ?? URL(string: "about:blank")!) {
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.mfAccent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !ref.topics.isEmpty {
                HStack(spacing: 6) {
                    ForEach(ref.topics, id: \.self) { topic in
                        Text(topic)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.mfAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.mfAccentBg))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.mfAccentBorder, lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading session record from your brain…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Strip a leading `media/` if the caller (e.g. a `brainiac://reference/...`
    /// link from a topic article) passed the full slug instead of just the leaf.
    /// Without this we'd build `media/media/...` and fail every lookup.
    private var normalizedSlug: String {
        slug.hasPrefix("media/") ? String(slug.dropFirst("media/".count)) : slug
    }

    private func load() async {
        loading = true
        parsed = nil
        rawMarkdown = nil
        let body = await appCore.gbrainClient.getPage(slug: "media/\(normalizedSlug)")
        if let body {
            rawMarkdown = body
            parsed = Self.parse(body, slug: normalizedSlug)
        }
        loading = false
    }

    private func splitParagraphs(_ body: String) -> [String] {
        body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Parser

    struct ParsedReference {
        var title: String
        var dateString: String
        var sourceURL: String?
        var topics: [String]
        /// The full LLM-authored digest body (article + woven conversation).
        var body: String
    }

    static func parse(_ raw: String, slug: String) -> ParsedReference? {
        var title = slug
        var dateString = ""
        var sourceURL: String?
        var topics: [String] = []

        var body = raw
        if raw.hasPrefix("---") {
            let afterOpen = String(raw.dropFirst(3))
            let body0 = afterOpen.hasPrefix("\n") ? String(afterOpen.dropFirst()) : afterOpen
            if let close = body0.range(of: "\n---") {
                let frontmatter = String(body0[..<close.lowerBound])
                var rest = String(body0[close.upperBound...])
                if rest.hasPrefix("\n") { rest.removeFirst() }
                body = rest
                for line in frontmatter.components(separatedBy: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if (value.hasPrefix("'") && value.hasSuffix("'")) ||
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    switch key {
                    case "date":       dateString = String(value.prefix(10))
                    case "source_url": sourceURL = value
                    case "topics":     topics = Self.parseInlineList(value)
                    case "page_title": title = value
                    default: break
                    }
                }
            }
        }

        return ParsedReference(
            title: title,
            dateString: dateString,
            sourceURL: sourceURL,
            topics: topics,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseInlineList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return s.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
