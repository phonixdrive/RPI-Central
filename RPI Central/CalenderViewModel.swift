//  CalendarViewModel.swift
//  RPI Central

import Foundation
import SwiftUI

// Represents a course+section the user has added
struct EnrolledCourse: Identifiable, Equatable, Codable {
    let id: String          // e.g. "CSCI-2300-35222"
    let course: Course
    let section: CourseSection
    let semesterCode: String

    static func == (lhs: EnrolledCourse, rhs: EnrolledCourse) -> Bool {
        lhs.id == rhs.id
    }
}

final class CalendarViewModel: ObservableObject {
    @Published var displayedMonthStart: Date
    @Published var selectedDate: Date
    @Published var events: [ClassEvent]
    @Published var enrolledCourses: [EnrolledCourse] = []
    @Published var currentSemester: Semester = .spring2025

    // THEME (for .tint and Settings)
    @Published var themeColor: Color = .blue

    // whether we've already pulled academic events
    @Published private(set) var academicEventsLoaded: Bool = false

    private let calendar = Calendar.current

    /// We treat the *current* week as a template week for class meetings
    private let weekStartDate: Date
    private let weekEndDate: Date

    private let enrolledStorageKey = "enrolled_courses_v1"

    // Your color palette: [light, dark]
    // Order: red, orange, blue, green, yellow
    private let lightPalette: [Color] = [
        Color(red: 1.0,       green: 0.83529,  blue: 0.87451),  // #ffd5df
        Color(red: 1.0,       green: 0.91373,  blue: 0.80784),  // #ffe9ce
        Color(red: 0.81176,   green: 0.93725,  blue: 0.98824),  // #cfeffc
        Color(red: 0.85490,   green: 0.96863,  blue: 0.85882),  // #daf7db
        Color(red: 1.0,       green: 0.95686,  blue: 0.81569)   // #fff4d0
    ]

    private let darkPalette: [Color] = [
        Color(red: 0.99608,   green: 0.13725,  blue: 0.4),      // #fe2366 (red)
        Color(red: 1.0,       green: 0.58039,  blue: 0.19608),  // #ff9432 (orange)
        Color(red: 0.27843,   green: 0.85882,  blue: 0.34510),  // #47db58
        Color(red: 0.28235,   green: 0.85490,  blue: 0.34510),  // #48da58
        Color(red: 1.0,       green: 0.79216,  blue: 0.26667)   // #ffca44 (yellow)
    ]

    init() {
        let today = Date()

        // Current week bounds (Sunday start)
        let interval = calendar.dateInterval(of: .weekOfYear, for: today)
        let startOfWeek = interval?.start ?? today
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek) ?? startOfWeek

        self.weekStartDate = startOfWeek
        self.weekEndDate = endOfWeek

        self.selectedDate = startOfWeek
        self.displayedMonthStart = startOfWeek.startOfMonth(using: calendar)
        self.events = []
        self.enrolledCourses = []

        loadEnrollment()
        rebuildEventsFromEnrollment()
    }

    // MARK: - Month navigation (for future month view)

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

    /// Return events for this date.
    /// - Class events (enrollmentID != nil) are treated as *template weekly* events
    ///   and are mapped onto whatever week you're viewing.
    /// - Non-class events (enrollmentID == nil) are fixed-date events.
    func events(on date: Date) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let weekday = calendar.component(.weekday, from: date)

        for base in events {
            if let _ = base.enrollmentID {
                // Weekly template (class)
                let baseWeekday = calendar.component(.weekday, from: base.startDate)
                guard baseWeekday == weekday else { continue }

                let startTime = calendar.dateComponents([.hour, .minute, .second], from: base.startDate)
                let endTime   = calendar.dateComponents([.hour, .minute, .second], from: base.endDate)

                var startComps = calendar.dateComponents([.year, .month, .day], from: date)
                startComps.hour = startTime.hour
                startComps.minute = startTime.minute
                startComps.second = startTime.second

                var endComps = calendar.dateComponents([.year, .month, .day], from: date)
                endComps.hour = endTime.hour
                endComps.minute = endTime.minute
                endComps.second = endTime.second

                guard
                    let newStart = calendar.date(from: startComps),
                    let newEnd   = calendar.date(from: endComps)
                else { continue }

                let copy = ClassEvent(
                    title: base.title,
                    location: base.location,
                    startDate: newStart,
                    endDate: newEnd,
                    backgroundColor: base.backgroundColor,
                    accentColor: base.accentColor,
                    enrollmentID: base.enrollmentID
                )

                result.append(copy)
            } else {
                // Fixed-date event (academic calendar, manual event, etc.)
                if calendar.isDate(base.startDate, inSameDayAs: date) {
                    result.append(base)
                }
            }
        }

        return result.sorted { $0.startDate < $1.startDate }
    }

    func addEvent(
        title: String,
        location: String,
        date: Date,
        startTime: Date,
        endTime: Date,
        color: Color = .gray
    ) {
        let start = merge(date: date, time: startTime)
        let end = merge(date: date, time: endTime)

        let new = ClassEvent(
            title: title,
            location: location,
            startDate: start,
            endDate: end,
            backgroundColor: color,
            accentColor: color,
            enrollmentID: nil
        )
        events.append(new)
    }

    func deleteEvents(at offsets: IndexSet, on date: Date) {
        let todaysEvents = events(on: date)
        let idsToDelete = offsets.map { todaysEvents[$0].id }
        events.removeAll { idsToDelete.contains($0.id) }
    }

    // MARK: - Semester switching

    func changeSemester(to newSemester: Semester) {
        currentSemester = newSemester
        rebuildEventsFromEnrollment()
    }

    // MARK: - Enrollment helpers

    private func enrollmentID(for course: Course, section: CourseSection) -> String {
        let crnText = section.crn.map(String.init) ?? "NA"
        return "\(course.subject)-\(course.number)-\(crnText)"
    }

    func isEnrolled(for course: Course, section: CourseSection) -> Bool {
        let id = enrollmentID(for: course, section: section)
        return enrolledCourses.contains { $0.id == id }
    }

    func enrollment(for course: Course, section: CourseSection) -> EnrolledCourse? {
        let id = enrollmentID(for: course, section: section)
        return enrolledCourses.first { $0.id == id }
    }

    // MARK: - QuACS-style color assignment

    /// Given enrollment at index i among n classes, return its light/dark colors.
    /// This implements: take first n colors, reverse them.
    private func colorsForEnrollmentIndex(_ i: Int, total n: Int) -> (Color, Color) {
        guard n > 0 else { return (lightPalette[0], darkPalette[0]) }
        let paletteIndex = (n - 1 - i) % lightPalette.count
        return (lightPalette[paletteIndex], darkPalette[paletteIndex])
    }

    /// Recompute colors for all events when the enrollment list changes.
    private func recolorAllEvents() {
        var updated = events
        for idx in updated.indices {
            guard let id = updated[idx].enrollmentID else { continue }
            guard let enrollIndex = enrolledCourses.firstIndex(where: { $0.id == id }) else { continue }

            let (bg, accent) = colorsForEnrollmentIndex(enrollIndex, total: enrolledCourses.count)
            updated[idx].backgroundColor = bg
            updated[idx].accentColor = accent
        }
        events = updated
    }

    // MARK: - Time conflict detection

    /// Returns true if this section clashes with any existing *class* event.
    private func hasTimeConflict(for section: CourseSection) -> Bool {
        for meeting in section.meetings {
            guard
                let startComponents = timeComponents(from: meeting.start),
                let endComponents = timeComponents(from: meeting.end)
            else { continue }

            for day in meeting.days {
                guard let date = firstDate(onOrAfter: weekStartDate,
                                           weekday: day.calendarWeekday) else { continue }

                var newStartComps = calendar.dateComponents([.year, .month, .day], from: date)
                newStartComps.hour = startComponents.hour
                newStartComps.minute = startComponents.minute

                var newEndComps = calendar.dateComponents([.year, .month, .day], from: date)
                newEndComps.hour = endComponents.hour
                newEndComps.minute = endComponents.minute

                guard
                    let newStart = calendar.date(from: newStartComps),
                    let newEnd = calendar.date(from: newEndComps)
                else { continue }

                // Only compare against class events (enrollmentID != nil)
                for e in events where e.enrollmentID != nil &&
                    calendar.isDate(e.startDate, inSameDayAs: newStart) {

                    let eStart = e.startDate
                    let eEnd = e.endDate

                    // Overlap if they intersect at all
                    if newStart < eEnd && eStart < newEnd {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Public helper so the UI can show "Time conflict"
    func hasConflict(for course: Course, section: CourseSection) -> Bool {
        hasTimeConflict(for: section)
    }

    // MARK: - Add/remove a course section

    func addCourseSection(_ section: CourseSection, course: Course) {
        let id = enrollmentID(for: course, section: section)

        // Already enrolled? bail to avoid duplicates
        if enrolledCourses.contains(where: { $0.id == id }) {
            return
        }

        // Prevent adding classes that conflict in time
        if hasTimeConflict(for: section) {
            return
        }

        let enrollment = EnrolledCourse(
            id: id,
            course: course,
            section: section,
            semesterCode: currentSemester.rawValue
        )
        enrolledCourses.append(enrollment)

        // Generate events for this "template week" (weekStartDate...weekEndDate)
        for meeting in section.meetings {
            for day in meeting.days {
                guard let classDate = firstDate(onOrAfter: weekStartDate,
                                                weekday: day.calendarWeekday) else { continue }

                generateSingleWeekEvent(
                    course: course,
                    section: section,
                    meeting: meeting,
                    date: classDate,
                    enrollmentID: id
                )
            }
        }

        // Now recolor everything so colors shift like QuACS
        recolorAllEvents()
        saveEnrollment()
    }

    func removeEnrollment(_ enrollment: EnrolledCourse) {
        enrolledCourses.removeAll { $0.id == enrollment.id }
        events.removeAll { $0.enrollmentID == enrollment.id }
        recolorAllEvents()
        saveEnrollment()
    }

    func removeEnrollment(at offsets: IndexSet) {
        for index in offsets {
            guard index < enrolledCourses.count else { continue }
            let enrollment = enrolledCourses[index]
            removeEnrollment(enrollment)
        }
    }

    // MARK: - Academic events

    func addAcademicEvents(_ academicEvents: [AcademicEvent]) {
        for ev in academicEvents {
            let event = ClassEvent(
                title: ev.title,
                location: ev.location ?? "",
                startDate: ev.startDate,
                endDate: ev.endDate,
                backgroundColor: Color.gray.opacity(0.3),
                accentColor: .gray,
                enrollmentID: nil
            )
            events.append(event)
        }
        academicEventsLoaded = true
    }

    // MARK: - Event creation helpers

    fileprivate func generateSingleWeekEvent(
        course: Course,
        section: CourseSection,
        meeting: Meeting,
        date: Date,
        enrollmentID: String
    ) {
        guard
            let startComponents = timeComponents(from: meeting.start),
            let endComponents = timeComponents(from: meeting.end)
        else { return }

        var startDateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        startDateComponents.hour = startComponents.hour
        startDateComponents.minute = startComponents.minute

        var endDateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        endDateComponents.hour = endComponents.hour
        endDateComponents.minute = endComponents.minute

        guard
            let startDate = calendar.date(from: startDateComponents),
            let endDate = calendar.date(from: endDateComponents)
        else { return }

        let title = "\(course.subject) \(course.number) – \(course.title)"
        let crnText = section.crn.map(String.init) ?? "Unknown CRN"
        let location = meeting.location.isEmpty
            ? "CRN \(crnText)"
            : "\(meeting.location) · CRN \(crnText)"

        // Temp color; will be normalized by recolorAllEvents()
        let bg = lightPalette[0]
        let accent = darkPalette[0]

        let event = ClassEvent(
            title: title,
            location: location,
            startDate: startDate,
            endDate: endDate,
            backgroundColor: bg,
            accentColor: accent,
            enrollmentID: enrollmentID
        )
        events.append(event)
    }

    // MARK: - Persistence

    private func saveEnrollment() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(enrolledCourses) {
            UserDefaults.standard.set(data, forKey: enrolledStorageKey)
        }
    }

    private func loadEnrollment() {
        guard let data = UserDefaults.standard.data(forKey: enrolledStorageKey) else { return }
        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([EnrolledCourse].self, from: data) {
            self.enrolledCourses = loaded
        }
    }

    /// Rebuild class events from the current `enrolledCourses` list, for the template week,
    /// only for the active semester.
    private func rebuildEventsFromEnrollment() {
        // If you later add academic events, you might want to preserve them here.
        events.removeAll()

        for enrollment in enrolledCourses where enrollment.semesterCode == currentSemester.rawValue {
            let course = enrollment.course
            let section = enrollment.section
            let id = enrollment.id

            for meeting in section.meetings {
                for day in meeting.days {
                    guard let classDate = firstDate(onOrAfter: weekStartDate,
                                                    weekday: day.calendarWeekday) else { continue }

                    generateSingleWeekEvent(
                        course: course,
                        section: section,
                        meeting: meeting,
                        date: classDate,
                        enrollmentID: id
                    )
                }
            }
        }

        recolorAllEvents()
    }

    // MARK: - Low-level helpers

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

    fileprivate func firstDate(onOrAfter start: Date, weekday: Int) -> Date? {
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

// MARK: - Day string -> weekday

extension String {
    /// Maps "M","T","W","R","F","S" to Calendar weekday ints
    /// Calendar: 1 = Sunday, 2 = Monday, ...
    var calendarWeekday: Int {
        switch self.uppercased() {
        case "M": return 2
        case "T": return 3
        case "W": return 4
        case "R": return 5
        case "F": return 6
        case "S": return 7
        default:  return 1
        }
    }
}
