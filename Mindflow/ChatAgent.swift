//
//  ChatAgent.swift
//  Mindflow — orchestrator for the chat agent. Holds conversation state, runs the agent loop,
//  exposes saveToGbrain(). Also owns the per-session lifecycle: startWithContext sets a
//  SessionContext, endCurrentSession (called by PopupController on hide) writes a
//  MemoryRecord to MemoryStore. Every popped-and-released hotkey produces one record.
//

import AppKit
import Foundation
import Observation

struct ChatMessage: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        /// `text` is what the user sees in the chat bubble (just the bare transcript or
        /// typed input). `agentPrompt` is what the agent actually receives — for voice
        /// captures this includes the app/URL framing that we don't want shown in chat.
        /// For typed follow-ups, `text` and `agentPrompt` are the same string.
        case user(text: String, agentPrompt: String, imageData: Data?)
        case assistant(String)
        case toolCall(name: String, summary: String)
        case toolResult(name: String, content: String)
        case error(String)
    }
}

/// One "what is the agent doing right now" beat shown in the ticker.
/// `index` is monotonic per turn so SwiftUI can identity-diff and animate the flip.
struct AgentStep: Equatable {
    let index: Int
    let kind: Kind
    let toolName: String

    enum Kind: String {
        case thinking
        case tool
        case text
    }

    var label: String {
        switch kind {
        case .thinking: return "Thinking…"
        case .text:     return "Replying…"
        case .tool:     return Self.formatTool(toolName)
        }
    }

    private static func formatTool(_ name: String) -> String {
        switch name {
        case "Read":      return "Reading file…"
        case "Write":     return "Writing file…"
        case "Edit":      return "Editing file…"
        case "Bash":      return "Running command…"
        case "Grep":      return "Searching code…"
        case "Glob":      return "Finding files…"
        case "WebFetch":  return "Fetching web page…"
        case "WebSearch": return "Searching the web…"
        case "Task":      return "Running subtask…"
        case "TodoWrite": return "Updating todos…"
        default:          return name.isEmpty ? "Working…" : "Using \(name)…"
        }
    }
}

@MainActor
@Observable
final class ChatAgent {
    /// User-facing conversation messages (drives the UI).
    private(set) var messages: [ChatMessage] = []
    /// Set true while the agent is mid-loop.
    var isThinking: Bool = false
    /// Set true while the mic is actively capturing audio (toggle-mode "hot" state).
    /// Drives the chat header's pulsing dot + listening hint so the user knows
    /// they need to tap again to send.
    var isRecording: Bool = false
    /// "Current beat" of the agent (Thinking…, Using Read…, etc.). Drives the ticker UI.
    /// Nil when the agent isn't actively processing.
    private(set) var currentStep: AgentStep? = nil
    /// Monotonic step counter for the active turn; reset at the start of each turn.
    private var stepCounter: Int = 0
    /// Text input bound to the chat composer.
    var inputDraft: String = ""
    /// After a successful save, the gbrain path lives here.
    var savedTo: String? = nil
    /// After a failed save, the error message lives here.
    var saveError: String? = nil

    private let bridge: MindflowAgentBridge?
    private let chatClient: ClaudeChatClient // fallback if bridge unavailable
    private let gbrainSaver: GbrainSaver
    private let memoryStore: MemoryStore
    /// Raw conversation in Anthropic API format. Used only when falling back to the direct API.
    private var apiMessages: [[String: Any]] = []
    /// Compact (user, assistant) history threaded into bridge turns.
    private var bridgeHistory: [(user: String, assistant: String)] = []
    private var currentSession: SessionContext?

    private struct SessionContext {
        let id: UUID
        let startedAt: Date
        let initialTranscript: String
        let screenshotPath: String
        let sourceAppName: String?
        let sourceURL: String?
    }

    init(anthropicApiKey: String, memoryStore: MemoryStore) {
        self.chatClient = ClaudeChatClient(apiKey: anthropicApiKey)
        self.gbrainSaver = GbrainSaver()
        self.memoryStore = memoryStore
        self.bridge = MindflowAgentBridge(
            systemPrompt: Self.buildSystemPrompt()
        )
        self.bridge?.warmUp()
    }

    /// System prompt — keeps token budget tight by pointing the agent at the
    /// bundled SKILL.md files instead of inlining them. The agent reads what
    /// it needs via the Read tool when the situation matches.
    private static func buildSystemPrompt() -> String {
        let skillsDir = Self.skillsDirectory()
        return """
        You are Mindflow, a personal-knowledge capture agent integrated with the user's macOS desktop and their gbrain.

        When the user holds ⌃⌥ and speaks, you receive:
        - A verbatim voice transcript
        - A screenshot of what they were looking at
        - The frontmost app name (and URL when it's Google Chrome)

        Your job: respond conversationally — explain what's on screen, search their gbrain, do quick research, help them think.

        You have Bash, Read, Write, Grep, Glob, and WebFetch tools available. For gbrain operations, shell out to the `gbrain` CLI (e.g., `gbrain put`, `gbrain search`, `gbrain list`, `gbrain get`).

        Skills bundled at \(skillsDir)/ — Read the one(s) that match the situation BEFORE acting:
        - voice-note-ingest/SKILL.md — verbatim transcript filing with decision-tree routing across originals/, concepts/, people/, companies/, ideas/, personal/, voice-notes/. Required before saving a voice note.
        - media-ingest/SKILL.md — screenshots, videos, PDFs, books, GitHub repos. Use when the screenshot is the primary signal.
        - brain-ops/SKILL.md — the canonical read/enrich/write cycle, source attribution, back-linking conventions. Required before any `gbrain put`.
        - query/SKILL.md — 3-layer search and citation propagation for looking up existing gbrain content.

        Default response shape: 1-3 sentences, conversational. Be specific. Only go long if the user asks for detail.
        """
    }

    /// Resolve where SKILL.md files live. They sit next to the vendored Node
    /// runtime in ~/Mindflow/AgentRuntime/skills/ — outside the Xcode source
    /// tree so synced groups don't flat-bundle the SKILL.md files and collide.
    private static func skillsDirectory() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Mindflow/AgentRuntime/skills")
            .path
    }

    /// Bootstrap a new conversation with screen context. Clears any previous state, then runs the agent loop.
    /// Screenshot is loaded from disk (MindflowSaver writes it before handoff).
    func startWithContext(
        sessionID: UUID,
        screenshotPath: String,
        initialTranscript: String,
        appName: String,
        url: String?
    ) async {
        print("[ChatAgent] >>> startWithContext — entry: prior messages.count=\(messages.count), prior session=\(currentSession?.id.uuidString ?? "nil")")
        // If a previous session is still hanging around (e.g. user re-pressed hotkey
        // before dismissing the prior popup), log it before starting fresh.
        if currentSession != nil {
            print("[ChatAgent]   ending prior session")
            endCurrentSession()
        }

        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSession = SessionContext(
            id: sessionID,
            startedAt: Date(),
            initialTranscript: initialTranscript,
            screenshotPath: screenshotPath,
            sourceAppName: trimmedAppName.isEmpty ? nil : trimmedAppName,
            sourceURL: url
        )

        messages.removeAll()
        apiMessages.removeAll()
        bridgeHistory.removeAll()
        print("[ChatAgent]   after removeAll: messages.count=\(messages.count)")
        savedTo = nil
        saveError = nil

        let screenshotData = (try? Data(contentsOf: URL(fileURLWithPath: screenshotPath))) ?? Data()

        let trimmedTranscript = initialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmedTranscript  // chat bubble shows just the bare transcript
        let agentPrompt: String = {
            var s = "I'm looking at \(appName)"
            if let url, !url.isEmpty { s += " (URL: \(url))" }
            s += "."
            if !trimmedTranscript.isEmpty {
                s += " I just said:\n\n\"\(trimmedTranscript)\""
            } else {
                s += " (no voice note this time — just look at the screenshot)"
            }
            return s
        }()

        messages.append(ChatMessage(kind: .user(text: displayText, agentPrompt: agentPrompt, imageData: screenshotData)))
        apiMessages.append([
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": screenshotData.base64EncodedString(),
                    ],
                ],
                [
                    "type": "text",
                    "text": agentPrompt,
                ],
            ],
        ])
        print("[ChatAgent]   appended initial user message: messages.count=\(messages.count)")

        print("[ChatAgent]   running agent loop")
        await runAgentLoop()
        print("[ChatAgent]   agent loop returned: messages.count=\(messages.count)")
    }

    /// Append another voice-capture turn (transcript + screenshot + app context) to the
    /// existing chat and run the agent loop. Used when the user holds ⌃⌥ again while
    /// the chat popup is still open — same session, additional turn, no reset.
    func appendContextTurn(
        screenshotPath: String,
        transcript: String,
        appName: String,
        url: String?
    ) async {
        print("[ChatAgent] >>> appendContextTurn — messages.count=\(messages.count)")

        let screenshotData = (try? Data(contentsOf: URL(fileURLWithPath: screenshotPath))) ?? Data()

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmedTranscript
        let agentPrompt: String = {
            var s = "I'm looking at \(appName)"
            if let url, !url.isEmpty { s += " (URL: \(url))" }
            s += "."
            if !trimmedTranscript.isEmpty {
                s += " I just said:\n\n\"\(trimmedTranscript)\""
            } else {
                s += " (no voice note this time — just look at the screenshot)"
            }
            return s
        }()

        messages.append(ChatMessage(kind: .user(text: displayText, agentPrompt: agentPrompt, imageData: screenshotData)))
        apiMessages.append([
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": screenshotData.base64EncodedString(),
                    ],
                ],
                [
                    "type": "text",
                    "text": agentPrompt,
                ],
            ],
        ])
        print("[ChatAgent]   appended turn, messages.count=\(messages.count), running agent loop")

        await runAgentLoop()
        print("[ChatAgent]   appendContextTurn returned: messages.count=\(messages.count)")
    }

    /// Append a user follow-up message and run the agent loop.
    func sendUserMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Typed follow-ups: display text == agent prompt; no app-context framing.
        messages.append(ChatMessage(kind: .user(text: trimmed, agentPrompt: trimmed, imageData: nil)))
        apiMessages.append([
            "role": "user",
            "content": [["type": "text", "text": trimmed]],
        ])

        await runAgentLoop()
    }

    /// Save the conversation as a gbrain media page.
    func saveToGbrain() async {
        guard !messages.isEmpty else { return }

        var lines: [String] = []
        for msg in messages {
            switch msg.kind {
            case .user(let text, _, _):
                lines.append("**You:** \(text)")
            case .assistant(let text):
                lines.append("**Mindflow:** \(text)")
            case .toolCall(let name, let summary):
                lines.append("_\(name): \(summary)_")
            case .toolResult:
                continue
            case .error(let msg):
                lines.append("_(error: \(msg))_")
            }
        }

        let conversation = lines.joined(separator: "\n\n")
        let slug = "mindflow-chat-\(Int(Date().timeIntervalSince1970))"
        let path = "media/\(slug)"

        do {
            try await gbrainSaver.save(
                path: path,
                transcript: conversation,
                conceptSlugs: [],
                anchorType: .other
            )
            savedTo = path
            saveError = nil
        } catch {
            saveError = "\(error)"
        }
    }

    /// Finalize the current session by appending a MemoryRecord to the store.
    /// Called by PopupController.hide() so dismissing the popup commits the
    /// session to the dashboard log. No-op if there's no active session.
    ///
    /// Also fires a fire-and-forget gbrain `put` for the full session transcript.
    /// This is the deterministic "audit log" save that runs regardless of what
    /// the agent decided to file mid-conversation.
    func endCurrentSession() {
        guard let session = currentSession else { return }
        currentSession = nil

        let snapshotMessages = messages

        let record = MemoryRecord(
            id: session.id,
            capturedAt: session.startedAt,
            initialTranscript: session.initialTranscript,
            screenshotPath: session.screenshotPath,
            sourceAppName: session.sourceAppName,
            sourceURL: session.sourceURL,
            chatMessages: snapshotMessages.map(PersistedChatMessage.init),
            savedToGbrain: savedTo
        )

        do {
            try memoryStore.append(record)
            print("[ChatAgent] logged memory \(session.id): \(snapshotMessages.count) messages, saved=\(savedTo ?? "no")")
        } catch {
            print("[ChatAgent] failed to log memory \(session.id): \(error)")
        }

        // Deterministic session-end gbrain ingest. Runs in the background so
        // popup dismissal isn't blocked. Complements (doesn't replace) anything
        // the agent already saved while the conversation was active.
        let saver = gbrainSaver
        Task {
            let body = Self.buildSessionMarkdown(session: session, messages: snapshotMessages)
            let slug = "mindflow-\(Int(session.startedAt.timeIntervalSince1970))"
            let path = "voice-notes/\(slug)"
            do {
                try await saver.putRaw(path: path, body: body)
                print("[ChatAgent] session pushed to gbrain at \(path)")
            } catch {
                print("[ChatAgent] failed to push session to gbrain: \(error)")
            }
        }

        // Clear chat state so the next popup opens fresh. The panel is already
        // invisible by the time this runs (hide's completion handler).
        messages.removeAll()
        apiMessages.removeAll()
        bridgeHistory.removeAll()
        savedTo = nil
        saveError = nil
    }

    /// Compose the markdown body written to `voice-notes/mindflow-{timestamp}` on
    /// session end. Frontmatter + verbatim voice note + full conversation replay.
    private static func buildSessionMarkdown(
        session: SessionContext,
        messages: [ChatMessage]
    ) -> String {
        let isoDate = ISO8601DateFormatter().string(from: session.startedAt)
        var s = """
        ---
        captured-at: \(isoDate)
        captured-by: Mindflow
        session-id: \(session.id.uuidString)
        anchor-type: voice-note
        """
        if let app = session.sourceAppName { s += "\nsource-app: \(app)" }
        if let url = session.sourceURL    { s += "\nsource-url: \(url)" }
        s += "\n---\n\n# Mindflow session\n\n## Voice note\n\n"
        let trimmed = session.initialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        s += trimmed.isEmpty ? "_(empty)_" : trimmed
        s += "\n\n## Conversation\n\n"
        for msg in messages {
            switch msg.kind {
            case let .user(text, _, _):
                if !text.isEmpty { s += "**You:** \(text)\n\n" }
            case let .assistant(text):
                if !text.isEmpty { s += "**Mindflow:** \(text)\n\n" }
            case let .toolCall(name, summary):
                let clipped = summary.count > 120 ? String(summary.prefix(120)) + "…" : summary
                s += "_tool \(name): \(clipped)_\n\n"
            case .toolResult:
                continue
            case let .error(msg):
                s += "_(error: \(msg))_\n\n"
            }
        }
        return s
    }

    // MARK: - private

    private func runAgentLoop() async {
        isThinking = true
        stepCounter = 0
        currentStep = AgentStep(index: 0, kind: .thinking, toolName: "")
        defer {
            isThinking = false
            currentStep = nil
        }

        if let bridge {
            await runViaBridge(bridge: bridge)
        } else {
            print("[ChatAgent] bridge unavailable; falling back to direct API")
            await runViaDirectAPI()
        }
    }

    /// Run the latest user message through the Claude Agent SDK bridge. The SDK
    /// owns the tool loop internally (Read/Write/Bash/Grep/Glob/WebFetch are all
    /// built in); we only show `tool_use` events as informational chips in the UI.
    private func runViaBridge(bridge: MindflowAgentBridge) async {
        // We send `agentPrompt` (the framed version with app/URL context) — not the
        // bare display text shown in the chat bubble.
        guard let last = messages.last, case let .user(_, userText, imageData) = last.kind else {
            return
        }

        let placeholderIndex = messages.count
        messages.append(ChatMessage(kind: .assistant("")))

        let images: [(data: Data, label: String)]
        if let imageData, !imageData.isEmpty {
            images = [(data: imageData, label: "screenshot of what the user was looking at")]
        } else {
            images = []
        }

        do {
            let result = try await bridge.sendTurn(
                images: images,
                history: bridgeHistory,
                userPrompt: userText,
                onTextChunk: { [weak self] text in
                    guard let self else { return }
                    if placeholderIndex < self.messages.count {
                        self.messages[placeholderIndex] = ChatMessage(kind: .assistant(text))
                    }
                },
                onToolUse: { [weak self] name, input in
                    let summary: String = {
                        if let v = input["query"] as? String { return v }
                        if let v = input["pattern"] as? String { return v }
                        if let v = input["file_path"] as? String { return v }
                        if let v = input["command"] as? String { return v }
                        if let v = input["slug"] as? String { return v }
                        return ""
                    }()
                    self?.messages.append(ChatMessage(kind: .toolCall(name: name, summary: summary)))
                },
                onStep: { [weak self] kind, toolName in
                    guard let self else { return }
                    let stepKind: AgentStep.Kind
                    switch kind {
                    case "thinking": stepKind = .thinking
                    case "text":     stepKind = .text
                    default:         stepKind = .tool
                    }
                    self.stepCounter += 1
                    self.currentStep = AgentStep(
                        index: self.stepCounter,
                        kind: stepKind,
                        toolName: toolName
                    )
                }
            )
            if placeholderIndex < messages.count {
                messages[placeholderIndex] = ChatMessage(kind: .assistant(result))
            }
            bridgeHistory.append((user: userText, assistant: result))
        } catch {
            if placeholderIndex < messages.count {
                messages[placeholderIndex] = ChatMessage(kind: .error("\(error)"))
            } else {
                messages.append(ChatMessage(kind: .error("\(error)")))
            }
        }
    }

    /// Fallback when the Agent SDK bridge can't spawn (Node missing, etc.). Uses the
    /// direct Anthropic API with our hand-rolled tool loop. Kept around for resilience.
    private func runViaDirectAPI() async {
        let systemPrompt = """
        You are Mindflow, an AI assistant integrated with the user's macOS desktop and personal knowledge graph (gbrain).

        The user just captured a voice note + screenshot of what they're looking at. Help them with whatever they want — \
        explain what's on screen, search their gbrain for related notes, do web research, summarize findings.

        Tool usage rules:
        - When the user mentions a person, concept, or topic they might have notes about, call gbrain_search FIRST before answering from scratch.
        - Call gbrain_get to read specific pages after gbrain_search reveals relevant slugs.
        - Use web_search for current events or things outside the user's personal notes.
        - You may call multiple tools in parallel by emitting multiple tool_use blocks in one response.

        Keep responses concise (2-4 sentences) unless the user asks for detail.
        """

        // Rebuild apiMessages from the UI messages so this path stays in sync even
        // when previous turns went through the bridge.
        apiMessages = messages.compactMap { msg -> [String: Any]? in
            switch msg.kind {
            case let .user(_, agentPrompt, imageData):
                var content: [[String: Any]] = []
                if let imageData, !imageData.isEmpty {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": imageData.base64EncodedString(),
                        ],
                    ])
                }
                content.append(["type": "text", "text": agentPrompt])
                return ["role": "user", "content": content]
            case let .assistant(text):
                return ["role": "assistant", "content": [["type": "text", "text": text]]]
            default:
                return nil
            }
        }

        let maxIterations = 6
        for _ in 0..<maxIterations {
            do {
                let response = try await chatClient.send(
                    messages: apiMessages,
                    tools: GbrainTools.definitions,
                    systemPrompt: systemPrompt
                )

                apiMessages.append(["role": "assistant", "content": response.assistantContent])

                if !response.text.isEmpty {
                    messages.append(ChatMessage(kind: .assistant(response.text)))
                }

                if response.toolUses.isEmpty { return }

                var toolResults: [[String: Any]] = []
                for use in response.toolUses {
                    let summary = (use.input["query"] as? String)
                        ?? (use.input["slug"] as? String)
                        ?? "\(use.input)"
                    messages.append(ChatMessage(kind: .toolCall(name: use.name, summary: summary)))

                    let result = use.name == "web_search"
                        ? "(handled by Anthropic)"
                        : await GbrainTools.execute(use)

                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": use.id,
                        "content": result,
                    ])
                    messages.append(ChatMessage(kind: .toolResult(name: use.name, content: result)))
                }

                apiMessages.append(["role": "user", "content": toolResults])
            } catch {
                messages.append(ChatMessage(kind: .error("\(error)")))
                return
            }
        }

        messages.append(ChatMessage(kind: .error("Reached max iterations without final answer.")))
    }
}

/// Helper for getting the current frontmost app + browser URL (Chrome only, optional).
@MainActor
enum AppContextProbe {
    static func current() -> (appName: String, url: String?) {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app"
        let url: String?
        if appName == "Google Chrome" {
            url = chromeActiveTabURL()
        } else {
            url = nil
        }
        return (appName, url)
    }

    private static func chromeActiveTabURL() -> String? {
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error { print("[AppContextProbe] AppleScript error: \(error)"); return nil }
        let url = result?.stringValue ?? ""
        return url.isEmpty ? nil : url
    }
}
