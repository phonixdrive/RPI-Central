//
//  WidgetSharedModels.swift
//  Shared (RPI Central + WidgetsExtension)
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum RPICentralWidgetShared {
    static let appGroup = "group.phonix.RPI-Central"
    static let snapshotKey = "rpiCentral.widget.snapshot.v4"
    static let debugKey = "rpiCentral.widget.debug"
}

enum RPICentralWidgetTheme: String, Codable {
    case blue, red, green, purple, orange

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .purple: return .purple
        case .orange: return .orange
        }
    }
}

enum RPICentralWidgetAppearance: String, Codable {
    case system
    case light
    case dark
}

struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }

    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    #if canImport(UIKit)
    static func from(_ swiftUIColor: Color) -> RGBAColor {
        let ui = UIColor(swiftUIColor)
        var rr: CGFloat = 0
        var gg: CGFloat = 0
        var bb: CGFloat = 0
        var aa: CGFloat = 0

        if ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa) {
            return RGBAColor(r: Double(rr), g: Double(gg), b: Double(bb), a: Double(aa))
        } else {
            return RGBAColor(r: 0.2, g: 0.4, b: 0.9, a: 1.0)
        }
    }
    #else
    static func from(_ swiftUIColor: Color) -> RGBAColor {
        return RGBAColor(r: 0.2, g: 0.4, b: 0.9, a: 1.0)
    }
    #endif
}

struct WidgetSnapshot: Codable {
    var generatedAt: Date
    var theme: RPICentralWidgetTheme
    var appearance: RPICentralWidgetAppearance
    var todayEvents: [WidgetDayEvent]
    var month: MonthSnapshot
    /// Events from today through the next week (added in 2.5; older
    /// snapshots decode without it).
    var upcomingEvents: [WidgetDayEvent]? = nil
    /// Tasks due in the next few weeks, soonest first.
    var deadlines: [WidgetDeadline]? = nil
    /// The app's theme color.
    var accent: RGBAColor? = nil

    var accentColor: Color { accent?.color ?? theme.color }

    /// Timed events that haven't ended yet, soonest first.
    func upcomingTimed(after now: Date) -> [WidgetDayEvent] {
        (upcomingEvents ?? todayEvents)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Events on the given day: all-day first, then by start time.
    func events(on day: Date, calendar: Calendar = .current) -> [WidgetDayEvent] {
        let dayStart = calendar.startOfDay(for: day)
        return (upcomingEvents ?? todayEvents)
            .filter { event in
                if event.isAllDay {
                    return calendar.startOfDay(for: event.startDate) <= dayStart && dayStart <= calendar.startOfDay(for: event.endDate)
                }
                return calendar.isDate(event.startDate, inSameDayAs: day)
            }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
    }

    func upcomingDeadlines(after now: Date) -> [WidgetDeadline] {
        (deadlines ?? []).filter { $0.dueDate > now }.sorted { $0.dueDate < $1.dueDate }
    }
}

struct WidgetDeadline: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// "CSCI 1200", or empty for tasks without a course.
    var courseCode: String
    /// CourseTaskKind raw value.
    var kind: String
    var dueDate: Date
    var color: RGBAColor

    var systemImage: String {
        switch kind {
        case "exam": return "star.circle.fill"
        case "quiz": return "checkmark.seal.fill"
        case "project": return "hammer.fill"
        case "assignment": return "doc.text.fill"
        default: return "tag.fill"
        }
    }
}

/// Short course label for a class event title like "CSCI 1200 - Data Structures".
enum WidgetText {
    static func courseCode(from title: String) -> String? {
        let cleaned = title.replacingOccurrences(of: "★ ", with: "")
        guard let range = cleaned.range(of: #"^[A-Z]{3,4}[ -]\d{4}"#, options: .regularExpression) else { return nil }
        return cleaned[range].replacingOccurrences(of: "-", with: " ")
    }

    /// "Data Structures" from "CSCI 1200 - Data Structures".
    static func courseName(from title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "★ ", with: "")
        if let range = cleaned.range(of: #"^[A-Z]{3,4}[ -]\d{4}\s*[-–:·]\s*"#, options: .regularExpression) {
            let rest = cleaned[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return cleaned
    }

    /// "DCC 308" for known campus rooms; otherwise the location as written.
    static func shortLocation(_ location: String) -> String {
        let abbreviations: [(String, String)] = [
            ("Darrin Communications Center", "DCC"),
            ("Jonsson Engineering Center", "JEC"),
            ("J Erik Jonsson Engineering Center", "JEC"),
            ("Jonsson-Rowland Science Center", "JROWL"),
            ("Russell Sage Laboratory", "Sage"),
            ("Sage Laboratory", "Sage"),
            ("Amos Eaton Hall", "Eaton"),
            ("Low Center for Industrial Innovation", "Low"),
            ("Walker Laboratory", "Walker"),
            ("Pittsburgh Building", "Pitt"),
            ("Carnegie Building", "Carnegie"),
            ("Troy Building", "Troy"),
            ("Lally Hall", "Lally"),
            ("West Hall", "West"),
            ("Ricketts Building", "Ricketts"),
            ("Folsom Library", "Folsom"),
        ]
        for (name, short) in abbreviations where location.localizedCaseInsensitiveContains(name) {
            return location.replacingOccurrences(of: name, with: short, options: .caseInsensitive)
        }
        return location
    }
}

struct WidgetDayEvent: Codable, Identifiable {
    var id: String
    var title: String
    var location: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var background: RGBAColor
    var accent: RGBAColor
    var badge: String?
    /// "CSCI 1200" for class meetings.
    var courseCode: String? = nil
}

struct MonthSnapshot: Codable {
    var year: Int
    var month: Int
    /// 1=Sun ... 7=Sat
    var firstWeekday: Int
    var daysInMonth: Int
    var todayDay: Int?
    var markers: [DayMarker]
}

struct DayMarker: Codable {
    var day: Int
    var dotColors: [RGBAColor]
    var hasExam: Bool
    var isBreakDay: Bool

    init(day: Int, dotColors: [RGBAColor], hasExam: Bool, isBreakDay: Bool) {
        self.day = day
        self.dotColors = dotColors
        self.hasExam = hasExam
        self.isBreakDay = isBreakDay
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case dotColors
        case hasExam
        case isBreakDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.day = try c.decode(Int.self, forKey: .day)
        self.dotColors = (try? c.decode([RGBAColor].self, forKey: .dotColors)) ?? []
        self.hasExam = (try? c.decode(Bool.self, forKey: .hasExam)) ?? false
        self.isBreakDay = (try? c.decode(Bool.self, forKey: .isBreakDay)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day)
        try c.encode(dotColors, forKey: .dotColors)
        try c.encode(hasExam, forKey: .hasExam)
        try c.encode(isBreakDay, forKey: .isBreakDay)
    }
}

// MARK: - Sample data

extension WidgetSnapshot {
    /// Shown in the widget gallery before the app has written anything.
    static func sample(now: Date) -> WidgetSnapshot {
        let calendar = Calendar.current
        /// Classes relative to now, so previews always show one in progress.
        func minutes(_ offset: Double) -> Date {
            now.addingTimeInterval(offset * 60).roundedToFiveMinutes(calendar: calendar)
        }
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        }
        let blue = RGBAColor(r: 0.20, g: 0.47, b: 0.96, a: 1)
        let purple = RGBAColor(r: 0.55, g: 0.35, b: 0.92, a: 1)
        let orange = RGBAColor(r: 0.97, g: 0.55, b: 0.15, a: 1)
        let events = [
            WidgetDayEvent(id: "1", title: "Data Structures", location: "Darrin Communications Center 308", startDate: minutes(-20), endDate: minutes(30), isAllDay: false, background: blue, accent: blue, badge: nil, courseCode: "CSCI 1200"),
            WidgetDayEvent(id: "2", title: "Calculus II", location: "Sage Laboratory 3303", startDate: minutes(45), endDate: minutes(95), isAllDay: false, background: purple, accent: purple, badge: nil, courseCode: "MATH 1020"),
            WidgetDayEvent(id: "3", title: "Physics II", location: "Jonsson Engineering Center 3117", startDate: minutes(105), endDate: minutes(155), isAllDay: false, background: orange, accent: orange, badge: nil, courseCode: "PHYS 1200"),
        ]
        return WidgetSnapshot(
            generatedAt: now,
            theme: .blue,
            appearance: .system,
            todayEvents: events,
            month: month(for: now),
            upcomingEvents: events,
            deadlines: [
                WidgetDeadline(id: "a", title: "HW 4: Recursion", courseCode: "CSCI 1200", kind: "assignment", dueDate: at(23, 59, dayOffset: 1), color: blue),
                WidgetDeadline(id: "b", title: "Midterm", courseCode: "MATH 1020", kind: "exam", dueDate: at(14, 0, dayOffset: 3), color: purple),
                WidgetDeadline(id: "c", title: "Lab Report 2", courseCode: "PHYS 1200", kind: "assignment", dueDate: at(23, 59, dayOffset: 5), color: orange),
            ],
            accent: blue
        )
    }

    static func month(for date: Date, calendar: Calendar = .current) -> MonthSnapshot {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let first = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
        let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return MonthSnapshot(
            year: comps.year ?? 2026,
            month: comps.month ?? 1,
            firstWeekday: calendar.component(.weekday, from: first),
            daysInMonth: days,
            todayDay: comps.day,
            markers: (1...days).map { DayMarker(day: $0, dotColors: [], hasExam: false, isBreakDay: false) }
        )
    }
}

private extension Date {
    func roundedToFiveMinutes(calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second], from: self)
        let extra = (parts.minute ?? 0) % 5 * 60 + (parts.second ?? 0)
        return addingTimeInterval(-Double(extra))
    }
}
