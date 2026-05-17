//
//  MemoryRow.swift
//  Mindflow — a single row in the dashboard sidebar. Thumbnail + meta + serif
//  voice note + delta pills (replies, tool uses, saved status).
//

import SwiftUI
import AppKit

struct MemoryRow: View {
    let memory: MemoryRecord
    @Environment(AppCore.self) private var appCore

    private var isProcessing: Bool {
        appCore.memoryStore.enrichmentStatus[memory.id] == .processing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemoryThumbnail(path: memory.screenshotPath)
                .frame(width: 56, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 5) {
                metaLine
                quoteLine
                deltaLine
            }
        }
        .padding(.vertical, 4)
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(memory.capturedAt, format: .dateTime.hour().minute())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if let appName = memory.sourceAppName {
                Text("·").foregroundStyle(.tertiary)
                Text(appName)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if memory.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mfAccent)
            }
        }
    }

    private var quoteLine: some View {
        Text(memory.initialTranscript.isEmpty ? "(no voice note)" : memory.initialTranscript)
            .font(.system(.callout, design: .serif))
            .foregroundStyle(memory.initialTranscript.isEmpty ? .tertiary : .primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var deltaLine: some View {
        let toolCount = memory.toolCalls.count
        let replyCount = memory.assistantMessageCount

        HStack(spacing: 4) {
            if isProcessing {
                ProcessingPill()
            }
            if replyCount > 0 {
                DeltaPill(text: "\(replyCount) \(replyCount == 1 ? "reply" : "replies")", style: .neutral)
            }
            if toolCount > 0 {
                DeltaPill(text: "\(toolCount) \(toolCount == 1 ? "tool" : "tools")", style: .neutral)
            }
            if memory.isSaved {
                DeltaPill(text: "✦ saved", style: .accent)
            }
        }
    }
}

struct ProcessingPill: View {
    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
            Text("Extracting memories…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.mfAccent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.mfAccentBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.mfAccent.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct DeltaPill: View {
    enum Style { case accent, neutral }

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, lineWidth: 0.5)
            )
            .foregroundStyle(foregroundColor)
    }

    private var backgroundColor: Color {
        switch style {
        case .accent: return .mfAccentBg
        case .neutral: return Color.secondary.opacity(0.08)
        }
    }

    private var borderColor: Color {
        switch style {
        case .accent: return Color.mfAccent.opacity(0.3)
        case .neutral: return Color.secondary.opacity(0.18)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .accent: return .mfAccent
        case .neutral: return .secondary
        }
    }
}

struct MemoryThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .task(id: path) {
            let url = URL(fileURLWithPath: path)
            image = NSImage(contentsOf: url)
        }
    }
}
