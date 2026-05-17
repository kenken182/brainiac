//
//  PopupState.swift
//  Mindflow — observable state for the top-right recording popup.
//

import Foundation
import Observation

enum PopupPhase: Equatable {
    case hidden
    case listening
    case processing(stage: String)
    case saved(path: String, conceptCount: Int)
    case failed(message: String)
}

@MainActor
@Observable
final class PopupState {
    var phase: PopupPhase = .hidden
    var transcript: String = ""
    /// True while the user has minimized the popup but the chat session is still
    /// alive. The MenuBarExtra reads this to surface a "Resume chat" item, and
    /// the popup controller skips endCurrentSession on minimize.
    var isMinimized: Bool = false

    func reset() {
        phase = .hidden
        transcript = ""
        isMinimized = false
    }
}
