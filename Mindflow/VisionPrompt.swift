//
//  VisionPrompt.swift
//  Mindflow — sends (screenshot + transcript) to Claude, returns structured VisionResult.
//

import Foundation

enum VisionPromptError: Error {
    case invalidJSON(String)
    case decodingFailed(String)
}

@MainActor
final class VisionPrompt {
    private let claudeClient: ClaudeClient

    init(claudeClient: ClaudeClient) {
        self.claudeClient = claudeClient
    }

    func extract(imagePNG: Data, transcript: String) async throws -> VisionResult {
        let prompt = """
        You're looking at a screenshot from the user's screen, plus a voice transcript of what they said while looking at it.

        Voice transcript:
        \(transcript.isEmpty ? "(empty — user pressed the hotkey without speaking)" : transcript)

        Return JSON only (no prose, no code fences) with this exact shape:
        {
          "anchor_type": "linkedin" | "email" | "article" | "other",
          "slug": "<kebab-case slug>",
          "concepts": ["<noun phrase 1>", "<noun phrase 2>", ...]
        }

        Rules:
        - anchor_type: "linkedin" if a LinkedIn profile/post/page is visible. "email" if an email client (Gmail, Apple Mail, etc.) is showing a message. "article" if a blog post, paper, docs page. "other" for everything else.
        - slug: short kebab-case identifier identifying the thing on screen — person name for linkedin (e.g. "sarah-chen"), email subject + sender for email (e.g. "collab-request-sarah"), article title for article. No spaces, no slashes, no leading dashes.
        - concepts: 3-8 noun phrases (2-6 words each) capturing the technical/domain ideas the user mentioned in the voice note OR that are central to what's on screen. Prefer coarse concepts ("rate limiting") over fine ones ("token bucket algorithm").

        Return ONLY the JSON object.
        """

        let response = try await claudeClient.sendVision(
            imagePNG: imagePNG,
            prompt: prompt
        )

        let cleaned = stripCodeFences(response)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw VisionPromptError.invalidJSON(cleaned)
        }

        do {
            return try JSONDecoder().decode(VisionResult.self, from: jsonData)
        } catch {
            throw VisionPromptError.decodingFailed(cleaned)
        }
    }

    private func stripCodeFences(_ response: String) -> String {
        var s = response.trimmingCharacters(in: .whitespacesAndNewlines)
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
