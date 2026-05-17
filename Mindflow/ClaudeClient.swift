//
//  ClaudeClient.swift
//  Mindflow — Anthropic /v1/messages client for vision calls (PNG + text → string response).
//

import Foundation

enum ClaudeError: Error {
    case requestFailed(Int, String)
    case responseParseFailed
}

@MainActor
final class ClaudeClient {
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

    func sendVision(
        imagePNG: Data,
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 4096
    ) async throws -> String {
        let base64Image = imagePNG.base64EncodedString()

        let messageContent: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": base64Image,
                ],
            ],
            [
                "type": "text",
                "text": prompt,
            ],
        ]

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": messageContent,
                ]
            ],
        ]
        if let systemPrompt {
            body["system"] = systemPrompt
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
            throw ClaudeError.requestFailed(statusCode, bodyText)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let content = json?["content"] as? [[String: Any]],
            let firstBlock = content.first,
            let text = firstBlock["text"] as? String
        else {
            throw ClaudeError.responseParseFailed
        }
        return text
    }
}
