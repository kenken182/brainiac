//
//  MindflowAgentBridge.swift
//  Mindflow — Swift side of the Claude Agent SDK bridge. Spawns Node running
//  Resources/AgentBridge/bridge.mjs and streams turns over JSON-line stdio.
//

import AppKit
import Foundation

@MainActor
final class MindflowAgentBridge {
    typealias TextChunkHandler = @MainActor @Sendable (String) -> Void
    typealias ToolUseHandler = @MainActor @Sendable (_ name: String, _ input: [String: Any]) -> Void
    /// Fires on each content_block_start so the UI can flip its ticker.
    /// `kind` is "tool", "thinking", or "text". `toolName` is non-empty only for "tool".
    typealias StepHandler = @MainActor @Sendable (_ kind: String, _ toolName: String) -> Void

    var model: String
    var maxOutputTokens: Int
    var systemPrompt: String

    private let nodeExecutableURL: URL
    private let bridgeScriptURL: URL
    private let claudeExecutableURL: URL?
    private let fileManager: FileManager
    private let workingDirectory: URL

    private var bridgeProcess: Process?
    private var bridgeInput: FileHandle?
    private var bridgeOutput: FileHandle?
    private var bridgeError: FileHandle?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    private struct PendingRequest {
        let id: String
        let onTextChunk: TextChunkHandler?
        let onToolUse: ToolUseHandler?
        let onStep: StepHandler?
        let continuation: CheckedContinuation<String, Error>
        var accumulated: String
    }
    private var pending: [String: PendingRequest] = [:]
    private var activeSystemPromptHash: Int?
    private var activeModel: String?

    init?(
        model: String = "claude-sonnet-4-6",
        maxOutputTokens: Int = 64_000,
        systemPrompt: String,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) {
        guard let node = Self.findNode(fileManager: fileManager),
              let bridge = Self.findBridgeScript(fileManager: fileManager) else {
            print("[MindflowAgentBridge] init failed: node=\(Self.findNode(fileManager: fileManager) != nil) bridge=\(Self.findBridgeScript(fileManager: fileManager) != nil)")
            return nil
        }
        self.nodeExecutableURL = node
        self.bridgeScriptURL = bridge
        self.claudeExecutableURL = Self.findClaude(fileManager: fileManager)
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.systemPrompt = systemPrompt
        print("[MindflowAgentBridge] ready: node=\(node.path) bridge=\(bridge.path) claude=\(claudeExecutableURL?.path ?? "<missing>")")
    }

    deinit {
        bridgeProcess?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        bridgeProcess?.terminate()
    }

    /// Warm the bridge so the first real turn is faster.
    func warmUp() {
        Task { [weak self] in
            do {
                _ = try await self?.sendInternal(
                    kind: "warmup",
                    images: [],
                    history: [],
                    userPrompt: "Reply 'ready' only. Prime the session.",
                    onTextChunk: nil,
                    onToolUse: nil,
                    onStep: nil
                )
            } catch {
                print("[MindflowAgentBridge] warmup failed: \(error)")
            }
        }
    }

    /// Send a single turn. Returns the final assistant text once the SDK emits `result`.
    /// `onTextChunk` is called on every streaming delta with the cumulative text so far.
    /// `onToolUse` is called whenever Claude emits a tool_use block (informational only —
    /// the SDK executes the tool itself in the Node subprocess; this is for UI hints).
    func sendTurn(
        images: [(data: Data, label: String)] = [],
        history: [(user: String, assistant: String)] = [],
        userPrompt: String,
        onTextChunk: TextChunkHandler? = nil,
        onToolUse: ToolUseHandler? = nil,
        onStep: StepHandler? = nil
    ) async throws -> String {
        try await sendInternal(
            kind: "request",
            images: images,
            history: history,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk,
            onToolUse: onToolUse,
            onStep: onStep
        )
    }

    func stop() {
        let process = bridgeProcess
        bridgeProcess = nil
        process?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeModel = nil
        activeSystemPromptHash = nil
        process?.terminate()
        failPending(error: NSError(domain: "MindflowAgentBridge", code: -10,
            userInfo: [NSLocalizedDescriptionKey: "bridge stopped"]))
    }

    // MARK: - private internals

    private func sendInternal(
        kind: String,
        images: [(data: Data, label: String)],
        history: [(user: String, assistant: String)],
        userPrompt: String,
        onTextChunk: TextChunkHandler?,
        onToolUse: ToolUseHandler?,
        onStep: StepHandler?
    ) async throws -> String {
        try ensureBridge()

        let requestID = UUID().uuidString
        let attachments: [[String: Any]] = images.map { img in
            [
                "label": img.label,
                "mediaType": img.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg",
                "data": img.data.base64EncodedString(),
            ]
        }
        let historyArr: [[String: Any]] = history.map { ["user": $0.user, "assistant": $0.assistant] }
        let payload: [String: Any] = [
            "type": kind,
            "id": requestID,
            "systemPrompt": systemPrompt,
            "prompt": userPrompt,
            "conversationHistory": historyArr,
            "images": attachments,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingRequest(
                id: requestID,
                onTextChunk: onTextChunk,
                onToolUse: onToolUse,
                onStep: onStep,
                continuation: continuation,
                accumulated: ""
            )
            do {
                try writeCommand(payload)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func ensureBridge() throws {
        let promptHash = systemPrompt.hashValue
        if let p = bridgeProcess, p.isRunning,
           activeModel == model,
           activeSystemPromptHash == promptHash,
           bridgeInput != nil {
            return
        }
        stop()

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.executableURL = nodeExecutableURL
        proc.arguments = [bridgeScriptURL.path]
        proc.currentDirectoryURL = workingDirectory
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.environment = buildEnvironment()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consumeStdout(text) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consumeStderr(text) }
        }
        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: process.terminationStatus)
            }
        }

        try proc.run()

        bridgeProcess = proc
        bridgeInput = inPipe.fileHandleForWriting
        bridgeOutput = outPipe.fileHandleForReading
        bridgeError = errPipe.fileHandleForReading
        activeModel = model
        activeSystemPromptHash = promptHash
        print("[MindflowAgentBridge] spawned node bridge pid=\(proc.processIdentifier)")
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let nodeDir = nodeExecutableURL.deletingLastPathComponent().path
        let baseline = "/Users/\(NSUserName())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [nodeDir, env["PATH"] ?? "", baseline].filter { !$0.isEmpty }.joined(separator: ":")
        if let claude = claudeExecutableURL {
            env["MINDFLOW_CLAUDE_EXECUTABLE"] = claude.path
        }
        env["MINDFLOW_CLAUDE_MODEL"] = model
        env["MINDFLOW_CLAUDE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        env["MINDFLOW_CLAUDE_CWD"] = workingDirectory.path
        env["MINDFLOW_CLAUDE_SYSTEM_PROMPT"] = systemPrompt
        env["MINDFLOW_CLAUDE_AGENT_SDK_PATHS"] = sdkSearchPaths().joined(separator: ":")
        env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "mindflow/0.1"
        return env
    }

    private func sdkSearchPaths() -> [String] {
        let bridgeDir = bridgeScriptURL.deletingLastPathComponent().path
        let home = fileManager.homeDirectoryForCurrentUser
        // Vendored runtime sits next to the source tree, NOT inside the bundle —
        // bundling node_modules causes Xcode to flat-copy thousands of files into
        // Contents/Resources and collide on duplicated filenames. See AgentRuntime/.
        let mindflowRuntime = home
            .appendingPathComponent("Mindflow/AgentRuntime/node_modules", isDirectory: true).path
        var paths: Set<String> = [
            bridgeDir,
            "\(bridgeDir)/node_modules",
            mindflowRuntime,
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules",
            home.appendingPathComponent(".nvm/versions/node", isDirectory: true).path,
        ]
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for v in versions {
                paths.insert(v.appendingPathComponent("lib/node_modules", isDirectory: true).path)
            }
        }
        return Array(paths).sorted()
    }

    private func writeCommand(_ command: [String: Any]) throws {
        guard let input = bridgeInput else {
            throw NSError(domain: "MindflowAgentBridge", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "bridge stdin unavailable"])
        }
        let data = try JSONSerialization.data(withJSONObject: command)
        input.write(data)
        input.write(Data("\n".utf8))
    }

    private func consumeStdout(_ text: String) {
        stdoutBuffer += text
        let parts = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = parts.last ?? ""
        for line in parts.dropLast() { handleLine(line) }
    }

    private func consumeStderr(_ text: String) {
        stderrBuffer += text
        let parts = stderrBuffer.components(separatedBy: "\n")
        stderrBuffer = parts.last ?? ""
        for line in parts.dropLast() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("[MindflowAgentBridge.stderr] \(line.prefix(500))")
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            print("[MindflowAgentBridge] sdk ready: \(event["sdkPath"] ?? "?")")
        case "started":
            break
        case "delta":
            guard let id = event["id"] as? String, var req = pending[id] else { return }
            let text = (event["text"] as? String) ?? ""
            req.accumulated = text
            pending[id] = req
            req.onTextChunk?(text)
        case "step":
            guard let id = event["id"] as? String, let req = pending[id] else { return }
            let kind = (event["kind"] as? String) ?? "tool"
            let toolName = (event["tool_name"] as? String) ?? ""
            req.onStep?(kind, toolName)
        case "tool_use":
            guard let id = event["id"] as? String, let req = pending[id] else { return }
            let name = (event["tool_name"] as? String) ?? ""
            let input = (event["input"] as? [String: Any]) ?? [:]
            req.onToolUse?(name, input)
        case "result":
            guard let id = event["id"] as? String, let req = pending.removeValue(forKey: id) else { return }
            let text = (event["text"] as? String) ?? req.accumulated
            req.continuation.resume(returning: text)
        case "error":
            let id = (event["id"] as? String) ?? ""
            let message = (event["message"] as? String) ?? "unknown bridge error"
            if let req = pending.removeValue(forKey: id) {
                req.continuation.resume(throwing: NSError(domain: "MindflowAgentBridge", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                print("[MindflowAgentBridge] unrouted error: \(message)")
            }
        default:
            break
        }
    }

    private func handleTermination(status: Int32) {
        print("[MindflowAgentBridge] bridge process exited status=\(status)")
        failPending(error: NSError(domain: "MindflowAgentBridge", code: -11,
            userInfo: [NSLocalizedDescriptionKey: "bridge exited with status \(status)"]))
        bridgeProcess = nil
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeModel = nil
        activeSystemPromptHash = nil
    }

    private func failPending(error: Error) {
        let remaining = pending
        pending.removeAll()
        for (_, req) in remaining { req.continuation.resume(throwing: error) }
    }

    // MARK: - executable discovery

    private static func findNode(fileManager: FileManager) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["MINDFLOW_NODE_EXECUTABLE"],
           fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let pathCandidates = (env["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        let fixed = [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ]
        let home = fileManager.homeDirectoryForCurrentUser
        var nvmCandidates: [URL] = []
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            nvmCandidates = versions
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                .map { $0.appendingPathComponent("bin/node") }
        }
        return (pathCandidates + fixed + nvmCandidates).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private static func findClaude(fileManager: FileManager) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["MINDFLOW_CLAUDE_EXECUTABLE"],
           fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let pathCandidates = (env["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let fixed = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return (pathCandidates + fixed).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private static func findBridgeScript(fileManager: FileManager) -> URL? {
        // 1) Bundle resource — Xcode's synced groups flatten our subfolders, so try
        //    the AgentBridge/ subdir form first (proper folder ref) then the flat form.
        if let bundled = Bundle.main.url(forResource: "bridge", withExtension: "mjs", subdirectory: "AgentBridge") {
            return bundled
        }
        if let bundledFlat = Bundle.main.url(forResource: "bridge", withExtension: "mjs") {
            return bundledFlat
        }
        // 2) Source-tree fallback for development (running outside the bundle).
        let dev = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Mindflow/Mindflow/Resources/AgentBridge/bridge.mjs")
        if fileManager.isReadableFile(atPath: dev.path) {
            return dev
        }
        return nil
    }
}
