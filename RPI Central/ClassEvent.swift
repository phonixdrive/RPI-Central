//  ClassEvent.swift
//  RPI Central

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
    /// `nil` for manually-added events.
    let enrollmentID: String?
}
