//
//  NotificationManager.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/3/25.
//

import Foundation
import UserNotifications

enum NotificationManager {

    // MARK: - Permission

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, err in
            #if DEBUG
            print("🔔 Notifications permission granted:", granted, "err:", err as Any)
            #endif
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
}
