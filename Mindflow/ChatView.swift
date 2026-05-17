//
//  ChatView.swift
//  Mindflow — chat surface that takes over the popup once the agent has a turn going.
//  Light-mode visual language matching docs/chat-tool-stream-mocks.html Variant 1.
//

import SwiftUI

struct ChatView: View {
    @Bindable var agent: ChatAgent
    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onResize: ((CGSize) -> Void)? = nil
    /// Called when the user clicks a `brainiac://` link in an agent message.
    /// Routes through PopupController → AppCore.openLearningLink.
    var onOpenURL: ((URL) -> Void)? = nil

    private static let userBubbleFill = Color(red: 0.86, green: 0.93, blue: 0.98)
    private static let userBubbleText = Color(red: 0.10, green: 0.32, blue: 0.55)
    private static let assistantFill = Color(red: 0.955, green: 0.952, blue: 0.940)
    private static let warmAccent    = Color(red: 0.72, green: 0.36, blue: 0.16)
    private static let greenAccent   = Color(red: 0.18, green: 0.55, blue: 0.22)
    private static let roseAccent    = Color(red: 0.72, green: 0.27, blue: 0.42)
    private static let kbdFill       = Color(red: 0.90, green: 0.90, blue: 0.88)
    private static let inputFill     = Color(red: 0.96, green: 0.96, blue: 0.95)
    private static let inputStroke   = Color.black.opacity(0.08)

    /// Parse the given string as inline markdown so **bold**, *italic*, `code`, and
    /// [links](url) render in chat bubbles. Newlines are preserved. Falls back to
    /// plain text on parse failure.
    private static func markdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// One renderable block in a chat message — paragraphs, headings, lists, and
    /// fenced code blocks. The bubble renders each as its own SwiftUI view so we
    /// get real visual separation between paragraphs and proper bullet/number
    /// indentation, instead of one mashed-together Text.
    private enum TextBlock {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case bulletList([AttributedString])
        case numberedList([AttributedString])
        case codeBlock(String)
    }

    /// Split a message body into TextBlocks. Splits on blank lines (`\n\n`) for
    /// paragraph boundaries, then sniffs each chunk for heading / list / code
    /// patterns. Inline markdown inside each block is still parsed by `markdown(_:)`.
    private static func parseBlocks(_ text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let chunks = text.components(separatedBy: "\n\n")
        for raw in chunks {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }

            // Fenced code block: ```\n...\n``` (with optional language tag on the opener)
            if chunk.hasPrefix("```") && chunk.hasSuffix("```") && chunk.count > 6 {
                var inner = String(chunk.dropFirst(3).dropLast(3))
                if let nl = inner.firstIndex(of: "\n") {
                    inner = String(inner[inner.index(after: nl)...])
                }
                blocks.append(.codeBlock(inner.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // Headings — match before list / paragraph
            if chunk.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: markdown(String(chunk.dropFirst(4)))))
                continue
            }
            if chunk.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: markdown(String(chunk.dropFirst(3)))))
                continue
            }
            if chunk.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: markdown(String(chunk.dropFirst(2)))))
                continue
            }

            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            // Bullet list — every non-empty line starts with "- " or "* "
            let bulletLines = lines.filter { !$0.isEmpty }
            if !bulletLines.isEmpty, bulletLines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
                let items = bulletLines.map { markdown(String($0.dropFirst(2))) }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list — every non-empty line starts with "<digits>. "
            if !bulletLines.isEmpty, bulletLines.allSatisfy({ $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }) {
                let items = bulletLines.map { line -> AttributedString in
                    let stripped = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    return markdown(stripped)
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Fall through: plain paragraph (preserves internal `\n` line breaks)
            blocks.append(.paragraph(markdown(chunk)))
        }
        return blocks
    }

    /// Render a single TextBlock with the given foreground color. Used for both
    /// user (blue) and assistant (black) bubbles.
    @ViewBuilder
    private func blockView(_ block: TextBlock, color: Color) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(text)
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(color.opacity(0.55))
                        Text(item)
                            .foregroundStyle(color)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 13))
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(color.opacity(0.55))
                            .monospacedDigit()
                        Text(item)
                            .foregroundStyle(color)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 13))
                }
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.05))
                )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            messageList
            footer
            composer
        }
        .background(Color.white)
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip { delta in
                onResize?(delta)
            }
            .padding(.trailing, 3)
            .padding(.bottom, 3)
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "brainiac" {
                onOpenURL?(url)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            PulseDot(color: headerDotColor, animated: agent.isRecording)
            Text("Brainiac")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(agent.isRecording ? Self.roseAccent : .black)
            Spacer()
            Text(headerStatus)
                .font(.system(size: 12, weight: agent.isRecording ? .semibold : .regular))
                .foregroundStyle(agent.isRecording ? Self.roseAccent : .secondary)
            Button {
                onMinimize?()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Minimize — keeps the session alive; restore from the menu bar.")
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close — ends the session.")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var headerDotColor: Color {
        if agent.isRecording { return Self.roseAccent }
        if agent.saveError != nil { return .red }
        if agent.isThinking { return Self.warmAccent }
        return Self.greenAccent
    }

    private var headerStatus: String {
        if agent.isRecording { return "Listening…" }
        if agent.saveError != nil { return "Failed" }
        if agent.isThinking { return "Working…" }
        return "Ready"
    }

    // MARK: - message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let lastVisibleID = lastVisibleMessageID
                    ForEach(Array(agent.messages.enumerated()), id: \.element.id) { _, msg in
                        messageRow(msg, isLast: msg.id == lastVisibleID)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            // Scroll on new messages AND on streaming text growth of the last
            // assistant message (count alone doesn't fire while the same row's
            // text grows chunk by chunk).
            .onChange(of: agent.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: lastVisibleContent) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    /// ID of the last *visible* message (toolCall/toolResult render as EmptyView,
    /// so they shouldn't count). Drives the assistant bubble's "isLast" affordances
    /// — the loading placeholder and the agent ticker — so they stay attached to
    /// the in-progress assistant bubble while the SDK is firing tool_use blocks.
    private var lastVisibleMessageID: UUID? {
        agent.messages.last { msg in
            switch msg.kind {
            case .toolCall, .toolResult: return false
            default: return true
            }
        }?.id
    }

    /// A string that changes whenever the bottom of the chat visually changes:
    /// message count, the last message's text content, and the ticker state.
    /// Used as a single `.onChange` key so streaming deltas always scroll.
    private var lastVisibleContent: String {
        var key = "\(agent.messages.count)|"
        if let last = agent.messages.last {
            switch last.kind {
            case .assistant(let text): key += "a:\(text.count)"
            case .user(let text, _, _): key += "u:\(text.count)"
            case .toolCall(let name, let summary): key += "tc:\(name):\(summary.count)"
            case .toolResult(let name, let content): key += "tr:\(name):\(content.count)"
            case .error(let msg): key += "e:\(msg.count)"
            }
        }
        if let step = agent.currentStep {
            key += "|step:\(step.index):\(step.kind.rawValue)"
        }
        return key
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let last = agent.messages.last else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage, isLast: Bool) -> some View {
        switch msg.kind {
        case .user(let text, _, _):
            // Silent captures have empty display text — the screenshot was for the
            // agent, not the user. Skip the empty bubble in that case.
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.parseBlocks(text).enumerated()), id: \.offset) { _, block in
                        blockView(block, color: Self.userBubbleText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Self.userBubbleFill)
                )
            }

        case .assistant(let text):
            assistantBubble(text: text, isLast: isLast)

        case .toolCall, .toolResult:
            // Tool activity is surfaced by the inline ticker; rows are hidden.
            // Data still lives in `messages` for the saved transcript.
            EmptyView()

        case .error(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
        }
    }

    private func assistantBubble(text: String, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if text.isEmpty && isLast && agent.isThinking {
                HStack(spacing: 8) {
                    TickerSpinner(color: Self.warmAccent)
                        .frame(width: 11, height: 11)
                    Text("Thinking…")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(.secondary)
                }
            } else if !text.isEmpty {
                ForEach(Array(Self.parseBlocks(text).enumerated()), id: \.offset) { _, block in
                    blockView(block, color: .black)
                }
            }
            if isLast, let step = agent.currentStep {
                TickerView(step: step)
                    .id(step.index)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.assistantFill)
        )
        .animation(.easeOut(duration: 0.28), value: agent.currentStep?.index ?? -1)
    }

    // MARK: - footer hints

    private var footer: some View {
        HStack {
            kbdHint(keys: "⌃⌥", caption: footerHotkeyCaption)
            Spacer()
            endChatButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var footerHotkeyCaption: String {
        if agent.isRecording { return "release to send" }
        if agent.isThinking { return "working…" }
        return "hold to talk"
    }

    private var endChatButton: some View {
        Button {
            onClose?()
        } label: {
            HStack(spacing: 6) {
                Text("End chat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("⌥⎋")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Self.kbdFill)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("End this chat — clears state and pushes the session to gbrain.")
    }

    private func kbdHint(keys: String, caption: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Self.kbdFill)
                )
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - composer

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Ask Brainiac…", text: $agent.inputDraft, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Self.inputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Self.inputStroke, lineWidth: 0.5)
                )
                .onSubmit { send() }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(canSend ? Self.warmAccent : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private var canSend: Bool {
        !agent.inputDraft.trimmingCharacters(in: .whitespaces).isEmpty && !agent.isThinking
    }

    private func send() {
        let text = agent.inputDraft
        agent.inputDraft = ""
        Task { await agent.sendUserMessage(text) }
    }
}

// MARK: - Inline ticker (Variant 1)

private struct TickerView: View {
    let step: AgentStep

    private static let accent = Color(red: 0.72, green: 0.36, blue: 0.16)

    var body: some View {
        HStack(spacing: 8) {
            TickerSpinner(color: Self.accent)
                .frame(width: 11, height: 11)
            Text(step.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Self.accent)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.accent.opacity(0.08))
        )
    }
}

private struct TickerSpinner: View {
    let color: Color
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}

// MARK: - Pulsing status dot

/// Tiny dot with an animated expanding halo when `animated` is true. Used in the
/// chat header to make the "Listening…" state unmistakable while toggle-mode is hot.
private struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var halo = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .scaleEffect(halo ? 2.6 : 1)
                    .opacity(halo ? 0 : 0.55)
            }
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 11, height: 11)
        .onAppear { triggerHalo() }
        .onChange(of: animated) { _, isOn in
            if isOn { triggerHalo() } else { halo = false }
        }
    }

    private func triggerHalo() {
        guard animated else { return }
        halo = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            halo = true
        }
    }
}

// MARK: - Resize grip

/// Tiny three-line diagonal grip in the bottom-right corner. Drag fires `onDrag`
/// with incremental size deltas — PopupController applies them to the NSPanel.
private struct ResizeGrip: View {
    let onDrag: (CGSize) -> Void
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let stroke = GraphicsContext.Shading.color(Color.black.opacity(0.28))
            for i in 0..<3 {
                let offset = CGFloat(i) * 4
                var path = Path()
                path.move(to: CGPoint(x: size.width - 2, y: size.height - 10 + offset))
                path.addLine(to: CGPoint(x: size.width - 10 + offset, y: size.height - 2))
                context.stroke(path, with: stroke, lineWidth: 1.2)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let delta = CGSize(
                        width: value.translation.width - lastTranslation.width,
                        height: value.translation.height - lastTranslation.height
                    )
                    onDrag(delta)
                    lastTranslation = value.translation
                }
                .onEnded { _ in
                    lastTranslation = .zero
                }
        )
    }
}
