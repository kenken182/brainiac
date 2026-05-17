//
//  GbrainSearch.swift
//  Mindflow — debounced search state for the dashboard sidebar. Owns the live
//  query string, last results, and the loading flag. Cancels in-flight queries
//  whenever the query changes so we never race stale results into the UI.
//

import Foundation
import Observation

@MainActor
@Observable
final class GbrainSearch {
    var query: String = ""
    private(set) var results: [GbrainSearchResult] = []
    private(set) var isSearching: Bool = false

    private let client: GbrainClient
    private var task: Task<Void, Never>?

    /// Debounce window — keystrokes within this window collapse to one call.
    private let debounceNanos: UInt64 = 220_000_000   // 220ms

    init(client: GbrainClient) {
        self.client = client
    }

    /// Called from the view's `.onChange(of: query)`. Cancels any pending task
    /// and either clears results (empty query) or schedules a debounced fetch.
    func queryDidChange() {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            guard !Task.isCancelled, let self else { return }
            let captured = self.query.trimmingCharacters(in: .whitespaces)
            // If the user kept typing, an even-newer task will supersede us.
            guard captured == trimmed else { return }
            let fetched = await self.client.search(query: trimmed, limit: 20)
            guard !Task.isCancelled else { return }
            self.results = fetched
            self.isSearching = false
        }
    }

    func clear() {
        task?.cancel()
        query = ""
        results = []
        isSearching = false
    }
}
