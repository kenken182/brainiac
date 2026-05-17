//
//  WebImageExtractor.swift
//  Mindflow — fetches an article's HTML and pulls out candidate diagram/image
//  URLs that the ArticleAuthor prompt can reference inline. Heuristics filter
//  out icons, tracking pixels, and nav imagery so the article doesn't render
//  noise.
//
//  This is the MVP version: image references stay as remote URLs pointing at
//  the source site. A future revision will download binaries and upload them
//  to gbrain via `gbrain files upload --page <slug>` so the article survives
//  if the source goes offline.
//

import Foundation

struct ExtractedImage: Equatable {
    /// Caption from the image's `alt` attribute. Empty if none.
    var caption: String
    /// Fully-qualified URL of the image. Relative `src` values are resolved
    /// against the document URL.
    var url: String
}

enum WebImageExtractorError: Error {
    case invalidURL
    case fetchFailed(Int)
    case decodeFailed
}

@MainActor
final class WebImageExtractor {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// Fetched page bundle: clean text body + candidate images. Failures (any
    /// network error, non-2xx, undecodable bytes) collapse to an empty bundle
    /// — image extraction and article fetching are both best-effort and should
    /// never block the pipeline.
    struct FetchedArticle {
        var text: String
        var images: [ExtractedImage]
        var pageTitle: String?
    }

    /// Single fetch that returns BOTH cleaned text and candidate images. Used
    /// by EnrichmentPipeline so we don't double-fetch the source.
    func fetch(_ url: String, imageLimit: Int = 6) async -> FetchedArticle {
        guard let base = URL(string: url) else { return FetchedArticle(text: "", images: [], pageTitle: nil) }
        do {
            var req = URLRequest(url: base)
            req.setValue("Mozilla/5.0 (Macintosh) Brainiac/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return FetchedArticle(text: "", images: [], pageTitle: nil)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return FetchedArticle(text: "", images: [], pageTitle: nil)
            }
            let raw = Self.parseImageTags(html, base: base)
            let images = Self.filterCandidates(raw, limit: imageLimit)
            let text = Self.extractText(html)
            let title = Self.extractTitle(html)
            return FetchedArticle(text: text, images: images, pageTitle: title)
        } catch {
            print("[WebImageExtractor] fetch failed for \(url): \(error)")
            return FetchedArticle(text: "", images: [], pageTitle: nil)
        }
    }

    /// Convenience for callers that only need images (legacy callsite).
    func extract(from url: String, limit: Int = 6) async -> [ExtractedImage] {
        await fetch(url, imageLimit: limit).images
    }

    // MARK: - Text extraction

    /// Strip HTML to readable plain text. Removes `<script>`, `<style>`, and
    /// `<nav>`/`<header>`/`<footer>` chrome; collapses whitespace; decodes
    /// common HTML entities. Won't beat readability.js but good enough for
    /// blog posts and docs pages.
    static func extractText(_ html: String) -> String {
        var s = html
        // Drop big non-content blocks wholesale.
        let dropPatterns = [
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<style\b[^>]*>[\s\S]*?</style>"#,
            #"<noscript\b[^>]*>[\s\S]*?</noscript>"#,
            #"<nav\b[^>]*>[\s\S]*?</nav>"#,
            #"<header\b[^>]*>[\s\S]*?</header>"#,
            #"<footer\b[^>]*>[\s\S]*?</footer>"#,
            #"<aside\b[^>]*>[\s\S]*?</aside>"#,
            #"<form\b[^>]*>[\s\S]*?</form>"#,
            #"<svg\b[^>]*>[\s\S]*?</svg>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        for p in dropPatterns {
            if let r = try? NSRegularExpression(pattern: p, options: .caseInsensitive) {
                s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            }
        }
        // Replace block-level closing tags with double newlines so paragraphs separate.
        let blockTags = ["p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote", "pre"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: "</\(tag)>", with: "\n\n", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "<\(tag)>", with: "\n\n", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "<\(tag) ", with: "\n\n<\(tag) ", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)

        // Strip everything else that looks like a tag.
        if let r = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }

        // Decode the most common entities; ignore the rest (most readers
        // tolerate raw `&` etc. in our digest input).
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&ldquo;", "\""), ("&rdquo;", "\""),
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }

        // Collapse runs of whitespace.
        if let r = try? NSRegularExpression(pattern: #"[ \t]+"#) {
            s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        if let r = try? NSRegularExpression(pattern: #"\n[ \t]+"#) {
            s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\n")
        }
        if let r = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            s = r.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull `<title>...</title>` content (or `<meta property="og:title">`).
    static func extractTitle(_ html: String) -> String? {
        if let r = try? NSRegularExpression(pattern: #"<title\b[^>]*>([\s\S]*?)</title>"#, options: .caseInsensitive),
           let m = r.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
           m.numberOfRanges > 1 {
            let raw = (html as NSString).substring(with: m.range(at: 1))
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Parsing

    /// Parse `<img>` tags out of HTML. Tolerant — accepts single- or double-quoted
    /// attribute values and missing attribute order. Resolves relative src against
    /// `base`.
    static func parseImageTags(_ html: String, base: URL) -> [ExtractedImage] {
        var results: [ExtractedImage] = []
        let pattern = #"<img\b[^>]*?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let nsHtml = html as NSString
        let range = NSRange(location: 0, length: nsHtml.length)
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            let tag = nsHtml.substring(with: m.range)
            let src = Self.attr("src", in: tag) ?? Self.attr("data-src", in: tag)
            let alt = Self.attr("alt", in: tag) ?? ""
            guard let src else { return }
            // data: URIs and javascript: → skip
            if src.hasPrefix("data:") || src.hasPrefix("javascript:") { return }
            // Resolve relative URL against base
            let absURL: String
            if let resolved = URL(string: src, relativeTo: base)?.absoluteString {
                absURL = resolved
            } else {
                absURL = src
            }
            results.append(ExtractedImage(caption: alt.trimmingCharacters(in: .whitespacesAndNewlines), url: absURL))
        }
        return results
    }

    /// Extract a quoted attribute value from a tag string. Returns nil if not present.
    static func attr(_ name: String, in tag: String) -> String? {
        // Match: name="value", name='value', or name=bareword (best-effort)
        let patterns = [
            #"\#(name)\s*=\s*"([^"]*)""#,
            #"\#(name)\s*=\s*'([^']*)'"#,
            #"\#(name)\s*=\s*([^\s>]+)"#,
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            let ns = tag as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: tag, options: [], range: range), match.numberOfRanges > 1 {
                let valueRange = match.range(at: 1)
                if valueRange.location != NSNotFound {
                    return ns.substring(with: valueRange)
                }
            }
        }
        return nil
    }

    // MARK: - Filtering

    /// Score and prune images. Drops obvious junk (tracking pixels, icons,
    /// avatars in nav bars) and prefers images that look like content
    /// (have alt text, content/figure-y filenames).
    static func filterCandidates(_ raw: [ExtractedImage], limit: Int) -> [ExtractedImage] {
        // Score: higher = more likely a real diagram.
        func score(_ img: ExtractedImage) -> Int {
            var s = 0
            // Has alt text → +3
            if !img.caption.isEmpty { s += 3 }
            // Filename suggests diagram/figure → +3
            let lowerURL = img.url.lowercased()
            if lowerURL.contains("/figure") || lowerURL.contains("/diagram") ||
               lowerURL.contains("figure-") || lowerURL.contains("diagram-") {
                s += 3
            }
            // Hints we're in main content
            if lowerURL.contains("/content/") || lowerURL.contains("/article/") || lowerURL.contains("/post/") {
                s += 1
            }
            // Penalize obvious junk
            if lowerURL.contains("logo") || lowerURL.contains("favicon") ||
               lowerURL.contains("avatar") || lowerURL.contains("badge") ||
               lowerURL.contains("/icons/") || lowerURL.contains("sprite") ||
               lowerURL.contains("tracking") || lowerURL.contains("pixel") {
                s -= 5
            }
            // Very small file-format hints (1px transparent gifs)
            if lowerURL.hasSuffix(".gif") && img.caption.isEmpty { s -= 2 }
            return s
        }

        // Deduplicate by URL.
        var seen: Set<String> = []
        let unique = raw.filter { seen.insert($0.url).inserted }

        let scored = unique
            .map { (img: $0, score: score($0)) }
            .filter { $0.score > -3 }
            .sorted { $0.score > $1.score }

        return scored.prefix(limit).map { $0.img }
    }
}
