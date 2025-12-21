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

    /// True for all-day / date-range events (academic calendar, holidays, breaks).
    let isAllDay: Bool

    init(
        title: String,
        location: String,
        startDate: Date,
        endDate: Date,
        backgroundColor: Color,
        accentColor: Color,
        enrollmentID: String?,
        isAllDay: Bool = false
    ) {
        self.title = title
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.enrollmentID = enrollmentID
        self.isAllDay = isAllDay
    }
}
