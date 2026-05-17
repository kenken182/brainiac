//
//  TopicArticleView.swift
//  Mindflow — read-only renderer for a concept page in Garry's-List shape.
//  Pulls `concepts/{slug}` from gbrain, parses it via ConceptPage, and lays out:
//    - Header (title, depth chip, updated date)
//    - Article body (flowing prose; markdown links and emphasis rendered)
//    - ## Open questions
//    - ## Sources (numbered footnotes)
//    - ## Neighbors (wikilink chips)
//
//  Citation styling and footnote-scroll behavior are deferred to D4 polish.
//

import SwiftUI

struct TopicArticleView: View {
    let slug: String
    /// Called when the user clicks a wikilink/neighbor chip — parent should
    /// swap the dashboard selection to that page.
    var onOpenTopic: ((String) -> Void)? = nil
    /// Called when the user clicks a `brainiac://reference/{slug}` link — parent
    /// should swap the dashboard selection to that reference page.
    var onOpenReference: ((String) -> Void)? = nil

    @Environment(AppCore.self) private var appCore

    @State private var page: ConceptPage? = nil
    @State private var loading: Bool = true
    @State private var loadError: String? = nil

    var body: some View {
        Group {
            if loading {
                loadingState
            } else if let page = page {
                ScrollView {
                    content(page)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let err = loadError {
                ContentUnavailableView(
                    "Couldn't load topic",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else {
                ContentUnavailableView(
                    "Topic not found",
                    systemImage: "doc.questionmark",
                    description: Text("`\(slug)` isn't in your brain yet.")
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: slug) { await load() }
    }

    // MARK: - sections

    @ViewBuilder
    private func content(_ page: ConceptPage) -> some View {
        let sections = ArticleSections.parse(page.body)
        let hasFooter = !(sections.openQuestions.isEmpty && sections.sources.isEmpty && sections.neighbors.isEmpty)
        VStack(alignment: .leading, spacing: 28) {
            header(page)
            articleBody(sections.articleBody)
            if hasFooter {
                Divider().padding(.vertical, 4)
            }
            if !sections.openQuestions.isEmpty {
                openQuestionsSection(sections.openQuestions)
            }
            if !sections.sources.isEmpty {
                sourcesSection(sections.sources)
            }
            if !sections.neighbors.isEmpty {
                neighborsSection(sections.neighbors)
            }
        }
    }

    private func header(_ page: ConceptPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.titleForSlug(page.slug))
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                depthChip(page.depth)
                Text("Updated \(Self.dateFormatter.string(from: page.updated))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func depthChip(_ depth: ConceptPage.Depth) -> some View {
        let parts: [String] = {
            var p: [String] = ["\(depth.sessions) session\(depth.sessions == 1 ? "" : "s")"]
            if depth.sources > 0 { p.append("\(depth.sources) source\(depth.sources == 1 ? "" : "s")") }
            if depth.openQ > 0  { p.append("\(depth.openQ) open Q\(depth.openQ == 1 ? "" : "s")") }
            return p
        }()
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.mfAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.mfAccentBg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.mfAccentBorder, lineWidth: 0.5))
    }

    private func articleBody(_ body: String) -> some View {
        // Full block-level markdown rendering — headings (`##`), lists, code
        // blocks, paragraphs all become real SwiftUI views instead of leaking
        // raw markdown syntax. The brainiac:// URL handler stays wired up so
        // [text](brainiac://topic/foo) links navigate in-app.
        MarkdownBlocksView(
            body,
            baseSize: 16,
            color: .primary,
            spacing: 16,
            onOpenURL: { url in
                if url.scheme == "brainiac" {
                    let host = url.host ?? ""
                    let tail = url.pathComponents.dropFirst().joined(separator: "/")
                    if host == "reference", !tail.isEmpty {
                        onOpenReference?(tail)
                    } else if host == "topic", !tail.isEmpty {
                        onOpenTopic?(tail)
                    }
                    return .handled
                }
                return .systemAction
            }
        )
    }

    @ViewBuilder
    private func paragraph(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("> ") {
            // Blockquote — literal quote from the user or a source, often with a date attribution.
            let lines = trimmed.components(separatedBy: "\n").map { line -> String in
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("> ") { return String(l.dropFirst(2)) }
                if l.hasPrefix(">")  { return String(l.dropFirst()) }
                return l
            }
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.mfAccent.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        markdownText(line)
                            .italic()
                    }
                }
            }
            .padding(.vertical, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let items = trimmed
                .components(separatedBy: "\n")
                .compactMap { line -> String? in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") { return String(l.dropFirst(2)) }
                    if l.hasPrefix("* ") { return String(l.dropFirst(2)) }
                    return nil
                }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        markdownText(item)
                    }
                }
            }
        } else {
            markdownText(trimmed)
        }
    }

    @ViewBuilder
    private func markdownText(_ raw: String) -> some View {
        // SwiftUI's Text(LocalizedStringKey) parses inline markdown — bold,
        // italic, [text](url) — which is what we need for article paragraphs.
        // Block-level elements (headers, lists) we handle ourselves above.
        Text(.init(raw))
            .font(.system(size: 16))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "brainiac" {
                    let host = url.host ?? ""
                    let tail = url.pathComponents.dropFirst().joined(separator: "/")
                    if host == "reference", !tail.isEmpty {
                        onOpenReference?(tail)
                    } else if host == "topic", !tail.isEmpty {
                        onOpenTopic?(tail)
                    }
                    return .handled
                }
                return .systemAction
            })
    }

    private func openQuestionsSection(_ items: [String]) -> some View {
        sectionContainer(title: "Open questions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        markdownText(item)
                    }
                }
            }
        }
    }

    private func sourcesSection(_ items: [String]) -> some View {
        sectionContainer(title: "Sources") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    markdownText(item)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func neighborsSection(_ items: [String]) -> some View {
        sectionContainer(title: "Neighbors") {
            FlowLayout(spacing: 8) {
                ForEach(items, id: \.self) { neighbor in
                    Button {
                        onOpenTopic?(neighbor)
                    } label: {
                        Text(neighbor)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.mfAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.mfAccentBg))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.mfAccentBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionContainer<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 8)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading topic from your brain…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    private func load() async {
        loading = true
        loadError = nil
        page = nil

        let body = await appCore.gbrainClient.getPage(slug: "concepts/\(slug)")
        if let body, let parsed = ConceptPage.parse(rawMarkdown: body, slug: slug) {
            page = parsed
        } else if body != nil {
            loadError = "Topic page is missing required frontmatter."
        }
        loading = false
    }

    private static func titleForSlug(_ slug: String) -> String {
        slug
            .components(separatedBy: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func splitParagraphs(_ body: String) -> [String] {
        body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Section parser

/// Splits a concept-page body into the article (lead + prose before the first
/// `## ` heading) and the canonical footer sections. Heading order is fixed by
/// the ArticleAuthor prompt; this parser is lenient about missing sections.
struct ArticleSections {
    var articleBody: String
    var openQuestions: [String]
    var sources: [String]
    var neighbors: [String]

    static func parse(_ body: String) -> ArticleSections {
        let lines = body.components(separatedBy: "\n")
        var article: [String] = []
        var open: [String] = []
        var sources: [String] = []
        var neighbors: [String] = []
        var section: Section = .article

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                if title.hasPrefix("open question") { section = .open; continue }
                if title.hasPrefix("source")        { section = .sources; continue }
                if title.hasPrefix("neighbor")      { section = .neighbors; continue }
                // Unknown heading — keep adding to the article body so we don't lose content.
                section = .article
            }
            switch section {
            case .article:
                article.append(line)
            case .open:
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    open.append(String(trimmed.dropFirst(2)))
                }
            case .sources:
                if !trimmed.isEmpty { sources.append(trimmed) }
            case .neighbors:
                neighbors.append(contentsOf: extractWikilinks(trimmed))
            }
        }

        return ArticleSections(
            articleBody: article.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            openQuestions: open,
            sources: sources,
            neighbors: neighbors
        )
    }

    private enum Section { case article, open, sources, neighbors }

    private static func extractWikilinks(_ line: String) -> [String] {
        var results: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            guard let open = line.range(of: "[[", range: i..<line.endIndex) else { break }
            guard let close = line.range(of: "]]", range: open.upperBound..<line.endIndex) else { break }
            let slug = String(line[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !slug.isEmpty { results.append(slug) }
            i = close.upperBound
        }
        return results
    }
}

// MARK: - FlowLayout (simple wrap-to-next-line container)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

