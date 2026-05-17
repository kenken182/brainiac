//
//  ArticleAuthor.swift
//  Mindflow — Sonnet 4.6 prompt that writes / re-rolls the editorial body of a
//  concept page in Garry's-List voice. Called by EnrichmentPipeline once per
//  topic touched in a session.
//
//  The output is the markdown body only (article + ## Open questions / ## Sources
//  / ## Neighbors footer). The pipeline wraps it with frontmatter when calling
//  ConceptPage.toMarkdown().
//

import Foundation

enum ArticleAuthorError: Error {
    case empty
    case llmFailed(String)
}

/// Input to the article author. Re-roll inputs are explicit; first-write
/// callers pass `existingBody = nil`.
struct ArticleAuthorInput {
    let topicSlug: String
    let sessionDate: Date
    /// LLM-authored reference body for THIS session (article digest + woven
    /// conversation). The article author distills the topic-specific learnings
    /// from this and integrates them with the existing concept body.
    let referenceBody: String
    /// Source URL the user was reading this session. Optional — `nil` when the
    /// session anchored on a native app or PDF.
    let sourceURL: String?
    /// Title of the source page if known. Falls back to URL hostname.
    let sourceTitle: String?
    /// Existing article body (full markdown — article + footer). `nil` for a
    /// brand-new topic page.
    let existingBody: String?
    /// Reference slug for THIS session (e.g. "2026-05-16-stripe-rate-limits").
    /// The author may weave inline links of the form
    /// `[your earlier session](brainiac://reference/{slug})` for distinctive
    /// user statements from this session.
    let referenceSlug: String
    /// Candidate images extracted from the source article. The author may
    /// include them inline as `![caption](url)` when they clarify a point.
    /// Empty array when there's nothing useful (or the extractor failed).
    let availableImages: [ExtractedImage]
}

@MainActor
final class ArticleAuthor {
    private let chatClient: ClaudeChatClient

    init(apiKey: String) {
        self.chatClient = ClaudeChatClient(apiKey: apiKey, model: "claude-sonnet-4-6")
    }

    /// Generate or re-roll the article body for a concept page. The result is
    /// just the markdown body — no frontmatter, no leading H1 (the renderer
    /// derives the title from the slug). Throws if the LLM returns empty text.
    func write(_ input: ArticleAuthorInput) async throws -> String {
        let system = Self.systemPrompt
        let user = Self.userPrompt(input: input)

        let response = try await chatClient.send(
            messages: [["role": "user", "content": [["type": "text", "text": user]]]],
            tools: [],
            systemPrompt: system,
            maxTokens: 4096
        )

        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ArticleAuthorError.empty }
        return Self.stripCodeFences(body)
    }

    // MARK: - Prompts

    private static let systemPrompt: String = """
    You are writing an entry for the user's personal Garry's-List — a permanent, all-in-one bookmark of their technical learnings. Each entry is ONE TOPIC (e.g. "rate limiting", "batch reporting") and accumulates across multiple sessions on multiple source articles.

    Your input each session is a REFERENCE BODY — a digest of an article the user just read, with their questions, observations, and reactions already woven in. Your job is to distill what's load-bearing for THIS TOPIC out of that reference, and integrate it with whatever the user has accumulated on this topic from prior sessions.

    # Voice

    Garry's-List voice. Plain language, opinion-led, conversational but substantive. First-person when natural ("I keep coming back to…", "the part I missed first time…"). Preserve literal phrases the user used when distinctive — those quotes are what anchor the page to *them*, not a generic synthesis.

    Write in the user's voice, not a third-person summary. The page should read as if the user wrote it themselves.

    # Structure

    The OUTPUT is markdown body only — no frontmatter (the pipeline adds it), no leading H1 (the renderer adds it from the slug).

    - **First paragraph is lead + TL;DR.** No "## TL;DR" heading. Just open with the punchline — what the user has come to believe about this topic.
    - **Article body** — flowing prose. Inline `[N]` numbered citations for sourced claims. Short bullet blocks where they help (patterns, pitfalls, discriminating examples) — but only when they read naturally, not as section headers.
    - **Footer sections** in this exact order, only included when they have content:
      ```
      ## Open questions
      - Bulleted, dated. Carry forward unresolved questions from prior sessions; add new ones from this session; drop questions resolved this session.

      ## Sources
      [1] [Title](URL) — session YYYY-MM-DD
      [2] ...

      ## Neighbors
      [[adjacent-topic-slug]] · [[another-topic]]
      ```

    # Citation rules

    - Use `[N]` superscript-style numeric citations for claims grounded in source articles. Anchor them in the `## Sources` footer.
    - For distinctive things the USER said this session — opinions, framings, decisions — you may weave in an inline markdown link of the form `[your earlier session](brainiac://reference/<reference-slug>)` so they can verify provenance. Use this sparingly (max 1–2 per re-roll) and only for genuinely distinctive lines worth surfacing.
    - User-attributed thoughts that aren't sourced should be marked inline (e.g. *"my own framing — …"*) so they're distinguishable from source-validated claims.

    # Diagrams

    When the user prompt provides "Available images" from the source article, you MAY embed them inline as `![caption](url)` where they clarify a structural point. Don't force them in — skip if none feel right. Pair each embedded image with a `[N]` citation pointing back to the source article in the `## Sources` footer.

    # What belongs

    Hard-to-Google material:
    - The user's decisions and preferences
    - Pitfalls they (or sources they trust) discovered
    - Discriminating examples
    - Open questions they're working on
    - Connections to related topics in the library

    # What's minimized

    Easy-to-Google material:
    - Generic definitions (don't recap Wikipedia)
    - Comprehensive reference material the source article already covers
    - Background any LLM already knows

    Filter: *"could this be Googled?"* If yes, cite the source and move on. The page is the user's editorial commentary, NOT a recap of the source.

    # Re-roll behavior

    When an existing body is provided, you are RE-ROLLING — incorporating this session's new material while preserving the user's accumulated thinking. Don't discard prior takes. Don't append blindly either; integrate. New material may:
    - Add a new opinion or example
    - Refine a previously-stated take
    - Resolve a previously-open question (move it from `## Open questions` into the body inline)
    - Introduce a new open question
    - Add a new source to `## Sources` (renumber if needed)

    Output the FULL re-rolled body. Don't output diffs or just-the-changes.

    # Filtering the reference

    The reference body covers the ENTIRE article — multiple topics may show up in one session. Your output should be specific to THIS topic (`topicSlug` in context). Skip parts of the reference that don't touch this topic. If a section of the reference mentions the topic in passing, pull just the relevant claim; don't drag along the broader context.
    """

    private static func userPrompt(input: ArticleAuthorInput) -> String {
        let dateStr = ISO8601DateFormatter().string(from: input.sessionDate).prefix(10)
        var s = "## Context\n\n"
        s += "- Topic slug: `\(input.topicSlug)`\n"
        s += "- Session date: \(dateStr)\n"
        s += "- Reference slug for this session: `\(input.referenceSlug)`\n"
        if let url = input.sourceURL, !url.isEmpty {
            s += "- Source URL this session: \(url)\n"
        } else {
            s += "- Source URL this session: (none — anchored on a native app or PDF)\n"
        }
        if let title = input.sourceTitle, !title.isEmpty {
            s += "- Source title: \(title)\n"
        }

        s += "\n## Existing article body\n\n"
        if let existing = input.existingBody, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "```markdown\n\(existing)\n```\n"
        } else {
            s += "_(This is a brand-new topic page — write the first version from this session alone.)_\n"
        }

        if !input.availableImages.isEmpty {
            s += "\n## Available images from the source article\n\n"
            for (idx, img) in input.availableImages.enumerated() {
                let caption = img.caption.isEmpty ? "(no caption)" : img.caption
                s += "\(idx + 1). `![\(caption)](\(img.url))`\n"
            }
            s += "\nEmbed any that clarify a structural point. Skip the rest. Each embed should be paired with a `[N]` source citation in the footer.\n"
        }

        s += "\n## This session's reference (article digest with conversation woven in)\n\n"
        s += "```markdown\n\(input.referenceBody)\n```\n"

        s += "\nProduce the re-rolled article body now — focused on the `\(input.topicSlug)` topic. Markdown only. Start with the lead paragraph."
        return s
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("```markdown") {
            s = String(s.dropFirst("```markdown".count))
        } else if s.hasPrefix("```md") {
            s = String(s.dropFirst("```md".count))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
