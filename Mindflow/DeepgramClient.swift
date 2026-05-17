//
//  DeepgramClient.swift
//  Mindflow — synchronous POST .wav → transcript via Deepgram.
//

import Foundation

enum DeepgramError: Error {
    case requestFailed(Int)
    case responseParseFailed
}

@MainActor
final class DeepgramClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    func transcribe(wavFile: URL) async throws -> String {
        let audioData = try Data(contentsOf: wavFile)

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DeepgramError.requestFailed(statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let results = json?["results"] as? [String: Any],
            let channels = results["channels"] as? [[String: Any]],
            let firstChannel = channels.first,
            let alternatives = firstChannel["alternatives"] as? [[String: Any]],
            let firstAlt = alternatives.first,
            let transcript = firstAlt["transcript"] as? String
        else {
            throw DeepgramError.responseParseFailed
        }
        return transcript
    }
}
