//
//  LearningPages.swift
//  Mindflow — schemas for the two markdown-page types the learning function writes
//  to gbrain: ConceptPage (the editorial topic page that gets re-rolled per session)
//  and ReferencePage (the immutable per-session record).
//
//  Both round-trip through gbrain via `gbrain put <path>` (write) and `gbrain get <slug>`
//  (read). Frontmatter is YAML; body is markdown. See learning-spec.md for the data
//  model contract.
//

import Foundation

/// Concept page lives at `concepts/{slug}` in gbrain. Re-rolled per session by the
/// EnrichmentPipeline. The body is the flowing editorial article + footer (Open
/// questions / Sources / Neighbors) that the ArticleAuthor prompt produces.
struct ConceptPage {
    var slug: String
    var depth: Depth
    var neighbors: [String]
    var created: Date
    var updated: Date
    /// Full markdown body including the article and the `## Open questions`,
    /// `## Sources`, `## Neighbors` footer sections. Stored verbatim — the
    /// ArticleAuthor prompt owns the internal structure.
    var body: String

    struct Depth: Equatable {
        var sessions: Int
        var sources: Int
        var openQ: Int
    }

    var path: String { "concepts/\(slug)" }

    /// Compose the full gbrain page (frontmatter + body) as a single string.
    func toMarkdown() -> String {
        let neighborList = neighbors.isEmpty
            ? "[]"
            : "[" + neighbors.joined(separator: ", ") + "]"
        let createdStr = Self.dateFormatter.string(from: created)
        let updatedStr = Self.dateFormatter.string(from: updated)

        return """
        ---
        type: concept
        slug: \(slug)
        depth:
          sessions: \(depth.sessions)
          sources: \(depth.sources)
          open_q: \(depth.openQ)
        neighbors: \(neighborList)
        created: \(createdStr)
        updated: \(updatedStr)
        ---
        \(body)
        """
    }

    /// Parse a previously-written concept page back. Tolerant: any frontmatter
    /// field that fails to parse falls back to a default rather than throwing.
    /// `slug` is required as an argument because gbrain doesn't preserve our
    /// custom `slug:` field when storing — it normalizes frontmatter to its own
    /// schema (adds `title:`, ISO-quotes the dates, reorders depth subfields).
    /// The caller already knows the slug from the page path it requested.
    static func parse(rawMarkdown: String, slug: String) -> ConceptPage? {
        guard let (frontmatter, body) = splitFrontmatter(rawMarkdown) else { return nil }

        var sessions = 1
        var sources = 0
        var openQ = 0
        var neighbors: [String] = []
        var created = Date()
        var updated = Date()

        var inDepth = false
        for rawLine in frontmatter.components(separatedBy: "\n") {
            let line = rawLine
            if line.hasPrefix("  ") && inDepth {
                let kv = line.trimmingCharacters(in: .whitespaces)
                if let (k, v) = splitKeyValue(kv) {
                    switch k {
                    case "sessions": sessions = Int(v) ?? sessions
                    case "sources":  sources  = Int(v) ?? sources
                    case "open_q":   openQ    = Int(v) ?? openQ
                    default: break
                    }
                }
                continue
            } else {
                inDepth = false
            }
            guard let (k, v) = splitKeyValue(line) else { continue }
            switch k {
            case "depth": inDepth = true
            case "neighbors": neighbors = parseInlineList(v)
            case "created": if let d = parseFlexibleDate(v) { created = d }
            case "updated": if let d = parseFlexibleDate(v) { updated = d }
            default: break
            }
        }

        return ConceptPage(
            slug: slug,
            depth: Depth(sessions: sessions, sources: sources, openQ: openQ),
            neighbors: neighbors,
            created: created,
            updated: updated,
            body: body
        )
    }

    /// Accepts `yyyy-MM-dd`, ISO 8601, or either form wrapped in single/double
    /// quotes — gbrain emits dates as `'2026-05-17T00:00:00.000Z'` even when we
    /// wrote them as plain `2026-05-17`.
    private static func parseFlexibleDate(_ raw: String) -> Date? {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")) {
            v = String(v.dropFirst().dropLast())
        }
        if let d = dateFormatter.date(from: v) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: v) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: v) { return d }
        return nil
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

/// Reference page lives at `media/{date}-{slug}` in gbrain. Anchored to ONE
/// article. The body is an LLM-authored digest: summary of the article with
/// the user's questions, observations, and reactions woven into the relevant
/// parts. Concept pages later synthesize learnings across multiple references.
///
/// References are targets of `brainiac://reference/{slug}` deep-links and the
/// citation footnotes on concept pages.
struct ReferencePage {
    var slug: String
    var sourceURL: String?
    var anchor: AnchorKind
    var date: Date
    var sessionID: UUID
    var topics: [String]
    var learner: String
    /// LLM-authored markdown body — article digest with conversation woven in.
    /// Stored verbatim; ReferenceAuthor owns the internal structure.
    var body: String
    var anchorMetadata: AnchorMetadata

    enum AnchorKind: String {
        case webPage = "web_page"
        case person
        case email
        case document
        case other
    }

    struct AnchorMetadata {
        var screenshotPath: String?
        var pageTitle: String?
    }

    var path: String { "media/\(slug)" }

    func toMarkdown() -> String {
        let isoDate = Self.dateFormatter.string(from: date)
        let topicList = topics.isEmpty ? "[]" : "[" + topics.joined(separator: ", ") + "]"
        var s = "---\n"
        s += "type: reference\n"
        if let url = sourceURL, !url.isEmpty {
            s += "source_url: \(url)\n"
        }
        s += "anchor: \(anchor.rawValue)\n"
        s += "date: \(isoDate)\n"
        s += "session_id: \(sessionID.uuidString)\n"
        s += "topics: \(topicList)\n"
        s += "learner: \(learner)\n"
        if let title = anchorMetadata.pageTitle, !title.isEmpty {
            s += "page_title: \(title)\n"
        }
        s += "---\n\n"
        s += body.isEmpty ? "_(empty)_\n" : body
        return s
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Compose the reference slug as `{yyyy-MM-dd}-{topic-slug}` per spec.
    static func slug(date: Date, topicSlug: String) -> String {
        "\(dateFormatter.string(from: date))-\(topicSlug)"
    }
}

// MARK: - Frontmatter helpers (shared, file-private)

private func splitFrontmatter(_ raw: String) -> (frontmatter: String, body: String)? {
    let trimmed = raw.hasPrefix("\n") ? String(raw.dropFirst()) : raw
    guard trimmed.hasPrefix("---") else { return nil }
    let afterOpening = String(trimmed.dropFirst(3))
    // Strip the optional newline right after the opening `---`.
    let body0 = afterOpening.hasPrefix("\n") ? String(afterOpening.dropFirst()) : afterOpening
    guard let closingRange = body0.range(of: "\n---") else { return nil }
    let frontmatter = String(body0[..<closingRange.lowerBound])
    var body = String(body0[closingRange.upperBound...])
    if body.hasPrefix("\n") { body.removeFirst() }
    return (frontmatter, body)
}

private func splitKeyValue(_ line: String) -> (String, String)? {
    guard let colonIdx = line.firstIndex(of: ":") else { return nil }
    let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
    let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
    return key.isEmpty ? nil : (key, value)
}

private func parseInlineList(_ raw: String) -> [String] {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("[") { s.removeFirst() }
    if s.hasSuffix("]") { s.removeLast() }
    if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
    return s
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
