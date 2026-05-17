//
//  MenuBarIcon.swift
//  Mindflow — gradient "M" icon shown in the macOS menubar via MenuBarExtra.
//  Static by design: MenuBarExtra pushes its label image to the NSStatusBarButton
//  on every SwiftUI body update via setImage, which triggers cell-size recompute.
//  A TimelineView-driven pulse here hangs the main thread at 30fps. The glow
//  toggles on/off when the popup is in .listening or .processing instead.
//

import SwiftUI

struct MindflowMenuBarIcon: View {
    let state: PopupState

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.5))
                    .blur(radius: 6)
                    .frame(width: 24, height: 24)
            }

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 1.00, green: 0.48, blue: 0.35),
                            Color(red: 1.00, green: 0.72, blue: 0.30),
                            Color(red: 0.35, green: 0.61, blue: 0.83),
                            Color(red: 0.42, green: 0.30, blue: 0.61),
                            Color(red: 1.00, green: 0.48, blue: 0.35),
                        ]),
                        center: .center,
                        angle: .degrees(180)
                    )
                )
                .frame(width: 18, height: 18)
                .overlay(
                    Text("M")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: isActive ? Color.orange.opacity(0.6) : .clear, radius: isActive ? 4 : 0)
        }
        .frame(width: 26, height: 22)
    }

    private var isActive: Bool {
        switch state.phase {
        case .listening, .processing: return true
        default: return false
        }
    }
}
