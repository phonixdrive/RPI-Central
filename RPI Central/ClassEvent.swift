//
//  ClassEvent.swift
//  RPI Central
//

import Foundation
import SwiftUI

struct ClassEvent: Identifiable, Equatable {
    let id = UUID()

    let title: String
    let location: String
    let startDate: Date
    let endDate: Date

    /// Light background color for the block.
    var backgroundColor: Color

    /// Dark accent color for the left strip.
    var accentColor: Color

    /// Which enrolled course generated this event (subject-number-CRN).
    /// `nil` for manually-added events and academic calendar events.
    let enrollmentID: String?

    /// Optional recurrence group for manually-added events.
    /// If non-nil, all events in the recurrence share the same seriesID.
    let seriesID: UUID?

    /// True for all-day / date-range events (academic calendar, holidays, breaks).
    let isAllDay: Bool

    /// Category used for UI color-coding and special rendering.
    let kind: CalendarEventKind

    init(
        title: String,
        location: String,
        startDate: Date,
        endDate: Date,
        backgroundColor: Color,
        accentColor: Color,
        enrollmentID: String?,
        seriesID: UUID? = nil,
        isAllDay: Bool = false,
        kind: CalendarEventKind = .personal
    ) {
        self.title = title
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.enrollmentID = enrollmentID
        self.seriesID = seriesID
        self.isAllDay = isAllDay
        self.kind = kind
    }

    /// A consistent color for dots / list indicators.
    /// For class meetings + personal events, use the accent color (two-tone system).
    var displayColor: Color {
        switch kind {
        case .classMeeting:
            return accentColor
        case .personal:
            return accentColor

        case .holiday:
            return .red
        case .break:
            return .orange
        case .readingDays:
            return .blue
        case .finals:
            return .purple
        case .noClasses:
            return .gray
        case .followDay:
            return .teal
        case .academicOther:
            return .yellow
        }
    }

    /// Used for overlap-group swipe state + hiding single class occurrences.
    var interactionKey: String {
        let sid = seriesID?.uuidString ?? "nil"
        let eid = enrollmentID ?? "nil"
        return "\(title)|\(location)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)|\(kind.rawValue)|\(isAllDay)|\(eid)|\(sid)"
    }

    /// Suggested background color for academic all-day events.
    static func backgroundForAcademic(kind: CalendarEventKind) -> Color {
        switch kind {
        case .holiday:      return Color.red.opacity(0.22)
        case .break:        return Color.orange.opacity(0.22)
        case .readingDays:  return Color.blue.opacity(0.22)
        case .finals:       return Color.purple.opacity(0.22)
        case .noClasses:    return Color.gray.opacity(0.18)
        case .followDay:    return Color.teal.opacity(0.22)
        case .academicOther:return Color.yellow.opacity(0.18)
        default:            return Color.gray.opacity(0.18)
        }
    }

    /// Suggested accent color for academic all-day events.
    static func accentForAcademic(kind: CalendarEventKind) -> Color {
        switch kind {
        case .holiday:      return .red
        case .break:        return .orange
        case .readingDays:  return .blue
        case .finals:       return .purple
        case .noClasses:    return .gray
        case .followDay:    return .teal
        case .academicOther:return .yellow
        default:            return .gray
        }
    }
}
