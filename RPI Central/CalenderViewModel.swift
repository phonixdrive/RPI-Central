//
//  CalendarViewModel.swift
//  RPI Central
//

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
    @Published var currentSemester: Semester = .fall2025

    // THEME (for .tint and Settings)
    @Published var themeColor: Color = .blue

    // whether we've already pulled academic events
    @Published private(set) var academicEventsLoaded: Bool = false

    // Prereq enforcement (Settings toggle)
    @Published var enforcePrerequisites: Bool = false {
        didSet {
            UserDefaults.standard.set(enforcePrerequisites, forKey: enforcePrereqsKey)
        }
    }

    private let calendar = Calendar.current

    /// We treat the *current* week as a template week for class meetings
    private let weekStartDate: Date
    private let weekEndDate: Date

    private let enrolledStorageKey = "enrolled_courses_v1"
    private let enforcePrereqsKey  = "enforce_prereqs_v1"

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
        Color(red: 0.99608,   green: 0.13725,  blue: 0.4),      // #fe2366
        Color(red: 1.0,       green: 0.58039,  blue: 0.19608),  // #ff9432
        Color(red: 0.231,     green: 0.510,    blue: 0.965),    // blue-ish
        Color(red: 0.28235,   green: 0.85490,  blue: 0.34510),  // #48da58
        Color(red: 1.0,       green: 0.79216,  blue: 0.26667)   // #ffca44
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

        self.enforcePrerequisites = UserDefaults.standard.bool(forKey: enforcePrereqsKey)

        loadEnrollment()
        rebuildEventsFromEnrollment()
    }

    // MARK: - Events per day

    /// Return events for this date.
    /// - Class events (enrollmentID != nil) are treated as *template weekly* events.
    /// - Fixed-date events (enrollmentID == nil) are anchored to real dates.
    ///   All-day / multi-day events show on every day in their range.
    func events(on date: Date) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let weekday = calendar.component(.weekday, from: date)

        for base in events {
            if base.kind == .classMeeting, base.enrollmentID != nil {
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
                    enrollmentID: base.enrollmentID,
                    isAllDay: false,
                    kind: .classMeeting
                )

                result.append(copy)
            } else {
                // Fixed-date (academic or manual)
                if base.isAllDay {
                    let d = calendar.startOfDay(for: date)
                    let s = calendar.startOfDay(for: base.startDate)
                    let e = calendar.startOfDay(for: base.endDate)
                    if s <= d && d <= e {
                        result.append(base)
                    }
                } else {
                    if calendar.isDate(base.startDate, inSameDayAs: date) {
                        result.append(base)
                    }
                }
            }
        }

        // All-day first, then timed
        return result.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay && !$1.isAllDay }
            return $0.startDate < $1.startDate
        }
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
            enrollmentID: nil,
            isAllDay: false,
            kind: .personal
        )
        events.append(new)
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

    private func colorsForEnrollmentIndex(_ i: Int, total n: Int) -> (Color, Color) {
        guard n > 0 else { return (lightPalette[0], darkPalette[0]) }
        let paletteIndex = (n - 1 - i) % lightPalette.count
        return (lightPalette[paletteIndex], darkPalette[paletteIndex])
    }

    private func recolorAllEvents() {
        var updated = events
        for idx in updated.indices {
            guard updated[idx].kind == .classMeeting else { continue }
            guard let id = updated[idx].enrollmentID else { continue }
            guard let enrollIndex = enrolledCourses.firstIndex(where: { $0.id == id }) else { continue }

            let (bg, accent) = colorsForEnrollmentIndex(enrollIndex, total: enrolledCourses.count)
            updated[idx].backgroundColor = bg
            updated[idx].accentColor = accent
        }
        events = updated
    }

    // MARK: - Time conflict detection

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

                for e in events where e.kind == .classMeeting &&
                    e.enrollmentID != nil &&
                    calendar.isDate(e.startDate, inSameDayAs: newStart) {

                    if newStart < e.endDate && e.startDate < newEnd {
                        return true
                    }
                }
            }
        }
        return false
    }

    func hasConflict(for course: Course, section: CourseSection) -> Bool {
        hasTimeConflict(for: section)
    }

    // MARK: - Prereqs (FIXED)

    private func courseKey(_ course: Course) -> String {
        "\(course.subject)-\(course.number)"
    }

    /// Returns prereq course IDs like ["MATH-1010","PHYS-1100"] if available.
    /// First tries prereq_graph.json (normalized), then falls back to parsing section prereq strings.
    func prerequisiteCourseIDs(for course: Course) -> [String] {
        let key = courseKey(course)
        let fromGraph = PrereqStore.shared.prereqIDs(for: key)
        if !fromGraph.isEmpty { return fromGraph }

        // Fallback: parse from prerequisitesText (best-effort)
        let texts = course.sections.map { $0.prerequisitesText }.filter { !$0.isEmpty }
        var out: [String] = []
        for t in texts {
            out.append(contentsOf: extractCourseIDs(from: t))
        }
        return Array(Set(out)).sorted()
    }

    func missingPrerequisites(for course: Course) -> [String] {
        let prereqs = prerequisiteCourseIDs(for: course)
        if prereqs.isEmpty { return [] }

        let completed: Set<String> = Set(enrolledCourses.map { "\($0.course.subject)-\($0.course.number)" })
        return prereqs.filter { !completed.contains($0) }
    }

    func prerequisitesDisplayString(for course: Course) -> String? {
        let prereqs = prerequisiteCourseIDs(for: course)
        if !prereqs.isEmpty {
            return prereqs
                .map { $0.replacingOccurrences(of: "-", with: " ") }
                .joined(separator: ", ")
        }

        // If we still have nothing, show any human-readable per-section string
        let texts = course.sections
            .map { $0.prerequisitesText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = texts.first else { return nil }
        return first
    }

    private func extractCourseIDs(from text: String) -> [String] {
        let upper = text.uppercased()

        // Match "CSCI 1200" or "CSCI-1200"
        let patterns = [
            #"([A-Z]{3,4})\s*[- ]\s*(\d{4})"#,
            #"([A-Z]{3,4})(\d{4})"#
        ]

        var found: [String] = []
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: []) {
                let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
                for m in re.matches(in: upper, options: [], range: range) {
                    guard m.numberOfRanges >= 3,
                          let r1 = Range(m.range(at: 1), in: upper),
                          let r2 = Range(m.range(at: 2), in: upper)
                    else { continue }
                    let subj = String(upper[r1])
                    let num  = String(upper[r2])
                    found.append("\(subj)-\(num)")
                }
            }
        }

        return Array(Set(found)).sorted()
    }

    // MARK: - Add/remove a course section

    func addCourseSection(_ section: CourseSection, course: Course) {
        let id = enrollmentID(for: course, section: section)

        if enrolledCourses.contains(where: { $0.id == id }) {
            return
        }

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

        recolorAllEvents()
        saveEnrollment()
    }

    func removeEnrollment(_ enrollment: EnrolledCourse) {
        enrolledCourses.removeAll { $0.id == enrollment.id }
        events.removeAll { $0.enrollmentID == enrollment.id }
        recolorAllEvents()
        saveEnrollment()
    }

    // MARK: - Academic events

    func addAcademicEvents(_ academicEvents: [AcademicEvent]) {
        for ev in academicEvents {
            let bg = ClassEvent.backgroundForAcademic(kind: ev.kind)
            let accent = ClassEvent.accentForAcademic(kind: ev.kind)

            let event = ClassEvent(
                title: ev.title,
                location: ev.location ?? "",
                startDate: ev.startDate,
                endDate: ev.endDate,
                backgroundColor: bg,
                accentColor: accent,
                enrollmentID: nil,
                isAllDay: true,
                kind: ev.kind
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

        let title = course.title

        let code = "\(course.subject) \(course.number)"
        let crnText = section.crn.map(String.init) ?? "Unknown CRN"
        let locCore = meeting.location.isEmpty ? code : "\(code) · \(meeting.location)"
        let location = "\(locCore) · CRN \(crnText)"

        let bg = lightPalette[0]
        let accent = darkPalette[0]

        let event = ClassEvent(
            title: title,
            location: location,
            startDate: startDate,
            endDate: endDate,
            backgroundColor: bg,
            accentColor: accent,
            enrollmentID: enrollmentID,
            isAllDay: false,
            kind: .classMeeting
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

    /// Rebuild class events from enrolledCourses for the template week,
    /// preserving fixed-date events (manual + academic).
    private func rebuildEventsFromEnrollment() {
        let fixed = events.filter { $0.enrollmentID == nil }  // keep manual + academic
        events = fixed

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
