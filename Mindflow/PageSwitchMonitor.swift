//
//  PageSwitchMonitor.swift
//  Mindflow — detects when the user switches articles mid-session.
//
//  Polls AppContextProbe every ~1.5s while running. Filters out self-foreground
//  (when the chat popup itself is frontmost — we want the article URL, not
//  Mindflow's bundle). Emits onURLChange with a ~1s debounce so we don't thrash
//  on rapid tab clicks. Anchor/query-only changes are ignored.
//
//  This is the lighter cousin of the AX-based monitor described in the spec.
//  AppleScript-via-AppContextProbe works on Chrome out of the box; Safari/Arc
//  support can be added later by extending AppContextProbe.
//

import AppKit
import Foundation

@MainActor
final class PageSwitchMonitor {
    /// Called when the URL changes (after debounce). New URL may be `nil` when
    /// the user lands on an app with no extractable URL.
    var onURLChange: ((String?) -> Void)?

    private var timer: Timer?
    private var lastURL: String?
    private var pendingURL: String?
    private var pendingSince: Date?
    private let pollInterval: TimeInterval = 1.5
    private let debounce: TimeInterval = 1.0
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    func start(initialURL: String?) {
        stop()
        lastURL = initialURL
        pendingURL = nil
        pendingSince = nil
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        // Allow firing during scroll / drag.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // If the popup is frontmost we ignore the read — Mindflow's own bundle
        // has no URL we care about.
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier == ownBundleID {
            return
        }
        let (_, url) = AppContextProbe.current()
        let normalized = url.map { Self.stripAnchorAndQuery($0) }
        let lastNorm = lastURL.map { Self.stripAnchorAndQuery($0) }
        guard normalized != lastNorm else {
            // No change — clear any pending state.
            pendingURL = nil
            pendingSince = nil
            return
        }

        // First sighting of a new URL — start debounce window.
        if pendingURL != url {
            pendingURL = url
            pendingSince = Date()
            return
        }
        // Still pending — check if debounce window elapsed.
        if let since = pendingSince, Date().timeIntervalSince(since) >= debounce {
            lastURL = url
            pendingURL = nil
            pendingSince = nil
            onURLChange?(url)
        }
    }

    /// Strip URL fragment + query so that scrolling to an anchor or changing
    /// only a query parameter doesn't trigger a re-fetch.
    private static func stripAnchorAndQuery(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        var c = components
        c.fragment = nil
        c.query = nil
        return c.string ?? url
    }
}
