//
//  ChatPopupView.swift
//  Mindflow — the floating panel's content. Shows the pill in listening/processing
//  states; expands into the chat UI once the agent has any messages.
//

import AppKit
import SwiftUI

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Backing view that opts into AppKit's window-drag-by-background behavior.
/// SwiftUI's hosting layer normally swallows mouse events, blocking the panel's
/// `isMovableByWindowBackground = true` setting; placing this as a `.background`
/// guarantees that empty regions of the popup drag the window. Interactive
/// SwiftUI elements (buttons, text fields, the resize grip) sit on top and
/// consume their clicks first.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MovableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MovableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

struct ChatPopupView: View {
    let state: PopupState
    @Bindable var agent: ChatAgent
    let onSizeChange: (CGSize) -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onResize: (CGSize) -> Void
    var onOpenURL: ((URL) -> Void)? = nil

    var body: some View {
        let _ = print("[ChatPopupView] body() — messages.count=\(agent.messages.count), mode=\(agent.messages.isEmpty ? "PILL" : "CHAT")")
        return Group {
            if agent.messages.isEmpty {
                RecordingPopupView(state: state)
                    .onAppear { print("[ChatPopupView] >>> PILL branch onAppear") }
            } else {
                ChatView(agent: agent, onClose: onClose, onMinimize: onMinimize, onResize: onResize, onOpenURL: onOpenURL)
                    .onAppear { print("[ChatPopupView] >>> CHAT branch onAppear (messages.count=\(agent.messages.count))") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
                    .padding(6)
            }
        }
        .preferredColorScheme(.light)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: geo.size)
                    .onAppear {
                        print("[ChatPopupView] geometry on appear: \(geo.size), chatMode=\(!agent.messages.isEmpty)")
                    }
            }
        )
        // Furthest-back layer: any click on a region not consumed by SwiftUI
        // controls (Buttons, TextFields, the resize grip's DragGesture) hits
        // this NSView and drags the panel.
        .background(WindowDragArea())
        .onPreferenceChange(SizePreferenceKey.self) { newSize in
            // Only auto-resize the panel while the popup is in pill mode (no
            // chat messages yet). Once chat takes over, the user owns sizing
            // via the panel's resize handle.
            if agent.messages.isEmpty {
                onSizeChange(newSize)
            }
        }
        .onChange(of: agent.messages.count) { old, new in
            print("[ChatPopupView] messages.count changed: \(old) → \(new)")
        }
        .animation(.easeInOut(duration: 0.22), value: agent.messages.isEmpty)
    }
}
