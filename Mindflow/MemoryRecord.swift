//
//  MemoryRecord.swift
//  Mindflow — one row of the dashboard log. A memory = one chat session
//  (one hotkey press/release with the conversation that followed). Persisted
//  as a single JSONL line by MemoryStore. Logged when the popup hides.
//

import Foundation

struct MemoryRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let capturedAt: Date
    let initialTranscript: String
    let screenshotPath: String
    let sourceAppName: String?
    let sourceURL: String?
    let chatMessages: [PersistedChatMessage]
    let savedToGbrain: String?

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case initialTranscript = "initial_transcript"
        case screenshotPath = "screenshot_path"
        case sourceAppName = "source_app_name"
        case sourceURL = "source_url"
        case chatMessages = "chat_messages"
        case savedToGbrain = "saved_to_gbrain"
    }

    var isSaved: Bool { savedToGbrain != nil }

    var assistantMessageCount: Int {
        chatMessages.reduce(0) { acc, m in
            if case .assistant = m { return acc + 1 }
            return acc
        }
    }

    var toolCalls: [(name: String, summary: String)] {
        chatMessages.compactMap { m in
            if case .toolCall(let name, let summary) = m { return (name, summary) }
            return nil
        }
    }
}

/// Transient (in-memory only) state for the background enrichment pass that
/// runs after a session ends — extracts topics from the transcript and writes
/// reference/concept pages into gbrain. Not persisted: on relaunch every
/// memory should already be "done", since the pipeline doesn't survive quit.
enum EnrichmentStatus: Hashable {
    case processing
}

enum PersistedChatMessage: Codable, Hashable {
    case user(text: String)
    case assistant(text: String)
    case toolCall(name: String, summary: String)
    case toolResult(name: String, content: String)
    case error(message: String)

    init(_ chatMessage: ChatMessage) {
        switch chatMessage.kind {
        case .user(let text, _, _):
            self = .user(text: text)
        case .assistant(let text):
            self = .assistant(text: text)
        case .toolCall(let name, let summary):
            self = .toolCall(name: name, summary: summary)
        case .toolResult(let name, let content):
            self = .toolResult(name: name, content: content)
        case .error(let msg):
            self = .error(message: msg)
        }
    }
}
