//
//  EnrichmentPipeline.swift
//  Mindflow — post-session enrichment. Triggered by ChatAgent.endCurrentSession.
//
//  Steps:
//    1. Extract topic slugs from the transcript (Sonnet 4.6 JSON call).
//    2. Write the immutable reference page in media/{date}-{topic-slug}.
//    3. For each topic touched:
//       a. Load existing concept page (if any).
//       b. Re-roll the article body via ArticleAuthor.
//       c. Write the concept page in concepts/{topic-slug}, bumping depth.
//    4. Fire a "topic updated" notification.
//
//  Runs in a detached Task so popup dismissal isn't blocked.
//

import Foundation

enum EnrichmentError: Error {
    case noConcepts
    case llmFailed(String)
}

@MainActor
final class EnrichmentPipeline {
    private let chatClient: ClaudeChatClient
    private let gbrainSaver: GbrainSaver
    private let articleAuthor: ArticleAuthor
    private let referenceAuthor: ReferenceAuthor
    private let imageExtractor: WebImageExtractor
    private let notifier: Notifier

    init(apiKey: String, gbrainSaver: GbrainSaver, notifier: Notifier) {
        self.chatClient = ClaudeChatClient(apiKey: apiKey, model: "claude-sonnet-4-6")
        self.gbrainSaver = gbrainSaver
        self.articleAuthor = ArticleAuthor(apiKey: apiKey)
        self.referenceAuthor = ReferenceAuthor(apiKey: apiKey)
        self.imageExtractor = WebImageExtractor()
        self.notifier = notifier
    }

    /// Input bundle for one session's worth of enrichment.
    struct Input {
        let sessionID: UUID
        let sessionStartedAt: Date
        let sourceAppName: String?
        let sourceURL: String?
        let screenshotPath: String
        let initialTranscript: String
        /// The full conversation as markdown — same shape ChatAgent writes to
        /// voice-notes/. Passed in already-built so we don't duplicate the
        /// composition logic.
        let conversationMarkdown: String
        let learner: String
    }

    /// Run the full enrichment pipeline for a session. Errors are logged and
    /// surfaced via notifier rather than thrown — popup-dismissal callers fire
    /// this as fire-and-forget, so the error path needs to be self-contained.
    ///
    /// Order:
    ///   1. Extract topic slugs from the transcript
    ///   2. Fetch the source article (text + images) once
    ///   3. Generate the reference body (article digest + woven conversation)
    ///   4. Write the reference page
    ///   5. For each topic touched, re-roll the concept page using the
    ///      reference body as its input material
    ///   6. Fire completion notification
    func enrich(_ input: Input) async {
        do {
            print("[Enrich] starting for session \(input.sessionID)")

            // 1. Extract topics
            let topics = try await extractTopics(transcript: input.conversationMarkdown)
            guard !topics.isEmpty else {
                print("[Enrich] no topics extracted — skipping")
                return
            }
            print("[Enrich] topics: \(topics)")
            let primaryTopic = topics[0]
            let refSlug = ReferencePage.slug(date: input.sessionStartedAt, topicSlug: primaryTopic)

            // 2. Fetch the article (text + images) once — both the reference
            //    digest and the concept re-roll need pieces of this.
            let article: WebImageExtractor.FetchedArticle
            if let url = input.sourceURL, !url.isEmpty {
                article = await imageExtractor.fetch(url, imageLimit: 6)
                print("[Enrich] fetched article: \(article.text.count) chars, \(article.images.count) images")
            } else {
                article = WebImageExtractor.FetchedArticle(text: "", images: [], pageTitle: nil)
            }

            // 3. Generate the reference body (article digest with conversation woven in)
            let referenceBody: String
            do {
                referenceBody = try await referenceAuthor.write(.init(
                    sessionDate: input.sessionStartedAt,
                    articleText: article.text,
                    conversation: input.conversationMarkdown,
                    sourceURL: input.sourceURL,
                    sourceTitle: article.pageTitle,
                    primaryTopicSlug: primaryTopic
                ))
            } catch {
                print("[Enrich] reference author failed: \(error) — falling back to raw transcript body")
                referenceBody = input.conversationMarkdown
            }

            // 4. Write the reference page
            let reference = ReferencePage(
                slug: refSlug,
                sourceURL: input.sourceURL,
                anchor: anchorKind(forApp: input.sourceAppName, url: input.sourceURL),
                date: input.sessionStartedAt,
                sessionID: input.sessionID,
                topics: topics,
                learner: input.learner,
                body: referenceBody,
                anchorMetadata: .init(
                    screenshotPath: input.screenshotPath,
                    pageTitle: article.pageTitle
                )
            )
            try await gbrainSaver.putRaw(path: reference.path, body: reference.toMarkdown())
            print("[Enrich] wrote reference \(reference.path)")

            // 5. For each topic touched, load-or-create and re-roll using the reference body
            var updatedTopics: [UpsertResult] = []
            for topic in topics {
                do {
                    let result = try await upsertConcept(
                        topicSlug: topic,
                        otherTopics: topics.filter { $0 != topic },
                        referenceSlug: refSlug,
                        sessionDate: input.sessionStartedAt,
                        referenceBody: referenceBody,
                        sourceURL: input.sourceURL,
                        sourceTitle: article.pageTitle,
                        availableImages: article.images
                    )
                    updatedTopics.append(result)
                } catch {
                    print("[Enrich] failed concept upsert for \(topic): \(error)")
                }
            }

            // 6. Fire completion notification
            await fireCompletionNotification(results: updatedTopics)
            print("[Enrich] done — updated \(updatedTopics.count) topics")
        } catch {
            print("[Enrich] pipeline failed: \(error)")
            await notifier.notify("Enrichment failed: \(error)")
        }
    }

    // MARK: - Topic extraction

    private func extractTopics(transcript: String) async throws -> [String] {
        let system = """
        You read a session transcript and return the 1-3 main topics it centered on. \
        Output JSON only — an array of kebab-case slugs. No prose. No code fences.

        Topic slugs are coarse domain concepts (e.g. "rate-limiting", "circuit-breakers", \
        "backpressure"), not fine-grained ones (e.g. "token-bucket-algorithm"). Use lowercase \
        kebab-case. 1-4 words per slug. Prefer fewer, broader topics over many narrow ones.

        If the conversation is shallow or off-topic, return [] — empty array.
        """
        let user = "Session transcript:\n\n\(transcript)"

        let response = try await chatClient.send(
            messages: [["role": "user", "content": [["type": "text", "text": user]]]],
            tools: [],
            systemPrompt: system,
            maxTokens: 256
        )

        let raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = stripCodeFences(raw)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
        return arr
            .map { AnchorPath.sanitize($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Concept upsert

    struct UpsertResult {
        let topicSlug: String
        let wasNew: Bool
        let sessions: Int
        let sourceAdded: Bool
        let openQ: Int
    }

    private func upsertConcept(
        topicSlug: String,
        otherTopics: [String],
        referenceSlug: String,
        sessionDate: Date,
        referenceBody: String,
        sourceURL: String?,
        sourceTitle: String?,
        availableImages: [ExtractedImage]
    ) async throws -> UpsertResult {
        let path = "concepts/\(topicSlug)"
        let existingRaw = try await gbrainSaver.getRaw(path: path)
        let existingPage = existingRaw.flatMap { ConceptPage.parse(rawMarkdown: $0, slug: topicSlug) }

        let articleInput = ArticleAuthorInput(
            topicSlug: topicSlug,
            sessionDate: sessionDate,
            referenceBody: referenceBody,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            existingBody: existingPage?.body,
            referenceSlug: referenceSlug,
            availableImages: availableImages
        )
        let newBody = try await articleAuthor.write(articleInput)

        let depth: ConceptPage.Depth = {
            if let existing = existingPage {
                return .init(
                    sessions: existing.depth.sessions + 1,
                    sources: existing.depth.sources + (sourceURL == nil ? 0 : 1),
                    openQ: countOpenQuestions(in: newBody)
                )
            } else {
                return .init(
                    sessions: 1,
                    sources: sourceURL == nil ? 0 : 1,
                    openQ: countOpenQuestions(in: newBody)
                )
            }
        }()

        let mergedNeighbors: [String] = {
            let existing = existingPage?.neighbors ?? []
            let union = Array(Set(existing + otherTopics)).sorted()
            return union.filter { $0 != topicSlug }
        }()

        let page = ConceptPage(
            slug: topicSlug,
            depth: depth,
            neighbors: mergedNeighbors,
            created: existingPage?.created ?? sessionDate,
            updated: sessionDate,
            body: newBody
        )

        try await gbrainSaver.putRaw(path: page.path, body: page.toMarkdown())
        print("[Enrich] wrote concept \(page.path) (sessions=\(depth.sessions))")

        return UpsertResult(
            topicSlug: topicSlug,
            wasNew: existingPage == nil,
            sessions: depth.sessions,
            sourceAdded: sourceURL != nil,
            openQ: depth.openQ
        )
    }

    // MARK: - Misc

    private func countOpenQuestions(in body: String) -> Int {
        // Count bulleted lines under "## Open questions" until the next "##".
        guard let range = body.range(of: "## Open questions") else { return 0 }
        let tail = body[range.upperBound...]
        var count = 0
        for line in tail.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { count += 1 }
        }
        return count
    }

    private func anchorKind(forApp app: String?, url: String?) -> ReferencePage.AnchorKind {
        if url != nil { return .webPage }
        guard let app else { return .other }
        let lower = app.lowercased()
        if lower.contains("mail") { return .email }
        if lower.contains("preview") || lower.contains("acrobat") { return .document }
        return .other
    }

    private func fireCompletionNotification(results: [UpsertResult]) async {
        guard !results.isEmpty else { return }
        if results.count == 1 {
            let r = results[0]
            var parts: [String] = []
            if r.wasNew {
                parts.append("created")
            } else {
                parts.append("\(r.sessions) sessions")
            }
            if r.sourceAdded { parts.append("+1 source") }
            if r.openQ > 0   { parts.append("\(r.openQ) open Q\(r.openQ == 1 ? "" : "s")") }
            let suffix = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
            let title = humanTopic(r.topicSlug)
            await notifier.notifyTopicUpdated(
                topicSlug: r.topicSlug,
                body: "Topic page updated: \(title)\(suffix)"
            )
        } else {
            // Multiple topics — fire one notification listing them, tap routes
            // to the first (primary) topic.
            let primary = results[0]
            let names = results.prefix(3).map { humanTopic($0.topicSlug) }.joined(separator: ", ")
            await notifier.notifyTopicUpdated(
                topicSlug: primary.topicSlug,
                body: "Topic pages updated: \(names)"
            )
        }
    }

    private func humanTopic(_ slug: String) -> String {
        slug.components(separatedBy: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func stripCodeFences(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("```json") {
            s = String(s.dropFirst("```json".count))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
