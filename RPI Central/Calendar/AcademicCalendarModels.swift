// AcademicCalendarModels.swift

import Foundation

struct AcademicCalendar: Decodable {
    let source: String
    let academicYear: String
    let generatedAt: String
    let terms: Terms
    let events: [AcademicCalendarEvent]
}

struct Terms: Decodable {
    let fall: Term
    let spring: Term
}

struct Term: Decodable {
    let classesBegin: String?
    let classesEnd: String?
}

struct AcademicCalendarEvent: Decodable, Identifiable {
    // Stable-ish ID derived from content
    var id: String { "\(title)|\(startDate)|\(endDate ?? startDate)" }

    let title: String
    let startDate: String
    let endDate: String?
    let dow: String?
    let tags: AcademicTags
}

struct AcademicTags: Decodable {
    let noClasses: Bool
    let holiday: Bool
    let followDay: Bool
    let finals: Bool
    let readingDays: Bool
    let `break`: Bool
}
