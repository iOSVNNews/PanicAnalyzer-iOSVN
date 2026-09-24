//  PartsNotifier.swift
//  iOS notification when a scan finds a replaced or unverified part, also
//  while the app is open (the scan usually runs in the foreground).

import UserNotifications

final class PartsNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = PartsNotifier()
    private static let identifier = "panic.parts.changed"

    func post(title: String, body: String) {
        guard !title.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
