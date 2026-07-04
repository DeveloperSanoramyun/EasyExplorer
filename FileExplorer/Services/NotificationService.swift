//
//  NotificationService.swift
//  FileExplorer
//
//  macOS Notification Center wrapper for "Copy completed", "Compression
//  finished" toasts. Only fires for operations that took longer than a
//  small threshold so trivial actions don't clutter the user's history.
//

import Foundation
import UserNotifications

enum NotificationService {

    /// Threshold below which we skip the notification entirely — copying
    /// a 4 KB text file shouldn't ping.
    static let minDuration: TimeInterval = 2.0

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// - Parameter tab: fallback target for the in-app success banner
    ///   when the system notification can't actually be shown (permission
    ///   denied, or never granted) — otherwise a completed multi-hour
    ///   transfer produced no feedback anywhere.
    @MainActor
    static func notifyOperationCompleted(
        title: String,
        body: String,
        elapsed: TimeInterval,
        tab: TabViewModel
    ) {
        guard elapsed >= minDuration else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Only .authorized/.provisional will actually show anything —
            // everything else (denied, not yet asked, ephemeral, or any
            // future status) falls back to the in-app banner so the
            // confirmation isn't silently lost.
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Task { @MainActor in
                    tab.reportSuccess("\(title) — \(body)")
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil   // deliver immediately
            )
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }
}
