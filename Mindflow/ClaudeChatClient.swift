//
//  ClaudeChatClient.swift
//  Mindflow — multi-turn Anthropic /v1/messages client with tool-use parsing.
//

import Foundation

enum ClaudeChatError: Error {
    case requestFailed(Int, String)
    case responseParseFailed
}

/// Parsed response from a /v1/messages call.
struct ClaudeChatResponse {
    /// "end_turn" (final response), "tool_use" (wants to call tools), "max_tokens", etc.
    let stopReason: String
    /// Text blocks from the assistant's response, joined.
    let text: String
    /// Tool-use blocks the assistant wants the caller to execute, in order.
    let toolUses: [ClaudeToolUse]
    /// Raw assistant content blocks — append to the conversation as the next assistant message.
    let assistantContent: [[String: Any]]
}

struct ClaudeToolUse {
    let id: String
    let name: String
    let input: [String: Any]
}

@MainActor
final class ClaudeChatClient {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Send a conversation, get an assistant response (possibly with tool-use blocks).
    /// - Parameters:
    ///   - messages: full conversation history. Each message has `role` ("user"|"assistant") and `content` (array of blocks).
    ///   - tools: tool definitions. Empty array if no tools wanted.
    ///   - systemPrompt: optional system instruction.
    ///   - maxTokens: response budget.
    func send(
        messages: [[String: Any]],
        tools: [[String: Any]] = [],
        systemPrompt: String? = nil,
        maxTokens: Int = 4096
    ) async throws -> ClaudeChatResponse {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let systemPrompt {
            body["system"] = systemPrompt
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeChatError.requestFailed(statusCode, bodyText)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let stopReason = json["stop_reason"] as? String
        else {
            throw ClaudeChatError.responseParseFailed
        }

        var textParts: [String] = []
        var toolUses: [ClaudeToolUse] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let t = block["text"] as? String { textParts.append(t) }
            case "tool_use":
                if
                    let id = block["id"] as? String,
                    let name = block["name"] as? String,
                    let input = block["input"] as? [String: Any]
                {
                    toolUses.append(ClaudeToolUse(id: id, name: name, input: input))
                }
            default:
                continue
            }
        }

        return ClaudeChatResponse(
            stopReason: stopReason,
            text: textParts.joined(separator: "\n\n"),
            toolUses: toolUses,
            assistantContent: content
        )
    }
}
