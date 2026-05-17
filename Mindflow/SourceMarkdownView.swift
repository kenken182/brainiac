//
//  SourceMarkdownView.swift
//  Mindflow — read-only monospaced display of a gbrain page's raw markdown.
//  Shown in the detail pane when the user expands "View source markdown".
//  v1 keeps it simple (no syntax highlighting); edit-in-place is a future task.
//

import SwiftUI

struct SourceMarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(markdown)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
