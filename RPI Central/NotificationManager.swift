//
//  NotificationManager.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/3/25.
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    static let rpiCentralPushTokenDidChange = Notification.Name("rpiCentral.pushTokenDidChange")
}

enum NotificationManager {
    private static let pushInstallationIDKey = "push.installation_id_v1"
    private static let pushFCMTokenKey = "push.fcm_token_v1"
    private static let pushAPNsRegisteredKey = "push.apns_registered_v1"
    private static let activeSocialContextIDKey = "social.active_context_id_v1"

    struct SocialPushPayload {
        let alertID: String
        let type: String
        let contextID: String
        let senderID: String
    }

    static var pushTokenDidChangeNotification: Notification.Name {
        .rpiCentralPushTokenDidChange
    }

    static var pushInstallationID: String {
        if let existing = UserDefaults.standard.string(forKey: pushInstallationIDKey), !existing.isEmpty {
            return existing
        }
        let newValue = UUID().uuidString
        UserDefaults.standard.set(newValue, forKey: pushInstallationIDKey)
        return newValue
    }

    static var currentFCMToken: String? {
        normalizedValue(UserDefaults.standard.string(forKey: pushFCMTokenKey))
    }

    static var canReceiveRemotePush: Bool {
        currentFCMToken != nil && UserDefaults.standard.bool(forKey: pushAPNsRegisteredKey)
    }

    static var activeSocialContextID: String? {
        normalizedValue(UserDefaults.standard.string(forKey: activeSocialContextIDKey))
    }

    static func socialPushPayload(from userInfo: [AnyHashable: Any]) -> SocialPushPayload? {
        let alertID = normalizedValue(userInfo["socialAlertId"] as? String) ?? normalizedValue(userInfo["alertID"] as? String) ?? ""
        let type = normalizedValue(userInfo["socialType"] as? String) ?? normalizedValue(userInfo["type"] as? String) ?? ""
        let contextID = normalizedValue(userInfo["socialContextID"] as? String) ?? normalizedValue(userInfo["contextID"] as? String) ?? ""
        let senderID = normalizedValue(userInfo["senderID"] as? String) ?? ""

        guard !type.isEmpty else { return nil }
        return SocialPushPayload(
            alertID: alertID,
            type: type,
            contextID: contextID,
            senderID: senderID
        )
    }

    static func shouldSuppressForegroundSocialPush(userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = socialPushPayload(from: userInfo) else { return false }
        return payload.type == "groupMessage" && payload.contextID == activeSocialContextID
    }

    static func updateFCMToken(_ token: String?) {
        let normalizedToken = normalizedValue(token)
        let existingToken = currentFCMToken

        if let normalizedToken {
            UserDefaults.standard.set(normalizedToken, forKey: pushFCMTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pushFCMTokenKey)
        }

        guard existingToken != normalizedToken else { return }
        NotificationCenter.default.post(name: pushTokenDidChangeNotification, object: nil)
    }

    static func setActiveSocialContextID(_ contextID: String?) {
        if let contextID = normalizedValue(contextID) {
            UserDefaults.standard.set(contextID, forKey: activeSocialContextIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeSocialContextIDKey)
        }
    }

    static func setDidRegisterForRemoteNotifications(_ didRegister: Bool) {
        let existing = UserDefaults.standard.bool(forKey: pushAPNsRegisteredKey)
        UserDefaults.standard.set(didRegister, forKey: pushAPNsRegisteredKey)
        guard existing != didRegister else { return }
        NotificationCenter.default.post(name: pushTokenDidChangeNotification, object: nil)
    }

    static func registerForRemoteNotificationsIfAuthorized() {
#if canImport(UIKit)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let canRegister: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                canRegister = true
            default:
                canRegister = false
            }
            guard canRegister else { return }
            DispatchQueue.main.async {
                #if DEBUG
                print("📲 Calling registerForRemoteNotifications()")
                #endif
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
#endif
    }

    // MARK: - Permission

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, err in
            #if DEBUG
            print("🔔 Notifications permission granted:", granted, "err:", err as Any)
            #endif
            guard granted else { return }
            registerForRemoteNotificationsIfAuthorized()
        }
    }

    // MARK: - Clear

    static func clearScheduledNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Clears only notifications scheduled for a specific CourseTask
    static func clearTaskNotifications(taskID: UUID) {
        let center = UNUserNotificationCenter.current()
        let prefix = taskNotificationPrefix(taskID: taskID)

        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }

            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
                #if DEBUG
                print("🧹 Cleared \(ids.count) task notifications for", taskID.uuidString)
                #endif
            }
        }
    }

    // MARK: - Class reminder notifications

    static func scheduleNotification(for event: ClassEvent, minutesBefore: Int) {
        guard minutesBefore >= 0 else { return }
        // Don’t schedule for academic all-day events / holidays / breaks.
        guard !event.isAllDay else { return }

        let center = UNUserNotificationCenter.current()

        let triggerDate = event.startDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard triggerDate > Date() else { return } // don't schedule in the past

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "Starts at \(timeString(event.startDate))"
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: trigger
        )

        center.add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Notification schedule failed:", err)
            } else {
                print("✅ Scheduled:", event.title, "at", triggerDate)
            }
            #endif
        }
    }

    /// ✅ Debug button: schedules a notification 5 seconds from now.
    static func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "RPI Central Test"
        content.body = "If you see this, notifications work."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)

        let request = UNNotificationRequest(
            identifier: "rpi_central_test_notification",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Test notification failed:", err)
            } else {
                print("✅ Test notification scheduled (5s)")
            }
            #endif
        }
    }

    // MARK: - Task reminders (Assignments / custom items)

    /// Schedules a reminder for a CourseTask `minutesBefore` due date.
    /// Example offsets: 10080 (7d), 1440 (1d), 60 (1h)
    static func scheduleTaskReminder(task: CourseTask, minutesBefore: Int) {
        let center = UNUserNotificationCenter.current()

        let triggerDate = task.dueDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard triggerDate > Date() else { return } // don't schedule in the past

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.sound = .default

        let kindText = task.kind.label
        let dueText = dateTimeString(task.dueDate)

        if minutesBefore >= 1440 {
            let days = minutesBefore / 1440
            content.body = "\(kindText) due in \(days)d • \(dueText)"
        } else if minutesBefore >= 60 {
            let hrs = minutesBefore / 60
            content.body = "\(kindText) due in \(hrs)h • \(dueText)"
        } else {
            content.body = "\(kindText) due soon • \(dueText)"
        }

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        // Stable identifier so we can delete/update them later
        let id = taskNotificationID(taskID: task.id, minutesBefore: minutesBefore)

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: trigger
        )

        center.add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Task reminder failed:", err)
            } else {
                print("✅ Task reminder scheduled:", task.title, "offset", minutesBefore, "mins")
            }
            #endif
        }
    }

    // MARK: - Pomodoro timer notifications

    /// Schedules an immediate "timer finished" notification.
    static func scheduleTimerFinishedNotification(isBreak: Bool) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        if isBreak {
            content.title = "Break finished"
            content.body = "Start your next focus session."
        } else {
            content.title = "Focus session finished"
            content.body = "Take a short break."
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: "pomodoro.finished.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Pomodoro notification failed:", err)
            } else {
                print("✅ Pomodoro notification scheduled")
            }
            #endif
        }
    }

    // MARK: - Social notifications

    static func scheduleSocialNotification(
        identifier: String,
        title: String,
        body: String,
        deliverAt: Date? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request: UNNotificationRequest
        if let deliverAt, deliverAt > Date() {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: deliverAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        } else {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }

        UNUserNotificationCenter.current().add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Social notification failed:", err)
            } else {
                print("✅ Social notification scheduled:", identifier)
            }
            #endif
        }
    }

    // MARK: - Helpers

    private static func taskNotificationPrefix(taskID: UUID) -> String {
        "task.\(taskID.uuidString)."
    }

    private static func taskNotificationID(taskID: UUID, minutesBefore: Int) -> String {
        "\(taskNotificationPrefix(taskID: taskID))\(minutesBefore)m"
    }

    private static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
