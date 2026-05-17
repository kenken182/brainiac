//
//  MindflowApp.swift
//  Mindflow — app entry point. Menubar-resident (NSApplicationActivationPolicy.accessory).
//  Dashboard window opens from the MenuBarExtra "Open Mindflow" item.
//

import AppKit
import SwiftUI

@main
struct MindflowApp: App {
    @State private var appCore = AppCore()

    var body: some Scene {
        Window("Mindflow", id: "dashboard") {
            DashboardView()
                .environment(appCore)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.light)
        }

        MenuBarExtra {
            MenuBarMenuContent()
        } label: {
            MindflowMenuBarIcon(state: appCore.popup.state)
                .task { appCore.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Mindflow Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Divider()

        Text("Hold ⌃⌥ to capture a memory")

        Divider()

        Button("Quit Mindflow") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
