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
    private static let legacyClassNotificationMigrationKey = "notifications.classIdentifiersMigrated.v1"
    private static let managedNotificationQueue = DispatchQueue(label: "rpiCentral.managedNotifications")
    private static var managedNotificationRevision = 0
    private static let maxManagedPendingNotifications = 60

    private struct DatedNotificationRequest {
        let deliveryDate: Date
        let request: UNNotificationRequest
    }

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

    static func clearManagedCalendarNotifications() {
        let center = UNUserNotificationCenter.current()

        managedNotificationQueue.async {
            managedNotificationRevision += 1
            let revision = managedNotificationRevision

            center.getPendingNotificationRequests { requests in
                managedNotificationQueue.async {
                    guard revision == managedNotificationRevision else { return }
                    let identifiers = managedCalendarIdentifiersToRemove(from: requests)
                    guard !identifiers.isEmpty else { return }
                    center.removePendingNotificationRequests(withIdentifiers: identifiers)
                }
            }
        }
    }

    static func replaceManagedCalendarNotifications(
        classEvents: [ClassEvent],
        minutesBeforeClass: Int,
        tasks: [CourseTask],
        lmsEvents: [StoredPersonalEvent],
        now: Date = Date()
    ) {
        var desiredRequests = classEvents.compactMap {
            classNotificationRequest(for: $0, minutesBefore: minutesBeforeClass, now: now)
        }

        desiredRequests.append(contentsOf: tasks.flatMap { task in
            task.reminderOffsetsMinutes.compactMap {
                taskNotificationRequest(task: task, minutesBefore: $0, now: now)
            }
        })

        desiredRequests.append(contentsOf: lmsEvents.flatMap { event in
            [1440, 60].compactMap {
                lmsNotificationRequest(event: event, minutesBefore: $0, now: now)
            }
        })

        let requestsToSchedule = Array(
            desiredRequests
                .sorted { $0.deliveryDate < $1.deliveryDate }
                .prefix(maxManagedPendingNotifications)
        )
        let center = UNUserNotificationCenter.current()

        managedNotificationQueue.async {
            managedNotificationRevision += 1
            let revision = managedNotificationRevision

            center.getPendingNotificationRequests { requests in
                managedNotificationQueue.async {
                    guard revision == managedNotificationRevision else { return }

                    let identifiers = managedCalendarIdentifiersToRemove(from: requests)
                    if !identifiers.isEmpty {
                        center.removePendingNotificationRequests(withIdentifiers: identifiers)
                    }

                    for datedRequest in requestsToSchedule {
                        center.add(datedRequest.request)
                    }

                    #if DEBUG
                    print(
                        "🔔 Replaced managed reminders:",
                        requestsToSchedule.count,
                        "of",
                        desiredRequests.count,
                        "eligible"
                    )
                    #endif
                }
            }
        }
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

    static func clearAllTaskNotifications() {
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("task.") }

            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            #if DEBUG
            print("🧹 Cleared all task notifications:", ids.count)
            #endif
        }
    }

    static func clearLMSNotifications(sourceID: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = lmsNotificationPrefix(sourceID: sourceID)

        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }

            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
                #if DEBUG
                print("🧹 Cleared \(ids.count) LMS notifications for", sourceID)
                #endif
            }
        }
    }

    static func clearAllLMSNotifications() {
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("lms.") }

            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            #if DEBUG
            print("🧹 Cleared all LMS notifications:", ids.count)
            #endif
        }
    }

    // MARK: - Class reminder notifications

    static func scheduleNotification(for event: ClassEvent, minutesBefore: Int) {
        guard let datedRequest = classNotificationRequest(
            for: event,
            minutesBefore: minutesBefore,
            now: Date()
        ) else { return }

        UNUserNotificationCenter.current().add(datedRequest.request) { err in
            #if DEBUG
            if let err {
                print("❌ Notification schedule failed:", err)
            } else {
                print("✅ Scheduled:", event.title, "at", datedRequest.deliveryDate)
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
        guard let datedRequest = taskNotificationRequest(
            task: task,
            minutesBefore: minutesBefore,
            now: Date()
        ) else { return }

        UNUserNotificationCenter.current().add(datedRequest.request) { err in
            #if DEBUG
            if let err {
                print("❌ Task reminder failed:", err)
            } else {
                print("✅ Task reminder scheduled:", task.title, "offset", minutesBefore, "mins")
            }
            #endif
        }
    }

    static func scheduleLMSReminder(event: StoredPersonalEvent, minutesBefore: Int) {
        guard let datedRequest = lmsNotificationRequest(
            event: event,
            minutesBefore: minutesBefore,
            now: Date()
        ) else { return }

        UNUserNotificationCenter.current().add(datedRequest.request) { err in
            #if DEBUG
            if let err {
                print("❌ LMS reminder failed:", err)
            } else {
                print("✅ LMS reminder scheduled:", event.title, "offset", minutesBefore, "mins")
            }
            #endif
        }
    }

    // MARK: - Pomodoro timer notifications

    private static let pomodoroNotificationID = "pomodoro.phase"

    /// Schedules the end-of-phase alert for `date`, replacing any earlier one,
    /// so it arrives on time even while the app is in the background.
    static func schedulePomodoroNotification(at date: Date, isBreak: Bool) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        if isBreak {
            content.title = "Break finished"
            content.body = "Start your next focus session."
        } else {
            content.title = "Focus session finished"
            content.body = "Take a short break."
        }

        let request = UNNotificationRequest(
            identifier: pomodoroNotificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { err in
            #if DEBUG
            if let err {
                print("❌ Pomodoro notification failed:", err)
            }
            #endif
        }
    }

    static func cancelPomodoroNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [pomodoroNotificationID])
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

    private static func classNotificationRequest(
        for event: ClassEvent,
        minutesBefore: Int,
        now: Date
    ) -> DatedNotificationRequest? {
        guard minutesBefore >= 0, !event.isAllDay, event.kind == .classMeeting else { return nil }

        let deliveryDate = event.startDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard deliveryDate > now else { return nil }

        let content = UNMutableNotificationContent()
        let code = courseCode(fromEnrollmentID: event.enrollmentID)
        let name = event.title.replacingOccurrences(of: "★ ", with: "")
        let isExam = event.badge == .exam || event.title.hasPrefix("★")
        content.title = [isExam ? "Exam" : nil, code, name].compactMap { $0 }.joined(separator: " · ")
        let when = minutesBefore == 0
            ? "Starting now"
            : "Starts in \(durationText(minutes: minutesBefore)) at \(timeString(event.startDate))"
        content.body = event.location.isEmpty ? when : "\(when) · \(event.location)"
        content.sound = .default
        content.threadIdentifier = "classes"
        content.userInfo = ["deeplink": "rpicentral://calendar?date=\(Int(event.startDate.timeIntervalSince1970))"]

        let request = UNNotificationRequest(
            identifier: classNotificationID(for: event, minutesBefore: minutesBefore),
            content: content,
            trigger: calendarTrigger(for: deliveryDate)
        )
        return DatedNotificationRequest(deliveryDate: deliveryDate, request: request)
    }

    private static func taskNotificationRequest(
        task: CourseTask,
        minutesBefore: Int,
        now: Date
    ) -> DatedNotificationRequest? {
        guard minutesBefore >= 0 else { return nil }
        let deliveryDate = task.dueDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard deliveryDate > now else { return nil }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.sound = .default

        let kindText = task.kind.label
        let dueText = dateTimeString(task.dueDate)
        let prefix = courseCode(fromEnrollmentID: task.enrollmentID).map { "\($0) · " } ?? ""
        content.body = minutesBefore == 0
            ? "\(prefix)\(kindText) due now · \(dueText)"
            : "\(prefix)\(kindText) due in \(durationText(minutes: minutesBefore)) · \(dueText)"
        content.threadIdentifier = "tasks"
        content.userInfo = ["deeplink": "rpicentral://tasks"]

        let request = UNNotificationRequest(
            identifier: taskNotificationID(taskID: task.id, minutesBefore: minutesBefore),
            content: content,
            trigger: calendarTrigger(for: deliveryDate)
        )
        return DatedNotificationRequest(deliveryDate: deliveryDate, request: request)
    }

    private static func lmsNotificationRequest(
        event: StoredPersonalEvent,
        minutesBefore: Int,
        now: Date
    ) -> DatedNotificationRequest? {
        guard minutesBefore >= 0,
              let sourceID = normalizedValue(event.externalSourceID) else { return nil }

        let dueDate = lmsReminderDueDate(for: event)
        let deliveryDate = dueDate.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard deliveryDate > now else { return nil }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.sound = .default

        let dueText = dateTimeString(dueDate)
        content.body = minutesBefore == 0
            ? "Blackboard item due now · \(dueText)"
            : "Blackboard item due in \(durationText(minutes: minutesBefore)) · \(dueText)"
        content.threadIdentifier = "tasks"
        content.userInfo = ["deeplink": "rpicentral://calendar?date=\(Int(dueDate.timeIntervalSince1970))"]

        let request = UNNotificationRequest(
            identifier: lmsNotificationID(sourceID: sourceID, minutesBefore: minutesBefore),
            content: content,
            trigger: calendarTrigger(for: deliveryDate)
        )
        return DatedNotificationRequest(deliveryDate: deliveryDate, request: request)
    }

    private static func calendarTrigger(for deliveryDate: Date) -> UNCalendarNotificationTrigger {
        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: deliveryDate
        )
        components.timeZone = calendar.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private static func classNotificationID(for event: ClassEvent, minutesBefore: Int) -> String {
        "class.\(stableNotificationToken(from: event.interactionKey)).\(minutesBefore)m"
    }

    private static func isManagedCalendarNotificationIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("class.") || identifier.hasPrefix("task.") || identifier.hasPrefix("lms.")
    }

    private static func managedCalendarIdentifiersToRemove(
        from requests: [UNNotificationRequest]
    ) -> [String] {
        let shouldMigrateLegacyClassIDs = !UserDefaults.standard.bool(
            forKey: legacyClassNotificationMigrationKey
        )

        let identifiers = requests
            .map(\.identifier)
            .filter { identifier in
                isManagedCalendarNotificationIdentifier(identifier) ||
                    (shouldMigrateLegacyClassIDs && UUID(uuidString: identifier) != nil)
            }

        if shouldMigrateLegacyClassIDs {
            UserDefaults.standard.set(true, forKey: legacyClassNotificationMigrationKey)
        }
        return identifiers
    }

    private static func taskNotificationPrefix(taskID: UUID) -> String {
        "task.\(taskID.uuidString)."
    }

    private static func taskNotificationID(taskID: UUID, minutesBefore: Int) -> String {
        "\(taskNotificationPrefix(taskID: taskID))\(minutesBefore)m"
    }

    private static func lmsNotificationPrefix(sourceID: String) -> String {
        "lms.\(stableNotificationToken(from: sourceID))."
    }

    private static func lmsNotificationID(sourceID: String, minutesBefore: Int) -> String {
        "\(lmsNotificationPrefix(sourceID: sourceID))\(minutesBefore)m"
    }

    private static func lmsReminderDueDate(for event: StoredPersonalEvent) -> Date {
        guard event.isAllDay ?? false else { return event.startDate }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: event.startDate) ?? event.startDate
    }

    /// "CSCI 1200" from an enrollment ID like "CSCI-1200-35222".
    static func courseCode(fromEnrollmentID enrollmentID: String?) -> String? {
        guard let parts = enrollmentID?.split(separator: "-"), parts.count >= 2 else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// "10 minutes", "1 hour", "2 days", "1 week".
    static func durationText(minutes: Int) -> String {
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if minutes % 10_080 == 0 && minutes >= 10_080 { return unit(minutes / 10_080, "week") }
        if minutes >= 1440 { return unit(Int((Double(minutes) / 1440).rounded()), "day") }
        if minutes >= 60 && minutes % 60 == 0 { return unit(minutes / 60, "hour") }
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return unit(minutes, "minute")
    }

    private static func stableNotificationToken(from value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
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
