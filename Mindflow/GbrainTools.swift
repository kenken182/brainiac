//
//  GbrainTools.swift
//  Mindflow — tool definitions + implementations for the chat agent.
//
//  Currently exposes:
//    - web_search       (Anthropic server-side, no implementation needed)
//    - gbrain_search    (custom — shells to `gbrain query`)
//    - gbrain_get       (custom — shells to `gbrain get`)
//

import Foundation

enum GbrainToolsError: Error {
    case unknownTool(String)
}

@MainActor
enum GbrainTools {
    static let gbrainPath = "/Users/keefeho/.bun/bin/gbrain"

    /// Tool definitions array for the `tools` parameter in /v1/messages.
    static let definitions: [[String: Any]] = [
        [
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": 5,
        ],
        [
            "name": "gbrain_search",
            "description":
                "Search the user's personal knowledge graph (gbrain) for pages matching a query. " +
                "Returns the top results with title, type, and slug. " +
                "Use this whenever the user asks about people, concepts, articles, or anything they might have notes about.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Natural language search query.",
                    ]
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "gbrain_get",
            "description":
                "Read the full markdown contents of a specific gbrain page by slug " +
                "(e.g. 'people/sarah-chen' or 'concepts/agentic-memory'). " +
                "Use this after gbrain_search returns a relevant slug to read its full contents.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "slug": [
                        "type": "string",
                        "description": "Page slug, e.g. 'people/sarah-chen'.",
                    ]
                ],
                "required": ["slug"],
            ],
        ],
    ]

    /// Execute a tool call from the assistant, return content for the tool_result block.
    static func execute(_ toolUse: ClaudeToolUse) async -> String {
        switch toolUse.name {
        case "gbrain_search":
            guard let query = toolUse.input["query"] as? String, !query.isEmpty else {
                return "Error: missing or empty query parameter."
            }
            return await runGbrain(args: ["query", query, "--limit", "5"])
        case "gbrain_get":
            guard let slug = toolUse.input["slug"] as? String, !slug.isEmpty else {
                return "Error: missing or empty slug parameter."
            }
            return await runGbrain(args: ["get", slug])
        default:
            return "Error: unknown tool '\(toolUse.name)'."
        }
    }

    private static func runGbrain(args: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gbrainPath)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.bun/bin"]
        env["PATH"] = "\(extraPaths.joined(separator: ":")):\(env["PATH"] ?? "/usr/bin:/bin")"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return "Error: couldn't run gbrain (\(error.localizedDescription))"
        }

        await Task.detached { process.waitUntilExit() }.value

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            return "Error (exit \(process.terminationStatus)): \(errText.isEmpty ? "no output" : errText)"
        }
        return outText.isEmpty ? "(no results)" : outText
    }
}
