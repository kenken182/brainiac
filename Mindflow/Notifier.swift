//
//  Notifier.swift
//  Mindflow — system notification + audible chime when a capture is saved.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class Notifier {
    private var authorized = false

    func requestAuthorizationIfNeeded() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
            self.authorized = granted
        } catch {
            self.authorized = false
        }
    }

    func notify(_ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Mindflow"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)

        // Audible cue that cuts through AirPods even if notifications are muted.
        NSSound(named: "Glass")?.play()
    }
}
