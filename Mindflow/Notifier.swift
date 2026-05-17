//
//  Notifier.swift
//  Mindflow — system notification + audible chime when a capture is saved.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user taps a topic-update notification. Argument is the
    /// topic slug encoded in the notification's userInfo. AppCore wires this
    /// to its deep-link handler.
    var onTopicTap: ((String) -> Void)?

    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

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

    /// Fire a plain notification. No tap action.
    func notify(_ message: String) async {
        await postNotification(body: message, userInfo: [:])
    }

    /// Fire a topic-update notification. Clicking it routes to AppCore.openLearningLink
    /// via the onTopicTap callback.
    func notifyTopicUpdated(topicSlug: String, body: String) async {
        await postNotification(body: body, userInfo: ["topic_slug": topicSlug])
    }

    private func postNotification(body: String, userInfo: [String: Any]) async {
        let content = UNMutableNotificationContent()
        content.title = "Brainiac"
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
        NSSound(named: "Glass")?.play()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Display the banner even when the app is in the foreground — without
    /// this, our own notifications get suppressed while the dashboard is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let slug = userInfo["topic_slug"] as? String
        Task { @MainActor [weak self] in
            if let slug, !slug.isEmpty {
                self?.onTopicTap?(slug)
            }
            completionHandler()
        }
    }
}
