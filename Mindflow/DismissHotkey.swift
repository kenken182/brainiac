//
//  DismissHotkey.swift
//  Mindflow — global ⌥⎋ keypress listener that hides the recording popup.
//
//  Uses NSEvent.addGlobal/LocalMonitorForEvents (no event tap needed — no extra TCC
//  permission beyond what HotkeyMonitor already requires). Fires only when option is
//  the lone modifier; ignores ⌃⌥⎋ (which the user might hit while holding the record
//  chord) so we don't close mid-recording.
//

import AppKit
import Foundation

@MainActor
final class DismissHotkey {
    var onDismiss: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    nonisolated private static let escapeKeyCode: UInt16 = 53
    nonisolated private static let relevantMods: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                print("[DismissHotkey] GLOBAL ESC: rawMods=\(event.modifierFlags.rawValue) opt=\(event.modifierFlags.contains(.option)) ctrl=\(event.modifierFlags.contains(.control)) cmd=\(event.modifierFlags.contains(.command)) shift=\(event.modifierFlags.contains(.shift))")
            }
            Self.dispatch(event, to: self)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                print("[DismissHotkey] LOCAL ESC: rawMods=\(event.modifierFlags.rawValue) opt=\(event.modifierFlags.contains(.option)) ctrl=\(event.modifierFlags.contains(.control)) cmd=\(event.modifierFlags.contains(.command)) shift=\(event.modifierFlags.contains(.shift))")
            }
            Self.dispatch(event, to: self)
            return event
        }
        print("[DismissHotkey] monitors installed — global=\(globalMonitor != nil), local=\(localMonitor != nil)")
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private nonisolated static func dispatch(_ event: NSEvent, to target: DismissHotkey?) {
        guard event.keyCode == escapeKeyCode else { return }
        let masked = event.modifierFlags.intersection(relevantMods)
        print("[DismissHotkey] dispatch — masked=\(masked.rawValue) expectedOption=\(NSEvent.ModifierFlags.option.rawValue) match=\(masked == .option)")
        guard masked == .option else { return }
        Task { @MainActor in
            print("[DismissHotkey] firing onDismiss")
            target?.onDismiss?()
        }
    }
}
