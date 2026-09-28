//
//  FriendPresence.swift
//  RPI Central
//
//  Combines a friend's shared location with their shared schedule into one
//  campus-aware status: "In class · Data Structures" at "DCC 308", "At
//  Folsom Library", or — for friends who share only their schedule — where
//  their class is right now.
//

import CoreLocation
import Foundation

struct FriendPresence: Identifiable {
    enum Freshness: Equatable {
        /// Live location updated within the last ~20 minutes.
        case live
        /// Live location, but older.
        case stale
        /// No live location; inferred from the friend's shared schedule.
        case scheduled
    }

    let friend: SocialFriend
    let coordinate: CLLocationCoordinate2D?
    let building: CampusBuilding?
    let headline: String
    let detail: String?
    let updatedAt: Date?
    let freshness: Freshness
    /// The friend's current class, when their schedule shows one.
    let currentActivity: ScheduledActivity?

    var id: String { friend.id }
    var isOnMap: Bool { coordinate != nil }
}

struct ScheduledActivity: Equatable {
    let title: String
    let location: String
    let roomLabel: String?
    let building: CampusBuilding?
    let start: Date
    let end: Date
    let isClass: Bool
    let isExam: Bool
}

enum FriendPresenceResolver {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func resolve(
        friend: SocialFriend,
        location: SharedFriendLocation?,
        schedule: SharedScheduleSnapshot?,
        now: Date = Date(),
        directory: CampusDirectory = .shared
    ) -> FriendPresence? {
        let current = schedule.flatMap { currentActivity(in: $0, at: now, directory: directory) }

        if let location, location.isVisible(at: now) {
            return livePresence(friend: friend, location: location, current: current, now: now, directory: directory)
        }

        guard let current else {
            if let upcoming = schedule.flatMap({ upcomingActivity(in: $0, at: now, directory: directory) }) {
                return FriendPresence(
                    friend: friend,
                    coordinate: nil,
                    building: upcoming.building,
                    headline: "Heading to \(upcoming.roomLabel ?? upcoming.location)",
                    detail: "\(upcoming.title) at \(timeFormatter.string(from: upcoming.start))",
                    updatedAt: nil,
                    freshness: .scheduled,
                    currentActivity: nil
                )
            }
            return nil
        }

        let place = current.roomLabel ?? (current.location.isEmpty ? nil : current.location)
        return FriendPresence(
            friend: friend,
            coordinate: current.building?.center,
            building: current.building,
            headline: activityHeadline(current),
            detail: [place, "until \(timeFormatter.string(from: current.end))", "from schedule"]
                .compactMap { $0 }
                .joined(separator: " · "),
            updatedAt: nil,
            freshness: .scheduled,
            currentActivity: current
        )
    }

    private static func livePresence(
        friend: SocialFriend,
        location: SharedFriendLocation,
        current: ScheduledActivity?,
        now: Date,
        directory: CampusDirectory
    ) -> FriendPresence {
        let building = directory.building(id: location.placeID)
            ?? directory.place(for: location.coordinate, horizontalAccuracy: location.accuracy).building
        let kind = location.placeKind
            ?? directory.place(for: location.coordinate, horizontalAccuracy: location.accuracy).kind
        let freshness: FriendPresence.Freshness = location.isFresh(at: now) ? .live : .stale

        let headline: String
        var detail: String?

        if let current, let building, current.building == building {
            // Location and schedule agree: the most specific answer we have.
            headline = activityHeadline(current)
            detail = [current.roomLabel ?? building.shortName, "until \(timeFormatter.string(from: current.end))"]
                .joined(separator: " · ")
        } else if let building {
            headline = kind == .inside ? "At \(building.name)" : "Near \(building.name)"
            if let current {
                detail = "\(current.isClass ? "Class" : "Scheduled"): \(current.title)"
                    + (current.roomLabel.map { " (\($0))" } ?? "")
            }
        } else {
            headline = location.isOnCampus ? "On campus" : "Off campus"
            if let current {
                detail = "\(current.isClass ? "Class" : "Scheduled"): \(current.title)"
            }
        }

        return FriendPresence(
            friend: friend,
            coordinate: location.coordinate,
            building: building,
            headline: headline,
            detail: detail,
            updatedAt: location.updatedAt,
            freshness: freshness,
            currentActivity: current
        )
    }

    private static func activityHeadline(_ activity: ScheduledActivity) -> String {
        if activity.isExam { return "In an exam · \(activity.title)" }
        return activity.isClass ? "In class · \(activity.title)" : activity.title
    }

    static func currentActivity(
        in schedule: SharedScheduleSnapshot,
        at now: Date,
        directory: CampusDirectory
    ) -> ScheduledActivity? {
        schedule.items
            .compactMap { activity(from: $0, directory: directory) }
            .filter { $0.start <= now && now < $0.end }
            .sorted { lhs, rhs in
                if lhs.isClass != rhs.isClass { return lhs.isClass }
                return lhs.start > rhs.start
            }
            .first
    }

    /// A class starting within 20 minutes, used when nothing is happening now.
    static func upcomingActivity(
        in schedule: SharedScheduleSnapshot,
        at now: Date,
        directory: CampusDirectory
    ) -> ScheduledActivity? {
        schedule.items
            .compactMap { activity(from: $0, directory: directory) }
            .filter { $0.isClass && $0.start > now && $0.start.timeIntervalSince(now) <= 20 * 60 && $0.building != nil }
            .min { $0.start < $1.start }
    }

    private static func activity(from item: SharedScheduleItem, directory: CampusDirectory) -> ScheduledActivity? {
        guard !item.isAllDay,
              let start = SharedScheduleDates.parse(item.startDate),
              let end = SharedScheduleDates.parse(item.endDate) else { return nil }

        let rawTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExam = item.badge?.lowercased() == "exam" || rawTitle.hasPrefix("★")
        let title = rawTitle.replacingOccurrences(of: "★ ", with: "")
        let location = item.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = directory.match(scheduleLocation: location)

        return ScheduledActivity(
            title: title.isEmpty ? "Busy" : title,
            location: location,
            roomLabel: match.map { match in
                match.room.map { "\(match.building.shortName) \($0)" } ?? match.building.shortName
            },
            building: match?.building,
            start: start,
            end: end,
            isClass: item.kind == CalendarEventKind.classMeeting.rawValue,
            isExam: isExam
        )
    }
}
