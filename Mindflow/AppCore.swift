//
//  AppCore.swift
//  Mindflow — top-level app state: owns the stores + chat agent + saver + hotkey
//  monitors. The dashboard reads MemoryStore via this; the ChatAgent appends
//  MemoryRecords on session-end (popup hide). The menubar icon lives in the
//  MenuBarExtra scene in MindflowApp.swift, not here.
//
//  API keys are read from the environment. In Xcode: Edit Scheme > Run > Arguments >
//  Environment Variables. Add ANTHROPIC_API_KEY and DEEPGRAM_API_KEY there.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppCore {
    let memoryStore: MemoryStore
    let screenshotStore: ScreenshotStore
    let gbrainClient: GbrainClient
    let gbrainSearch: GbrainSearch
    let chatAgent: ChatAgent
    let popup: PopupController

    /// Single source of truth for the dashboard's currently-selected row.
    /// Mutated by deep-link navigation (`openLearningLink`) and by the
    /// DashboardView itself (two-way binding).
    var dashboardSelection: DashboardSelection? = nil

    private let saver: MindflowSaver
    private let hotkey: HotkeyMonitor
    private let dismissHotkey: DismissHotkey
    private let notifier: Notifier
    private var started = false

    init() {
        let env = ProcessInfo.processInfo.environment
        let anthropicKey = env["ANTHROPIC_API_KEY"] ?? ""
        let deepgramKey = env["DEEPGRAM_API_KEY"] ?? ""

        if anthropicKey.isEmpty {
            print("⚠️ ANTHROPIC_API_KEY not set in environment — add it to the Xcode scheme.")
        }
        if deepgramKey.isEmpty {
            print("⚠️ DEEPGRAM_API_KEY not set in environment — add it to the Xcode scheme.")
        }

        let memoryStore = MemoryStore()
        self.memoryStore = memoryStore

        let screenshotStore = ScreenshotStore()
        self.screenshotStore = screenshotStore

        let gbrainClient = GbrainClient()
        self.gbrainClient = gbrainClient

        self.gbrainSearch = GbrainSearch(client: gbrainClient)

        let notifier = Notifier()
        self.notifier = notifier

        let popup = PopupController()
        self.popup = popup

        let chatAgent = ChatAgent(
            anthropicApiKey: anthropicKey,
            memoryStore: memoryStore,
            notifier: notifier
        )
        self.chatAgent = chatAgent

        let saver = MindflowSaver(
            deepgramApiKey: deepgramKey,
            anthropicApiKey: anthropicKey,
            notifier: notifier,
            popup: popup,
            chatAgent: chatAgent,
            screenshotStore: screenshotStore
        )
        self.saver = saver

        let hotkey = HotkeyMonitor()
        // Hybrid hotkey semantics: push-to-talk for the very first turn (so a
        // brief tap doesn't accidentally fire an empty capture), toggle after
        // the chat exists (so longer follow-ups don't need a held chord).
        hotkey.onPress = { [weak saver] in saver?.handleHotkeyPress() }
        hotkey.onRelease = { [weak saver] in saver?.handleHotkeyRelease() }
        self.hotkey = hotkey

        let dismissHotkey = DismissHotkey()
        dismissHotkey.onDismiss = { [weak popup] in popup?.hide() }
        self.dismissHotkey = dismissHotkey

        // Inject the agent reference into the popup. PopupController uses it to
        // (a) render ChatPopupView and (b) call endCurrentSession on hide.
        popup.attach(chatAgent: chatAgent)
        // Route brainiac:// link clicks from chat into dashboard navigation.
        popup.onChatOpenURL = { [weak self] url in
            self?.openLearningLink(url)
        }
        // Topic-updated notifications: tap opens the topic page.
        notifier.onTopicTap = { [weak self] topicSlug in
            self?.dashboardSelection = .topic(topicSlug)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Handle a `brainiac://` deep-link by setting the dashboard selection and
    /// bringing the dashboard window forward. Supported hosts:
    ///   - `brainiac://topic/<slug>`     → TopicArticleView for that concept
    ///   - `brainiac://reference/<slug>` → raw markdown view for media/<slug>
    func openLearningLink(_ url: URL) {
        guard url.scheme == "brainiac" else { return }
        let host = url.host ?? ""
        let tail = url.pathComponents.dropFirst().joined(separator: "/")
        guard !tail.isEmpty else { return }
        switch host {
        case "topic":
            dashboardSelection = .topic(tail)
        case "reference":
            dashboardSelection = .reference(tail)
        default:
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !started else { return }
        started = true
        hotkey.start()
        dismissHotkey.start()
        Task { [notifier] in
            await notifier.requestAuthorizationIfNeeded()
            await notifier.notify("Brainiac is running. Hold ctrl+option to start; tap to keep talking.")
        }
    }
}
