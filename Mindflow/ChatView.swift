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
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            PulseDot(color: headerDotColor, animated: agent.isRecording)
            Text("Mindflow")
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
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(agent.messages.enumerated()), id: \.element.id) { idx, msg in
                        messageRow(msg, isLast: idx == agent.messages.count - 1)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: agent.messages.count) { _, _ in
                if let last = agent.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage, isLast: Bool) -> some View {
        switch msg.kind {
        case .user(let text, _, _):
            // Silent captures have empty display text — the screenshot was for the
            // agent, not the user. Skip the empty bubble in that case.
            if !text.isEmpty {
                Text(Self.markdown(text))
                    .font(.system(size: 13))
                    .foregroundStyle(Self.userBubbleText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Self.userBubbleFill)
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 8) {
            if text.isEmpty && isLast && agent.isThinking {
                Text("Capturing your note…")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.secondary)
            } else if !text.isEmpty {
                Text(Self.markdown(text))
                    .font(.system(size: 13))
                    .foregroundStyle(.black)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            kbdHint(keys: "⌥⎋", caption: "close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerHotkeyCaption: String {
        if agent.isRecording { return "tap to send" }
        if agent.isThinking { return "working…" }
        return "tap to talk"
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
            TextField("Ask Mindflow…", text: $agent.inputDraft, axis: .vertical)
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
