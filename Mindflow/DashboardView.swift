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

/// Unified selection for the sidebar — either a captured memory by UUID, or a
/// gbrain page by slug. Hashable so it works as a `List(selection:)` binding.
enum DashboardSelection: Hashable {
    case memory(MemoryRecord.ID)
    case page(String)
}

struct DashboardView: View {
    @Environment(AppCore.self) private var appCore
    @State private var selection: DashboardSelection?

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
    }

    // MARK: - sidebar

    @ViewBuilder private var sidebar: some View {
        let search = appCore.gbrainSearch
        if !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchList(search)
        } else if appCore.memoryStore.memories.isEmpty {
            emptyState
        } else {
            memoryList
        }
    }

    private var memoryList: some View {
        List(selection: $selection) {
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
            List(selection: $selection) {
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
        switch selection {
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
                    // Drop the selection so the detail pane reverts to the placeholder,
                    // and re-run the active search so the deleted slug stops appearing
                    // in the sidebar list.
                    selection = nil
                    appCore.gbrainSearch.queryDidChange()
                },
                onOpenPage: { newSlug in
                    selection = .page(newSlug)
                }
            )
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
