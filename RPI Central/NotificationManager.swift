//
//  NotificationManager.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/3/25.
//

import Foundation
import UserNotifications

enum NotificationManager {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, err in
            #if DEBUG
            print("🔔 Notifications permission granted:", granted, "err:", err as Any)
            #endif
        }
    }

    static func clearScheduledNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

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

    private static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }
}
