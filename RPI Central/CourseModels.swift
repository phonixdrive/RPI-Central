//
//  CourseModels.swift
//  RPI Central
//

import Foundation

// MARK: - Weekday

enum Weekday: String, Codable, CaseIterable {
    case mon = "M"
    case tue = "T"
    case wed = "W"
    case thu = "R"
    case fri = "F"
    case sat = "S"
    case sun = "U"

    // Calendar: 1 = Sunday ... 7 = Saturday
    var calendarWeekday: Int {
        switch self {
        case .sun: return 1
        case .mon: return 2
        case .tue: return 3
        case .wed: return 4
        case .thu: return 5
        case .fri: return 6
        case .sat: return 7
        }
    }

    var shortName: String { rawValue }
}

// MARK: - Meeting (one timeslot)

struct Meeting: Codable {
    let days: [Weekday]      // e.g. [.mon, .thu]
    let start: String        // "09:30"
    let end: String          // "10:50"
    let location: String
}

// MARK: - Course section (CRN)

struct CourseSection: Codable, Identifiable {
    var id: String { "\(crn ?? -1)-\(section)" }

    let crn: Int?
    let section: String
    let instructor: String
    let meetings: [Meeting]
    let prerequisitesText: String
    let credits: Double

    enum CodingKeys: String, CodingKey {
        case crn
        case section
        case instructor
        case meetings
        case prerequisitesText
        case credits
    }

    // Custom decode so section can be String or Int, etc.
    // IMPORTANT: credits defaults to 4.0 for older saved enrollments that didn't store credits.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        crn = try? container.decode(Int.self, forKey: .crn)

        if let s = try? container.decode(String.self, forKey: .section) {
            section = s
        } else if let i = try? container.decode(Int.self, forKey: .section) {
            section = String(i)
        } else {
            section = ""
        }

        instructor = (try? container.decode(String.self, forKey: .instructor)) ?? ""
        meetings = (try? container.decode([Meeting].self, forKey: .meetings)) ?? []
        prerequisitesText = (try? container.decode(String.self, forKey: .prerequisitesText)) ?? ""

        // ✅ Key fix: old persisted data won't have this key, so default to 4.0 (not 0.0)
        credits = (try? container.decode(Double.self, forKey: .credits)) ?? 4.0
    }

    // Manual memberwise init so we can use this in builders/tests
    init(
        crn: Int?,
        section: String,
        instructor: String,
        meetings: [Meeting],
        prerequisitesText: String = "",
        credits: Double = 4.0
    ) {
        self.crn = crn
        self.section = section
        self.instructor = instructor
        self.meetings = meetings
        self.prerequisitesText = prerequisitesText
        self.credits = credits
    }
}

// MARK: - Course

struct Course: Codable, Identifiable {
    var id: String { subject + "-" + number }

    let subject: String      // "CSCI"
    let number: String       // "2300" (stored as String even if JSON had an Int)
    let title: String
    let description: String
    let sections: [CourseSection]

    enum CodingKeys: String, CodingKey {
        case subject
        case number
        case title
        case description
        case sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        subject = (try? container.decode(String.self, forKey: .subject)) ?? ""

        // number can be "2300" or 2300
        if let s = try? container.decode(String.self, forKey: .number) {
            number = s
        } else if let i = try? container.decode(Int.self, forKey: .number) {
            number = String(i)
        } else {
            number = ""
        }

        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        sections = (try? container.decode([CourseSection].self, forKey: .sections)) ?? []
    }

    init(subject: String, number: String, title: String, description: String, sections: [CourseSection]) {
        self.subject = subject
        self.number = number
        self.title = title
        self.description = description
        self.sections = sections
    }
}
