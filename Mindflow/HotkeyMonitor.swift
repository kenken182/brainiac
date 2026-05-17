//
//  HotkeyMonitor.swift
//  Mindflow — global push-to-hold hotkey: ⌃⌥ press fires onPress, release fires onRelease.
//
//  Uses NSEvent global + local monitors. Simpler and more robust than a raw CGEvent tap,
//  which macOS aggressively disables on timeout.
//

import AppKit
import Foundation

@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isChordCurrentlyPressed = false

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor handler is delivered on main; just hop the actor.
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        if globalMonitor != nil {
            print("[HotkeyMonitor] global NSEvent monitor installed")
        } else {
            print("[HotkeyMonitor] FAILED to install global monitor — likely Input Monitoring permission")
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isChordCurrentlyPressed = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let chord: NSEvent.ModifierFlags = [.control, .option]
        let isPressed = flags.isSuperset(of: chord)

        print("[HotkeyMonitor] flagsChanged: ctrl=\(flags.contains(.control) ? "Y" : "N") opt=\(flags.contains(.option) ? "Y" : "N") chord=\(isPressed ? "Y" : "N")")

        if isPressed && !isChordCurrentlyPressed {
            isChordCurrentlyPressed = true
            onPress?()
        } else if !isPressed && isChordCurrentlyPressed {
            isChordCurrentlyPressed = false
            onRelease?()
        }
    }
}
