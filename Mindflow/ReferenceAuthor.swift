//
//  ReferenceAuthor.swift
//  Mindflow — Sonnet 4.6 prompt that builds the body of a reference page.
//
//  A reference is the per-article record: a summary of the article with the
//  user's questions, answers, observations, and reactions woven into the
//  relevant parts. It anchors the conversation to the source. Concept pages
//  later synthesize learnings across multiple references.
//
//  Inputs: article text (from WebImageExtractor.fetch), conversation
//  transcript, source URL/title. Output: markdown body only (no frontmatter,
//  no leading H1).
//

import Foundation

enum ReferenceAuthorError: Error {
    case empty
    case llmFailed(String)
}

struct ReferenceAuthorInput {
    let sessionDate: Date
    /// Cleaned article text from the source URL. May be empty when the source
    /// is a native app, paywalled SPA, or otherwise unfetchable.
    let articleText: String
    /// Full conversation markdown (user dialogue + Brainiac replies + voice
    /// notes). Same string ChatAgent.buildSessionMarkdown produces.
    let conversation: String
    let sourceURL: String?
    let sourceTitle: String?
    /// Used in the prompt for context only — the title rendering is owned by
    /// the renderer (TopicArticleView / ReferenceDetailView).
    let primaryTopicSlug: String
}

@MainActor
final class ReferenceAuthor {
    private let chatClient: ClaudeChatClient

    init(apiKey: String) {
        self.chatClient = ClaudeChatClient(apiKey: apiKey, model: "claude-sonnet-4-6")
    }

    /// Produce the reference body. Returns trimmed markdown (no frontmatter,
    /// no leading H1). Throws if the LLM returns empty text.
    func write(_ input: ReferenceAuthorInput) async throws -> String {
        let system = Self.systemPrompt
        let user = Self.userPrompt(input: input)

        let response = try await chatClient.send(
            messages: [["role": "user", "content": [["type": "text", "text": user]]]],
            tools: [],
            systemPrompt: system,
            maxTokens: 4096
        )

        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ReferenceAuthorError.empty }
        return Self.stripCodeFences(body)
    }

    // MARK: - Prompts

    private static let systemPrompt: String = """
    You are writing a "reference page" for the user's personal Garry's-List-style library. A reference is anchored to ONE article the user just read and discussed with you. Your job: produce a record that captures the SUBSTANCE of the article AND weaves the user's questions, observations, and reactions into the relevant parts of that article.

    # Frame

    The reader is the user looking back at this session in 6 months. They want to remember (1) what the article actually said, and (2) what they were thinking about while reading it. The reference is the record both of those things, fused.

    # Voice

    Plain language. The article's claims are stated as the article states them ("Databricks routes each rate-limit check to…", "the doc recommends…"), with section citations where useful. The user's interjections are written in first person, distinguishable from the article's voice ("I keep coming back to…", "my read is…", "I asked: …").

    Don't bullet-point everything. The default shape is flowing paragraphs that follow the article's structure, with conversational asides integrated where they're load-bearing.

    # Structure

    Output: markdown body only. No frontmatter (the pipeline adds it). No leading H1 (the renderer derives the title from the source).

    - **Lead paragraph** — summary of what the article is about and what the user was trying to figure out from it.
    - **Walk through the article's structure**, one section/argument per paragraph or short paragraph cluster. Use `## Subheadings` where the article has clear sections. Quote the article when distinctive ("the doc puts it: '…'"). Cite section numbers / headings when possible.
    - **Weave conversation inline**: when the user asked a question that's relevant to a section, drop it in as part of that section's prose — "I asked whether X; the answer is Y because [article §3.2]". When the user made an observation or claim, integrate it the same way — "I noted that this matches our gateway setup; per the article that's exactly the pattern in §4."
    - **Validate user claims against the article inline**:
      - **Supported by article** → state the user's claim, anchor it to the article section.
      - **Contradicted** → surface it explicitly: "I said X, but the article actually says the opposite in §4.1: '…'."
      - **Not in article** → mark it as user-attributed: "*my own framing — not from the article*."
    - **Don't include a separate "Conversation" or "Q&A" section**. The conversation IS woven in. Don't lose any load-bearing question/answer pair.

    # What to minimize

    - Generic background the article already assumes you know
    - Conversation fluff (filler words, "um", "right", reformulations) — capture the SUBSTANCE of what was said, not the verbatim phrasing
    - The article's setup/intro material if it's standard

    # What's load-bearing

    - The article's actual decisions, examples, claims, recommendations
    - The user's questions and the answers they got
    - The user's reactions / opinions / "I keep coming back to this" moments — those are valuable for the cross-article concept pages later
    - Contradictions between the article and the user's prior beliefs (if surfaced)
    """

    private static func userPrompt(input: ReferenceAuthorInput) -> String {
        let dateStr = String(ISO8601DateFormatter().string(from: input.sessionDate).prefix(10))

        var s = "## Context\n\n"
        s += "- Session date: \(dateStr)\n"
        s += "- Primary topic slug: `\(input.primaryTopicSlug)`\n"
        if let url = input.sourceURL, !url.isEmpty {
            s += "- Source URL: \(url)\n"
        } else {
            s += "- Source URL: (none — anchored on a native app or PDF, no article text available)\n"
        }
        if let title = input.sourceTitle, !title.isEmpty {
            s += "- Source title: \(title)\n"
        }

        s += "\n## Article text\n\n"
        if input.articleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "_(The article text wasn't available — write the reference from the conversation alone. Note in the lead that the source content wasn't captured.)_\n"
        } else {
            // Trim very long articles so we don't blow out the prompt. Keep
            // the first ~10k chars — plenty for a typical blog post / docs page.
            let truncated = input.articleText.prefix(10_000)
            s += "```\n\(truncated)\n```\n"
            if input.articleText.count > 10_000 {
                s += "\n_(article truncated to first 10,000 chars)_\n"
            }
        }

        s += "\n## Conversation\n\n"
        s += "```\n\(input.conversation)\n```\n"

        s += "\nProduce the reference body now. Markdown only. Start with the lead paragraph."
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
