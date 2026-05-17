//
//  RecordingPopupView.swift
//  Mindflow — the floating pill that appears top-right while ctrl+option is held
//  and through the save pipeline. Design follows docs/ui-mockups.html (Option A).
//
//  Visual rules:
//  - Background material stays consistent across every phase (no green-flash on save).
//  - Phase is conveyed by the pulse dot (color + animated halo) and the status text only.
//

import SwiftUI

struct RecordingPopupView: View {
    let state: PopupState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PulseDot(color: dotColor, animated: dotAnimated)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let chip = anchorChip {
                    Text(chip)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.14))
                        )
                        .foregroundStyle(Color.accentColor)
                }
            }

            if !state.transcript.isEmpty {
                Text(state.transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            if case let .saved(_, count) = state.phase, count > 0 {
                Text("\(count) concept\(count == 1 ? "" : "s") wired")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if showFooter {
                Divider().opacity(0.4)
                HStack {
                    Text(footerLeading)
                    Spacer()
                    Text("⌥⎋  close")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                )
        }
        .animation(.easeInOut(duration: 0.18), value: state.phase)
    }

    private var dotColor: Color {
        switch state.phase {
        case .listening:  return Color(red: 0.72, green: 0.27, blue: 0.42)
        case .processing: return Color(red: 0.72, green: 0.36, blue: 0.16)
        case .saved:      return Color(red: 0.18, green: 0.55, blue: 0.22)
        case .failed:     return .red
        case .hidden:     return .clear
        }
    }

    private var dotAnimated: Bool {
        switch state.phase {
        case .listening, .processing: return true
        default: return false
        }
    }

    private var statusText: String {
        switch state.phase {
        case .listening:           return "listening…"
        case .processing(let s):   return s
        case .saved:               return "saved"
        case .failed:              return "couldn't save"
        case .hidden:              return ""
        }
    }

    private var anchorChip: String? {
        if case let .saved(path, _) = state.phase {
            return path.components(separatedBy: "/").last
        }
        return nil
    }

    private var showFooter: Bool {
        switch state.phase {
        case .hidden: return false
        default:      return true
        }
    }

    private var footerLeading: String {
        switch state.phase {
        case .listening:  return "release to send"
        case .processing: return "working…"
        case .saved:      return "tap ⌃⌥ to keep talking"
        case .failed:     return "tap ⌃⌥ to retry"
        case .hidden:     return ""
        }
    }
}

private struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var halo = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .scaleEffect(halo ? 2.6 : 1)
                    .opacity(halo ? 0 : 0.55)
            }
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 11, height: 11)
        .onAppear { triggerHalo() }
        .onChange(of: animated) { _, newValue in
            if newValue { triggerHalo() } else { halo = false }
        }
    }

    private func triggerHalo() {
        guard animated else { return }
        halo = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            halo = true
        }
    }
}

#Preview("listening") {
    let s = PopupState(); s.phase = .listening
    return RecordingPopupView(state: s).padding(40).background(.gray.opacity(0.2))
}

#Preview("processing") {
    let s = PopupState(); s.phase = .processing(stage: "transcribing…")
    s.transcript = "save Sarah, she works on agentic memory at Acme, just published a paper on attention"
    return RecordingPopupView(state: s).padding(40).background(.gray.opacity(0.2))
}

#Preview("saved") {
    let s = PopupState(); s.phase = .saved(path: "people/sarah-chen", conceptCount: 3)
    s.transcript = "save Sarah, she works on agentic memory at Acme."
    return RecordingPopupView(state: s).padding(40).background(.gray.opacity(0.2))
}
