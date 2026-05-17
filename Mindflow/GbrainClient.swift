//
//  GbrainClient.swift
//  Mindflow — shells out to `gbrain` for read-side queries. Used by:
//    1. MindflowSaver — checks pre-save existence of anchor + concept pages
//       so MemoryRecord can flag what was new at capture time.
//    2. MemoryDetail — fetches current backlink counts + anchor markdown.
//  The write side lives in GbrainSaver.swift.
//

import Foundation

struct GbrainPageStatus {
    let slug: String
    let exists: Bool
    let backlinks: [GbrainBacklink]  // empty if none or the query failed
    let backlinksOK: Bool            // false if the backlinks query itself errored
    let body: String?                // nil if missing or query failed

    var backlinkCount: Int { backlinks.count }
}

/// One inbound link to a page, as returned by `gbrain backlinks <slug>`.
/// gbrain extracts these from `[[wikilinks]]` in page markdown into a relational
/// links table; this struct is one row of that table viewed from the "to" side.
struct GbrainBacklink: Codable, Hashable, Sendable, Identifiable {
    let fromSlug: String
    let toSlug: String
    let linkType: String
    let context: String

    var id: String { "\(fromSlug)->\(toSlug)#\(linkType)" }
}

/// One row of `gbrain list` output. Tab-separated columns: slug, type, date, title.
struct GbrainListEntry: Identifiable, Hashable, Sendable {
    let slug: String
    let type: String
    let updated: String  // raw date string as returned by `gbrain list` (e.g. "Sat May 16")
    let title: String

    var id: String { slug }

    /// Slug "directory" — e.g. `concepts/rate-limiting` → `concepts`.
    var directory: String? {
        guard let i = slug.firstIndex(of: "/") else { return nil }
        return String(slug[..<i])
    }

    /// Slug leaf — e.g. `concepts/rate-limiting` → `rate-limiting`.
    var leaf: String {
        guard let i = slug.lastIndex(of: "/") else { return slug }
        return String(slug[slug.index(after: i)...])
    }
}

struct GbrainSearchResult: Identifiable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let score: Double
    let preview: String

    /// The "directory" portion of a slug — e.g. `media/foo-bar` → `media`.
    /// Used as a group header in the dashboard sidebar so the user can see
    /// at a glance which area of their brain a result lives in.
    var directory: String? {
        guard let slashIdx = slug.firstIndex(of: "/") else { return nil }
        return String(slug[..<slashIdx])
    }

    /// The leaf portion of the slug, with the directory stripped.
    var leaf: String {
        guard let slashIdx = slug.lastIndex(of: "/") else { return slug }
        return String(slug[slug.index(after: slashIdx)...])
    }
}

final class GbrainClient: @unchecked Sendable {
    private let gbrainPath: String

    init(gbrainPath: String = "/Users/keefeho/.bun/bin/gbrain") {
        self.gbrainPath = gbrainPath
    }

    /// Read a page's markdown body. Returns nil if it doesn't exist or the call failed.
    func getPage(slug: String) async -> String? {
        let result = await run(args: ["get", slug])
        guard result.exitCode == 0 else { return nil }
        return result.stdout
    }

    /// Write/update a page. The body should be full markdown including the YAML
    /// frontmatter (matching what `getPage` returns). Returns (success, stderr).
    func putPage(slug: String, body: String) async -> (success: Bool, stderr: String) {
        let result = await run(args: ["put", slug, "--content", body])
        return (result.exitCode == 0, result.stderr)
    }

    /// Delete a page. Returns (success, stderr).
    func deletePage(slug: String) async -> (success: Bool, stderr: String) {
        let result = await run(args: ["delete", slug])
        return (result.exitCode == 0, result.stderr)
    }

    /// Count incoming backlinks for a page. Returns -1 if the query failed.
    /// Convenience wrapper around `backlinks(forSlug:)`.
    func backlinkCount(slug: String) async -> Int {
        let result = await backlinks(forSlug: slug)
        return result.ok ? result.links.count : -1
    }

    /// Fetch the full list of inbound links to a page. `gbrain backlinks` returns
    /// a JSON array; we decode it with snake_case mapping.
    func backlinks(forSlug slug: String) async -> (links: [GbrainBacklink], ok: Bool) {
        let result = await run(args: ["backlinks", slug])
        guard result.exitCode == 0 else { return ([], false) }
        guard let data = result.stdout.data(using: .utf8) else { return ([], false) }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let parsed = try decoder.decode([GbrainBacklink].self, from: data)
            return (parsed, true)
        } catch {
            // Treat a parse failure (unexpected output) as "no data" but still OK
            // so we don't keep showing an error indicator for a benign quirk.
            return ([], true)
        }
    }

    /// Full-text search across the brain. Returns ranked results with a short
    /// preview snippet. `gbrain search` output format is:
    ///   [score] slug -- preview text...
    /// Previews may span multiple lines until the next `[score] slug --` header.
    func search(query: String, limit: Int = 20) async -> [GbrainSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let result = await run(args: ["search", trimmed, "--limit", "\(limit)"])
        guard result.exitCode == 0 else { return [] }
        return Self.parseSearchOutput(result.stdout)
    }

    static func parseSearchOutput(_ output: String) -> [GbrainSearchResult] {
        // Header regex: `[<score>] <slug> -- <rest>`
        // Slug may contain `/`, `-`, alphanumerics; we stop at whitespace.
        let headerRe = #/^\[(\d+(?:\.\d+)?)\]\s+(\S+)\s+--\s?(.*)$/#
        var results: [GbrainSearchResult] = []
        var pending: (score: Double, slug: String, previewLines: [String])?

        func flush() {
            guard let p = pending else { return }
            let preview = p.previewLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(GbrainSearchResult(slug: p.slug, score: p.score, preview: preview))
            pending = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let match = try? headerRe.firstMatch(in: line) {
                flush()
                let score = Double(match.1) ?? 0
                pending = (score: score, slug: String(match.2), previewLines: [String(match.3)])
            } else if pending != nil {
                pending?.previewLines.append(line)
            }
        }
        flush()
        return results
    }

    /// List pages, optionally filtered by directory prefix (e.g. `concepts/`).
    /// `gbrain list` output is tab-separated; the prefix filter is applied
    /// client-side because the CLI doesn't accept a slug-prefix flag.
    func listPages(prefix: String? = nil, limit: Int = 200) async -> [GbrainListEntry] {
        let result = await run(args: ["list", "--limit", "\(limit)"])
        guard result.exitCode == 0 else { return [] }
        var entries: [GbrainListEntry] = []
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 4 else { continue }
            let slug = cols[0].trimmingCharacters(in: .whitespaces)
            let type = cols[1].trimmingCharacters(in: .whitespaces)
            let updated = cols[2].trimmingCharacters(in: .whitespaces)
            let title = cols[3].trimmingCharacters(in: .whitespaces)
            if let prefix, !slug.hasPrefix(prefix) { continue }
            entries.append(GbrainListEntry(slug: slug, type: type, updated: updated, title: title))
        }
        return entries
    }

    /// Combined fetch: body + full backlinks list in one go, ran in parallel.
    func status(forSlug slug: String) async -> GbrainPageStatus {
        async let bodyTask = getPage(slug: slug)
        async let backlinksTask = backlinks(forSlug: slug)
        let body = await bodyTask
        let bl = await backlinksTask
        return GbrainPageStatus(
            slug: slug,
            exists: body != nil,
            backlinks: bl.links,
            backlinksOK: bl.ok,
            body: body
        )
    }

    private struct ShellResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(args: [String]) async -> ShellResult {
        let path = gbrainPath
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            let extraPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "\(NSHomeDirectory())/.bun/bin",
            ]
            let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(extraPaths.joined(separator: ":")):\(existingPath)"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return ShellResult(exitCode: -1, stdout: "", stderr: "\(error)")
            }
            process.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
