//
//  DashboardView.swift
//  Mindflow — the homepage. List of every captured chat session on the left
//  (grouped by day), detail pane on the right showing the screenshot + voice
//  note + conversation + what was added to your brain.
//
//  The sidebar doubles as a brain searcher: typing in the search field swaps
//  the memory list for live results from `gbrain search`, and picking one shows
//  the page's raw markdown in the detail pane.
//

import SwiftUI

/// Unified selection for the sidebar — captured memory, a gbrain page by slug
/// (raw markdown view), or a concept topic (rendered TopicArticleView).
enum DashboardSelection: Hashable {
    case memory(MemoryRecord.ID)
    case page(String)
    case topic(String)
    case reference(String)
}

struct DashboardView: View {
    @Environment(AppCore.self) private var appCore
    @State private var topics: [GbrainListEntry] = []
    @State private var topicsLoading: Bool = false

    /// Binding that bridges SwiftUI's List `selection:` (which needs a Binding)
    /// to AppCore's owned `dashboardSelection`. Defined as a computed property
    /// so helper view methods can use it (the previous in-body `let` wasn't
    /// visible from outside `body`).
    private var selectionBinding: Binding<DashboardSelection?> {
        Binding(
            get: { appCore.dashboardSelection },
            set: { appCore.dashboardSelection = $0 }
        )
    }

    var body: some View {
        @Bindable var search = appCore.gbrainSearch

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 500)
                .searchable(
                    text: $search.query,
                    placement: .sidebar,
                    prompt: "Search your brain"
                )
                .onChange(of: search.query) { _, _ in search.queryDidChange() }
        } detail: {
            detail
        }
        .navigationTitle("Brainiac")
        .task { await loadTopics() }
    }

    private func loadTopics() async {
        topicsLoading = true
        topics = await appCore.gbrainClient.listPages(prefix: "concepts/", limit: 200)
        topicsLoading = false
    }

    // MARK: - sidebar

    @ViewBuilder private var sidebar: some View {
        let search = appCore.gbrainSearch
        if !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchList(search)
        } else if appCore.memoryStore.memories.isEmpty && topics.isEmpty && !topicsLoading {
            emptyState
        } else {
            libraryAndMemoryList
        }
    }

    private var libraryAndMemoryList: some View {
        List(selection: selectionBinding) {
            if !topics.isEmpty || topicsLoading {
                Section {
                    if topicsLoading && topics.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.5)
                            Text("Loading library…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(topics) { topic in
                            TopicRow(entry: topic)
                                .tag(DashboardSelection.topic(topic.leaf))
                        }
                    }
                } header: {
                    Text("Library")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(memoryGroups) { group in
                Section {
                    ForEach(group.memories) { memory in
                        MemoryRow(memory: memory)
                            .tag(DashboardSelection.memory(memory.id))
                    }
                } header: {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func searchList(_ search: GbrainSearch) -> some View {
        if search.isSearching && search.results.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Searching your brain…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.results.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches")
                    .font(.headline)
                Text("Try a different term — gbrain uses keyword search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selectionBinding) {
                ForEach(resultGroups(search.results)) { group in
                    Section {
                        ForEach(group.results) { result in
                            GbrainResultRow(result: result)
                                .tag(DashboardSelection.page(result.slug))
                        }
                    } header: {
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No memories yet")
                    .font(.headline)
                Text("Hold ⌃⌥ to capture your first thought")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - detail

    @ViewBuilder private var detail: some View {
        switch appCore.dashboardSelection {
        case .memory(let id):
            if let memory = appCore.memoryStore.memories.first(where: { $0.id == id }) {
                MemoryDetail(memory: memory)
            } else {
                detailPlaceholder
            }
        case .page(let slug):
            GbrainPageView(
                slug: slug,
                onDelete: {
                    appCore.dashboardSelection = nil
                    appCore.gbrainSearch.queryDidChange()
                    Task { await loadTopics() }
                },
                onOpenPage: { newSlug in
                    appCore.dashboardSelection = .page(newSlug)
                }
            )
        case .topic(let slug):
            TopicArticleView(
                slug: slug,
                onOpenTopic: { newSlug in
                    appCore.dashboardSelection = .topic(newSlug)
                },
                onOpenReference: { refSlug in
                    appCore.dashboardSelection = .reference(refSlug)
                }
            )
        case .reference(let slug):
            ReferenceDetailView(slug: slug)
        case .none:
            detailPlaceholder
        }
    }

    @ViewBuilder private var detailPlaceholder: some View {
        if appCore.memoryStore.memories.isEmpty {
            ContentUnavailableView(
                "Capture a memory",
                systemImage: "waveform.badge.mic",
                description: Text("Hold ⌃⌥ anywhere on your Mac, say a thought about what you're looking at, release.")
            )
        } else if !appCore.gbrainSearch.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Pick a page",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a search result to view its markdown.")
            )
        } else {
            ContentUnavailableView(
                "Select a memory",
                systemImage: "doc.richtext",
                description: Text("Pick a memory on the left to see what was added to your brain.")
            )
        }
    }

    // MARK: - groupings

    private var memoryGroups: [MemoryGroup] {
        MemoryGroup.group(appCore.memoryStore.memories)
    }

    /// Group search results by their slug "directory" prefix (e.g. `media/`,
    /// `concepts/`). Pages with no slash collapse into a single "Pages" group.
    private func resultGroups(_ results: [GbrainSearchResult]) -> [ResultGroup] {
        // Preserve the score-ordered position of each directory's first hit
        // so the most relevant area surfaces at the top of the sidebar.
        var order: [String] = []
        var buckets: [String: [GbrainSearchResult]] = [:]
        for r in results {
            let key = r.directory ?? "Pages"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(r)
        }
        return order.map { key in
            ResultGroup(id: key, title: key, results: buckets[key] ?? [])
        }
    }
}

struct ResultGroup: Identifiable {
    let id: String
    let title: String
    let results: [GbrainSearchResult]
}

struct TopicRow: View {
    let entry: GbrainListEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "book.pages")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfAccent)
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Text(entry.updated)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        // Prefer the title from `gbrain list` if it's non-empty; fall back to
        // a titleized slug leaf otherwise.
        if !entry.title.isEmpty && entry.title != entry.slug {
            return entry.title
        }
        return entry.leaf
            .components(separatedBy: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

struct MemoryGroup: Identifiable {
    let id: String
    let title: String
    let memories: [MemoryRecord]

    static func group(_ memories: [MemoryRecord]) -> [MemoryGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [MemoryRecord] = []
        var yesterday: [MemoryRecord] = []
        var thisWeek: [MemoryRecord] = []
        var earlier: [MemoryRecord] = []

        for m in memories {
            if calendar.isDateInToday(m.capturedAt) {
                today.append(m)
            } else if calendar.isDateInYesterday(m.capturedAt) {
                yesterday.append(m)
            } else if let days = calendar.dateComponents([.day], from: m.capturedAt, to: now).day, days < 7 {
                thisWeek.append(m)
            } else {
                earlier.append(m)
            }
        }

        var groups: [MemoryGroup] = []
        if !today.isEmpty { groups.append(MemoryGroup(id: "today", title: "Today", memories: today)) }
        if !yesterday.isEmpty { groups.append(MemoryGroup(id: "yesterday", title: "Yesterday", memories: yesterday)) }
        if !thisWeek.isEmpty { groups.append(MemoryGroup(id: "week", title: "Earlier this week", memories: thisWeek)) }
        if !earlier.isEmpty { groups.append(MemoryGroup(id: "earlier", title: "Earlier", memories: earlier)) }
        return groups
    }
}

extension Color {
    static let mfAccent = Color(red: 0.761, green: 0.329, blue: 0.039)       // #c2540a
    static let mfAccentBg = Color(red: 0.992, green: 0.965, blue: 0.933)     // #fdf6ee
    static let mfAccentBorder = Color(red: 0.945, green: 0.831, blue: 0.729) // #f1d4ba
}
