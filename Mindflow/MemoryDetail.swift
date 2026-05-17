//
//  MemoryDetail.swift
//  Mindflow — the right pane of the dashboard. Renders the chosen memory:
//  header (time/app/url), full screenshot, the voice note as a serif quote,
//  the chat conversation, then "What was added to your brain" — the saved
//  gbrain page (if any) + every tool the agent ran during this session.
//

import SwiftUI

struct MemoryDetail: View {
    let memory: MemoryRecord
    @Environment(AppCore.self) private var appCore
    @State private var savedPageBacklinks: Int = -1
    @State private var savedPageMarkdown: String?
    @State private var showSource = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                screenshot
                voiceNote
                if !conversationMessages.isEmpty {
                    conversation
                }
                whatWasAdded
                if memory.isSaved {
                    sourceMarkdownSection
                }
            }
            .padding(36)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: memory.id) {
            await refresh()
        }
    }

    private var conversationMessages: [PersistedChatMessage] {
        Array(memory.chatMessages.dropFirst())
    }

    // MARK: - sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(memory.capturedAt, format: .dateTime.month(.wide).day().hour().minute())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let appName = memory.sourceAppName {
                    Text("·").foregroundStyle(.tertiary)
                    Text(appName)
                        .font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }

                if let urlString = memory.sourceURL, let url = URL(string: urlString) {
                    Text("·").foregroundStyle(.tertiary)
                    Link(destination: url) {
                        Text(urlString)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Text(headerTitle)
                .font(.system(.title2, design: .serif))
                .fontWeight(.medium)
        }
    }

    private var headerTitle: String {
        if let appName = memory.sourceAppName {
            return "Captured on \(appName)"
        }
        return "Captured memory"
    }

    private var screenshot: some View {
        MemoryThumbnail(path: memory.screenshotPath)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }

    private var voiceNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("You said")

            if memory.initialTranscript.isEmpty {
                Text("(no voice note this time — agent worked from the screenshot alone)")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                Text(memory.initialTranscript)
                    .font(.system(.title3, design: .serif))
                    .lineSpacing(3)
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.mfAccent)
                            .frame(width: 3)
                    }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Conversation")

            ForEach(Array(conversationMessages.enumerated()), id: \.offset) { _, msg in
                ChatMessageRow(message: msg)
            }
        }
    }

    private var whatWasAdded: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("What was added to your brain")

            if let savedTo = memory.savedToGbrain {
                SavedPageCard(slug: savedTo, backlinks: savedPageBacklinks)
            } else {
                UnsavedNotice()
            }

            let tools = memory.toolCalls
            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tools used during this session")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        ToolUseRow(name: tool.name, summary: tool.summary)
                    }
                }
            }
        }
    }

    private var sourceMarkdownSection: some View {
        DisclosureGroup(isExpanded: $showSource) {
            SourceMarkdownView(markdown: savedPageMarkdown ?? "Loading…")
                .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                Text("View source markdown (what's literally on disk in gbrain)")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func refresh() async {
        guard let savedTo = memory.savedToGbrain else {
            savedPageBacklinks = -1
            savedPageMarkdown = nil
            return
        }
        async let backlinks = appCore.gbrainClient.backlinkCount(slug: savedTo)
        async let body = appCore.gbrainClient.getPage(slug: savedTo)
        savedPageBacklinks = await backlinks
        savedPageMarkdown = await body
    }
}

// MARK: - subviews

struct ChatMessageRow: View {
    let message: PersistedChatMessage

    var body: some View {
        switch message {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 480, alignment: .trailing)
            }
        case .assistant(let text):
            HStack(alignment: .top, spacing: 10) {
                MindflowAvatar()
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .toolCall(let name, let summary):
            HStack(spacing: 8) {
                Image(systemName: ToolPresentation.icon(for: name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(ToolPresentation.label(for: name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.leading, 26)
        case .toolResult:
            EmptyView()
        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }
}

struct MindflowAvatar: View {
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.mfAccent, Color.mfAccent.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 18, height: 18)
            .overlay(
                Text("M")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .padding(.top, 2)
    }
}

struct SavedPageCard: View {
    let slug: String
    let backlinks: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SAVED TO GBRAIN")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.mfAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(slug)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()
            }

            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.mfAccentBg)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.mfAccentBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footerText: String {
        switch backlinks {
        case -1: return "Conversation written to gbrain · checking backlinks…"
        case 0: return "Conversation written to gbrain · no backlinks yet"
        case 1: return "Conversation written to gbrain · 1 backlink"
        default: return "Conversation written to gbrain · \(backlinks) backlinks"
        }
    }
}

struct UnsavedNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.slash")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("This conversation was dismissed without being committed to gbrain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolUseRow: View {
    let name: String
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ToolPresentation.icon(for: name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

enum ToolPresentation {
    static func icon(for name: String) -> String {
        switch name {
        case "gbrain_search": return "magnifyingglass"
        case "gbrain_get": return "doc.text"
        case "web_search": return "globe"
        default: return "wrench.adjustable"
        }
    }

    static func label(for name: String) -> String {
        switch name {
        case "gbrain_search": return "Searched gbrain:"
        case "gbrain_get": return "Read gbrain:"
        case "web_search": return "Searched web:"
        default: return "\(name):"
        }
    }
}
