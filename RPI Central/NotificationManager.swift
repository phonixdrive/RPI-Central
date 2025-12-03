//
//  NotificationManager.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/3/25.
//
//  NotificationManager.swift
//  RPI Central

import Foundation
import UserNotifications

enum NotificationManager {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in
            // You could handle errors here if you want
        }
    }

    static func clearScheduledNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func scheduleNotification(for event: ClassEvent, minutesBefore: Int) {
        let center = UNUserNotificationCenter.current()

        let triggerDate = event.startDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard triggerDate > Date() else { return } // don't schedule in the past

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "Class starts at \(timeString(event.startDate))"
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

        center.add(request, withCompletionHandler: nil)
    }

    private static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }
}
