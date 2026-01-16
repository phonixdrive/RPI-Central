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
