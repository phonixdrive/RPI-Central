//
//  CalendarEventKind.swift
//  RPI Central
//
import Foundation

/// High-level categories so UI can color-code non-class events (breaks, holidays, finals, etc.)
enum CalendarEventKind: String, Codable, CaseIterable {
    case classMeeting
    case personal

    case holiday
    case `break`
    case readingDays
    case finals
    case noClasses
    case followDay
    case academicOther
}
