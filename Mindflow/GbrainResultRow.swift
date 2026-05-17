//
//  GbrainResultRow.swift
//  Mindflow — sidebar row for a single gbrain search hit. Mirrors MemoryRow's
//  visual rhythm (compact, two-line, monospaced meta) but shows slug + preview
//  instead of timestamp + voice note.
//

import SwiftUI

struct GbrainResultRow: View {
    let result: GbrainSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            slugLine
            previewLine
        }
        .padding(.vertical, 4)
    }

    private var slugLine: some View {
        HStack(spacing: 6) {
            if let dir = result.directory {
                Text(dir)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.mfAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3).fill(Color.mfAccentBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.mfAccentBorder, lineWidth: 0.5)
                    )
            }
            Text(result.leaf)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var previewLine: some View {
        let trimmed = result.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
