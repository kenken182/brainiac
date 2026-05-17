//
//  PopupController.swift
//  Mindflow — owns the floating NSPanel that hosts RecordingPopupView. Positions it
//  top-right of the active screen, just below the menu bar. Non-activating so the
//  hotkey event tap keeps receiving flag-change events while the popup is visible.
//

import AppKit
import SwiftUI

@MainActor
final class PopupController {
    let state = PopupState()
    /// Callback set by AppCore — invoked when the user clicks a `brainiac://`
    /// link in the chat. Routes to dashboard deep-link navigation.
    var onChatOpenURL: ((URL) -> Void)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var chatAgent: ChatAgent?
    /// Monotonic counter that invalidates pending hide-animation completion handlers
    /// when show() races. Without it, a close-then-quick-reopen causes the deferred
    /// orderOut from the original hide() to fire after show() has already re-shown
    /// the panel — re-hiding it.
    private var hideToken: Int = 0

    /// Wire the chat agent into the popup's hosted view. Must be called before show().
    func attach(chatAgent: ChatAgent) {
        self.chatAgent = chatAgent
    }

    /// Expand the popup to chat dimensions. Call when the agent is about to take over.
    /// User can drag any edge afterwards to resize.
    func resizeForChat() {
        print("[PopupController] >>> resizeForChat() — current size: \(panel?.frame.size ?? .zero), panel exists: \(panel != nil)")
        setSize(to: CGSize(width: 380, height: 460))
    }

    /// Collapse back to the pill size (only useful if we shrink mid-flow).
    func resizeForPill() {
        print("[PopupController] >>> resizeForPill() — current size: \(panel?.frame.size ?? .zero)")
        setSize(to: CGSize(width: 360, height: 110))
    }

    func show() {
        print("[PopupController] >>> show() — panel exists: \(panel != nil), visible: \(panel?.isVisible ?? false), size: \(panel?.frame.size ?? .zero)")
        ensurePanel()
        hideTask?.cancel()
        hideToken += 1   // invalidate any pending hide completion
        // A fresh show() means we're no longer in the minimized-but-alive state.
        state.isMinimized = false
        guard let panel else { return }
        // Reposition only on first show (or after a real close); preserve the
        // user's chosen window position when they restore from minimized state.
        if !panel.isVisible {
            positionTopRight(panel: panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    /// Hide the panel without ending the chat session. The agent's state is
    /// preserved so the user can restore the popup later (via the menu bar or
    /// the hotkey) and continue the conversation where they left off.
    func minimize() {
        print("[PopupController] >>> minimize() — visible: \(panel?.isVisible ?? false)")
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        state.isMinimized = true
        hideToken += 1
        let myToken = hideToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.hideToken == myToken else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    /// Bring back a previously minimized panel without resetting agent state.
    /// If the panel was fully closed (no session), this falls through to show()
    /// behavior, which is what the menu-bar "Resume" item also wants.
    func restore() {
        print("[PopupController] >>> restore() — minimized=\(state.isMinimized)")
        ensurePanel()
        hideTask?.cancel()
        hideToken += 1
        state.isMinimized = false
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        print("[PopupController] >>> hide() — visible: \(panel?.isVisible ?? false)")
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }

        // Clear chat state synchronously so a quick close → re-open always sees
        // an empty session (the next ⌃⌥ press will hit the push-to-talk path
        // instead of toggling into the prior chat).
        chatAgent?.endCurrentSession()
        state.reset()

        hideToken += 1
        let myToken = hideToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // If show() ran after this hide started, our token is stale —
                // skip the orderOut so we don't yank a freshly re-opened panel.
                guard self.hideToken == myToken else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    /// Keep the popup visible for `delay` seconds, then hide it.
    func dismiss(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        guard let chatAgent else {
            print("[PopupController] WARNING: ensurePanel called before chatAgent attached")
            return
        }

        let view = ChatPopupView(
            state: state,
            agent: chatAgent,
            onSizeChange: { [weak self] newSize in
                Task { @MainActor in self?.resize(to: newSize) }
            },
            onClose: { [weak self] in
                Task { @MainActor in self?.hide() }
            },
            onMinimize: { [weak self] in
                Task { @MainActor in self?.minimize() }
            },
            onResize: { [weak self] delta in
                Task { @MainActor in
                    guard let panel = self?.panel else { return }
                    let current = panel.frame.size
                    let newSize = CGSize(
                        width: max(360, current.width + delta.width),
                        height: max(220, current.height + delta.height)
                    )
                    self?.resize(to: newSize)
                }
            },
            onOpenURL: { [weak self] url in
                self?.onChatOpenURL?(url)
            }
        )
        let hosting = NSHostingView(rootView: view)
        // NSHostingView defaults to translatesAutoresizingMaskIntoConstraints = true,
        // which lets the panel's setContentSize actually take effect. If we set it to
        // false, the panel auto-fits the SwiftUI fittingSize and ignores our resize requests.
        let size = hosting.fittingSize

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size == .zero ? NSSize(width: 360, height: 110) : size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.becomesKeyOnlyIfNeeded = true
        // Drag the popup from any non-interactive area. Buttons, text fields, and
        // SwiftUI gestures (like the resize grip) still consume clicks first; only
        // background pixels initiate the window drag.
        p.isMovableByWindowBackground = true
        // Force light appearance so the popup matches its designed light-mode look,
        // regardless of the user's macOS dark/light setting.
        p.appearance = NSAppearance(named: .aqua)
        // Minimum size keeps the chat usable; no upper bound — let users grow it.
        p.minSize = NSSize(width: 320, height: 320)

        p.contentView = hosting
        // Stretch the hosting view to fill the panel whenever the panel resizes.
        hosting.autoresizingMask = [.width, .height]

        self.panel = p
    }

    /// Preference-driven resize from SwiftUI. Grow-only: never shrinks the panel,
    /// because during pill→chat transitions the GeometryReader fires with the pill's
    /// small size before the chat view has rendered, which would undo resizeForChat.
    /// Use setSize(to:) when you want exact sizing that can shrink.
    private func resize(to size: CGSize) {
        guard let panel else { print("[PopupController] resize aborted: no panel"); return }
        guard size.width > 0 && size.height > 0 else { print("[PopupController] resize aborted: zero size"); return }
        let before = panel.frame.size
        let target = CGSize(width: max(size.width, before.width), height: max(size.height, before.height))
        if target == before {
            print("[PopupController] resize: \(before) — no-op (grow-only, requested \(size))")
            return
        }
        print("[PopupController] resize: \(before) → \(target) (grow-only, requested \(size))")
        applySize(target)
    }

    /// Explicit sizing — can shrink. Used by resizeForChat / resizeForPill.
    private func setSize(to size: CGSize) {
        guard let panel else { print("[PopupController] setSize aborted: no panel"); return }
        guard size.width > 0 && size.height > 0 else { print("[PopupController] setSize aborted: zero size"); return }
        print("[PopupController] setSize: \(panel.frame.size) → \(size)")
        applySize(size)
    }

    private func applySize(_ size: CGSize) {
        guard let panel else { return }
        panel.setContentSize(size)
        positionTopRight(panel: panel)
        print("[PopupController]   panel.frame after positioning: \(panel.frame)")
        if let screen = mouseScreen() ?? NSScreen.main {
            print("[PopupController]   screen.visibleFrame: \(screen.visibleFrame)")
        }
    }

    private func positionTopRight(panel: NSPanel) {
        guard let screen = mouseScreen() ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 6
        )
        panel.setFrameOrigin(origin)
    }

    private func mouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
