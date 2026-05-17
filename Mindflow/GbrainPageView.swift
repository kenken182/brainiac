//
//  GbrainPageView.swift
//  Mindflow — detail pane for a brain page picked from the search sidebar.
//  Fetches the page's markdown + backlink count via GbrainClient, renders the
//  raw markdown via SourceMarkdownView in display mode, and swaps to a
//  monospaced TextEditor for edit mode. Save round-trips via `gbrain put`;
//  delete confirms then calls `gbrain delete`, after which the parent clears
//  the selection so the row disappears.
//

import SwiftUI
import AppKit

struct GbrainPageView: View {
    let slug: String
    /// Called after a successful delete so the parent can drop the selection
    /// and refresh the active search results (the deleted slug should vanish).
    var onDelete: (() -> Void)? = nil
    /// Called when the user clicks a backlink — the parent should swap the
    /// dashboard selection to that page so it loads in the detail pane.
    var onOpenPage: ((String) -> Void)? = nil

    @Environment(AppCore.self) private var appCore

    @State private var pageBody: String? = nil
    @State private var backlinks: [GbrainBacklink] = []
    @State private var backlinksLoaded: Bool = false
    @State private var loading: Bool = true

    @State private var isEditing: Bool = false
    @State private var editingDraft: String = ""
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    @State private var showDeleteConfirm: Bool = false
    @State private var isDeleting: Bool = false
    @State private var deleteError: String? = nil

    var body: some View {
        Group {
            if isEditing {
                editLayout
            } else {
                displayLayout
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: slug) { await load() }
        .confirmationDialog(
            "Delete \(slug)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete page", role: .destructive) {
                Task { await deletePage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the page from your brain. It can't be undone from Brainiac.")
        }
    }

    // MARK: - layouts

    private var displayLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if loading {
                    unifiedLoader
                } else {
                    if !backlinks.isEmpty {
                        backlinksSection
                    }
                    Divider()
                    loadedContent
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unifiedLoader: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading page from your brain…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        .padding(.top, 32)
    }

    private var editLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let err = saveError {
                    errorBanner(err)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Divider()

            TextEditor(text: $editingDraft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.secondary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .disabled(isSaving)
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let dir = directory {
                    Text(dir)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.mfAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.mfAccentBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.mfAccentBorder, lineWidth: 0.5)
                        )
                }
                Text(leaf)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                headerActions
            }

            HStack(spacing: 12) {
                Text(slug)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !loading && backlinksLoaded {
                    Label("\(backlinks.count) backlink\(backlinks.count == 1 ? "" : "s")", systemImage: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Other pages in your brain that reference this one via [[wikilinks]]. Populated when you run `gbrain extract links`.")
                }
                if isDeleting {
                    ProgressView().scaleEffect(0.6)
                }
                if let err = deleteError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder private var headerActions: some View {
        if isEditing {
            HStack(spacing: 8) {
                Button("Cancel") { cancelEdit() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isSaving)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5)
                            Text("Saving…")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isSaving || editingDraft == (pageBody ?? ""))
                .buttonStyle(.borderedProminent)
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    copySlug()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy slug")

                Button {
                    startEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(pageBody == nil || loading)
                .help(pageBody == nil ? "Load the page first" : "Edit the page markdown")

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(pageBody == nil || isDeleting)
                .help("Delete this page")
            }
        }
    }

    // MARK: - backlinks

    private var backlinksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linked from")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(backlinks) { link in
                    BacklinkRow(link: link) {
                        onOpenPage?(link.fromSlug)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.mfAccentBg.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mfAccentBorder, lineWidth: 0.5)
        )
    }

    // MARK: - loaded content

    /// Rendered after `load()` resolves. The page-not-found case sits here too;
    /// the loader above keeps the pane blank until we know which one to show.
    @ViewBuilder private var loadedContent: some View {
        if let body = pageBody, !body.isEmpty {
            // Strip the YAML frontmatter header before rendering — users don't
            // need to see the raw `---\ntype: ...\n---` block when reading the
            // page. The Edit mode still shows it (so they can change it).
            MarkdownBlocksView(Self.stripFrontmatter(body), baseSize: 14, color: .primary, spacing: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView(
                "Page not found",
                systemImage: "doc.questionmark",
                description: Text("`\(slug)` couldn't be loaded from your brain.")
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - actions

    private func startEdit() {
        editingDraft = pageBody ?? ""
        saveError = nil
        isEditing = true
    }

    private func cancelEdit() {
        isEditing = false
        editingDraft = ""
        saveError = nil
    }

    private func save() async {
        let draft = editingDraft
        isSaving = true
        saveError = nil
        let (ok, stderr) = await appCore.gbrainClient.putPage(slug: slug, body: draft)
        isSaving = false
        if ok {
            pageBody = draft
            isEditing = false
        } else {
            saveError = stderr.isEmpty ? "gbrain put failed." : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func deletePage() async {
        isDeleting = true
        deleteError = nil
        let (ok, stderr) = await appCore.gbrainClient.deletePage(slug: slug)
        isDeleting = false
        if ok {
            onDelete?()
        } else {
            deleteError = stderr.isEmpty ? "Delete failed." : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - helpers

    /// Drop the leading `---\n...\n---\n` YAML frontmatter, if present, so the
    /// rendered view shows just the prose body. Edit mode still preserves the
    /// frontmatter (since the user might want to change tags / type / title).
    static func stripFrontmatter(_ raw: String) -> String {
        guard raw.hasPrefix("---\n") else { return raw }
        let after = raw.dropFirst(4)  // drop the opening "---\n"
        guard let endRange = after.range(of: "\n---\n") else { return raw }
        return String(after[endRange.upperBound...])
    }

    private var directory: String? {
        guard let i = slug.firstIndex(of: "/") else { return nil }
        return String(slug[..<i])
    }

    private var leaf: String {
        guard let i = slug.lastIndex(of: "/") else { return slug }
        return String(slug[slug.index(after: i)...])
    }

    private func load() async {
        // Drop the previous page's content immediately so the unified loader
        // takes over instead of briefly showing the old body / old backlinks
        // while the new fetch is in flight.
        pageBody = nil
        backlinks = []
        backlinksLoaded = false
        deleteError = nil
        saveError = nil
        loading = true

        let status = await appCore.gbrainClient.status(forSlug: slug)
        // Bail out if the slug changed underneath us — `.task(id: slug)` will
        // have started a fresh load() and we don't want to splat stale data
        // over its in-progress state.
        guard slug == status.slug else { return }
        pageBody = status.body
        backlinks = status.backlinks
        backlinksLoaded = status.backlinksOK
        loading = false
    }

    private func copySlug() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(slug, forType: .string)
    }
}

// MARK: - BacklinkRow

/// A single clickable inbound link. Shows the source slug + a snippet of the
/// surrounding context (when gbrain captured one) and navigates to that page.
private struct BacklinkRow: View {
    let link: GbrainBacklink
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfAccent)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(link.fromSlug)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !link.linkType.isEmpty {
                            Text(link.linkType)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    if !link.context.isEmpty {
                        Text(link.context)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.white.opacity(0.7) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
