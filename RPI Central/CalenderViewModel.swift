//  CalendarViewModel.swift
//  RPI Central

import Foundation
import SwiftUI

final class CalendarViewModel: ObservableObject {
    @Published var displayedMonthStart: Date
    @Published var selectedDate: Date
    @Published var events: [ClassEvent]

    private let calendar = Calendar.current

    // Adjust to the real semester dates
    private let semesterStartDate: Date
    private let semesterEndDate: Date

    init() {
        let today = Date()
        self.displayedMonthStart = today.startOfMonth(using: calendar)
        self.selectedDate = today
        self.events = CalendarViewModel.sampleEvents(for: today)

        var compsStart = DateComponents()
        compsStart.year = 2025
        compsStart.month = 1
        compsStart.day = 13    // first day of classes (tweak if needed)

        var compsEnd = DateComponents()
        compsEnd.year = 2025
        compsEnd.month = 5
        compsEnd.day = 9       // last day of classes (tweak if needed)

        self.semesterStartDate = calendar.date(from: compsStart) ?? today
        self.semesterEndDate = calendar.date(from: compsEnd) ?? today
    }

    // MARK: - Month navigation

    func goToPreviousMonth() {
        if let newDate = calendar.date(byAdding: .month, value: -1, to: displayedMonthStart) {
            displayedMonthStart = newDate.startOfMonth(using: calendar)
        }
    }

    func goToNextMonth() {
        if let newDate = calendar.date(byAdding: .month, value: 1, to: displayedMonthStart) {
            displayedMonthStart = newDate.startOfMonth(using: calendar)
        }
    }

    // MARK: - Events per day

    func events(on date: Date) -> [ClassEvent] {
        events
            .filter { calendar.isDate($0.startDate, inSameDayAs: date) }
            .sorted { $0.startDate < $1.startDate }
    }

    func addEvent(
        title: String,
        location: String,
        date: Date,
        startTime: Date,
        endTime: Date,
        color: Color = .blue
    ) {
        let start = merge(date: date, time: startTime)
        let end = merge(date: date, time: endTime)

        let new = ClassEvent(
            title: title,
            location: location,
            startDate: start,
            endDate: end,
            color: color
        )
        events.append(new)
    }

    func deleteEvents(at offsets: IndexSet, on date: Date) {
        let todaysEvents = events(on: date)
        let idsToDelete = offsets.map { todaysEvents[$0].id }
        events.removeAll { idsToDelete.contains($0.id) }
    }

    // MARK: - Add a course section for the whole semester

    func addCourseSection(_ section: CourseSection, course: Course) {
        for meeting in section.meetings {
            for day in meeting.days {
                generateEventsForMeeting(
                    course: course,
                    section: section,
                    meeting: meeting,
                    weekday: day
                )
            }
        }
    }

    private func generateEventsForMeeting(
        course: Course,
        section: CourseSection,
        meeting: Meeting,
        weekday: Weekday
    ) {
        guard let firstClassDate = firstDate(onOrAfter: semesterStartDate,
                                             weekday: weekday.calendarWeekday)
        else { return }

        var date = firstClassDate
        while date <= semesterEndDate {
            guard
                let startComponents = timeComponents(from: meeting.start),
                let endComponents = timeComponents(from: meeting.end)
            else {
                break
            }

            var startDateComponents = calendar.dateComponents([.year, .month, .day], from: date)
            startDateComponents.hour = startComponents.hour
            startDateComponents.minute = startComponents.minute

            var endDateComponents = calendar.dateComponents([.year, .month, .day], from: date)
            endDateComponents.hour = endComponents.hour
            endDateComponents.minute = endComponents.minute

            guard
                let startDate = calendar.date(from: startDateComponents),
                let endDate = calendar.date(from: endDateComponents)
            else { break }

            let title = "\(course.subject) \(course.number) – \(course.title)"
            let crnText = section.crn.map(String.init) ?? "Unknown CRN"
            let location = meeting.location.isEmpty
                ? "CRN \(crnText)"
                : "\(meeting.location) · CRN \(crnText)"

            let event = ClassEvent(
                title: title,
                location: location,
                startDate: startDate,
                endDate: endDate,
                color: .blue
            )
            events.append(event)

            // Next week
            guard let next = calendar.date(byAdding: .day, value: 7, to: date) else { break }
            date = next
        }
    }

    // MARK: - Helper functions

    private func merge(date: Date, time: Date) -> Date {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)

        var merged = DateComponents()
        merged.year = dateComponents.year
        merged.month = dateComponents.month
        merged.day = dateComponents.day
        merged.hour = timeComponents.hour
        merged.minute = timeComponents.minute

        return calendar.date(from: merged) ?? date
    }

    private func firstDate(onOrAfter start: Date, weekday: Int) -> Date? {
        var date = start
        while calendar.component(.weekday, from: date) != weekday {
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            date = next
        }
        return date
    }

    private func timeComponents(from string: String) -> DateComponents? {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return comps
    }

    private static func sampleEvents(for today: Date) -> [ClassEvent] {
        let calendar = Calendar.current
        let start1 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today) ?? today
        let end1   = calendar.date(bySettingHour: 10, minute: 15, second: 0, of: today) ?? today

        let start2 = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: today) ?? today
        let end2   = calendar.date(bySettingHour: 14, minute: 15, second: 0, of: today) ?? today

        return [
            ClassEvent(title: "FOCS", location: "DCC 308", startDate: start1, endDate: end1, color: .red),
            ClassEvent(title: "Macro Theory", location: "Sage 2301", startDate: start2, endDate: end2, color: .green)
        ]
    }
}

// MARK: - Date helpers

extension Date {
    func startOfMonth(using calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: comps) ?? self
    }

    func formatted(_ format: String) -> String {
        let df = DateFormatter()
        df.dateFormat = format
        return df.string(from: self)
    }
}
