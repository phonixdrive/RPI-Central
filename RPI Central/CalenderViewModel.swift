// CalendarViewModel.swift
// RPI Central

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

// MARK: - Appearance mode (persisted)

enum AppAppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil = follow system
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

final class CalendarViewModel: ObservableObject {
    @Published var displayedMonthStart: Date
    @Published var selectedDate: Date
    @Published var events: [ClassEvent]
    @Published var enrolledCourses: [EnrolledCourse] = []
    @Published var currentSemester: Semester = .fall2025

    // MARK: - Persisted appearance settings

    // Stored theme tokens (so we can persist reliably without comparing Color values)
    private enum StoredThemeColor: String, CaseIterable {
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

        static func from(color: Color) -> StoredThemeColor {
            if color == Color.red { return .red }
            if color == Color.green { return .green }
            if color == Color.purple { return .purple }
            if color == Color.orange { return .orange }
            return .blue
        }
    }

    private let themeColorKey = "settings_theme_color_v1"
    private let appearanceModeKey = "settings_appearance_mode_v1"

    // THEME (for .tint and Settings) ✅ persisted
    @Published var themeColor: Color = .blue {
        didSet {
            let stored = StoredThemeColor.from(color: themeColor)
            UserDefaults.standard.set(stored.rawValue, forKey: themeColorKey)
        }
    }

    // Light/Dark/System ✅ persisted (default dark)
    @Published var appearanceMode: AppAppearanceMode = .dark {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceModeKey)
        }
    }

    // whether we've already pulled academic events for at least one year
    @Published private(set) var academicEventsLoaded: Bool = false

    // Term bounds by semesterCode (e.g. "202601" -> DateInterval)
    @Published private(set) var termBoundsBySemesterCode: [String: DateInterval] = [:]

    // ✅ Boot/loading overlay state (still used elsewhere if you want)
    @Published var isBootLoading: Bool = true
    @Published var canSkipBootLoading: Bool = false
    @Published var bootLoadingStatusText: String = "Loading calendar…"

    // Prereq enforcement (Settings toggle)
    @Published var enforcePrerequisites: Bool = false {
        didSet {
            UserDefaults.standard.set(enforcePrerequisites, forKey: enforcePrereqsKey)
        }
    }

    // MARK: - GPA / Grades (per enrollment)

    /// enrollmentID -> LetterGrade rawValue (e.g. "CSCI-2300-35222" -> "A-")
    @Published private(set) var gradesByEnrollmentID: [String: String] = [:]
    private let gradesStorageKey = "enrollment_grades_v1"

    private let calendar = Calendar.current

    /// We treat the *current* week as a template week for class meetings
    private let weekStartDate: Date
    private let weekEndDate: Date

    private let enrolledStorageKey = "enrolled_courses_v1"
    private let enforcePrereqsKey  = "enforce_prereqs_v1"

    // For prereq “auto-fulfillment” when a user adds a course without prereqs.
    // Map: assumedCourseID -> set of courseIDs that caused this assumption.
    private let assumedPrereqsStorageKey = "assumed_prereqs_v1"
    private var assumedBy: [String: Set<String>] = [:]

    // Track which academic years we’ve already loaded to avoid duplicates.
    private var loadedAcademicYearStarts: Set<Int> = []

    // ✅ Track “attempted” loads so UI won’t perma-block if requests hang
    private var attemptedAcademicYearStarts: Set<Int> = []
    private var attemptedTermBoundsCodes: Set<String> = []
    private var beganBootLoading: Bool = false

    // ✅ Dedup academic events so you never get “same all-day event 5 times”
    private var academicEventKeys: Set<String> = []

    // ✅ Hide single class occurrences
    private let hiddenOccurrencesKey = "hidden_class_occurrences_v1"
    private var hiddenClassOccurrences: Set<String> = []

    // ✅ Hide all-day events (academic/etc.)
    private let hiddenAllDayKey = "hidden_all_day_events_v1"
    private var hiddenAllDayEvents: Set<String> = []

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
        Color(red: 0.231,     green: 0.510,    blue: 0.965),
        Color(red: 0.28235,   green: 0.85490,  blue: 0.34510),  // #48da58
        Color(red: 1.0,       green: 0.79216,  blue: 0.26667)   // #ffca44
    ]

    init() {
        // ✅ Load persisted appearance first
        if let raw = UserDefaults.standard.string(forKey: themeColorKey),
           let stored = StoredThemeColor(rawValue: raw) {
            self.themeColor = stored.color
        } else {
            self.themeColor = .blue
            UserDefaults.standard.set(StoredThemeColor.blue.rawValue, forKey: themeColorKey)
        }

        if let raw = UserDefaults.standard.string(forKey: appearanceModeKey),
           let mode = AppAppearanceMode(rawValue: raw) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .dark
            UserDefaults.standard.set(AppAppearanceMode.dark.rawValue, forKey: appearanceModeKey)
        }

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

        loadHiddenOccurrences()
        loadHiddenAllDay()
        loadAssumedPrereqs()
        loadEnrollment()
        loadGrades() // ✅ load grades after enrollment so we can prune invalid IDs

        // ✅ Build weekly templates for ALL enrollments (not just currentSemester)
        rebuildEventsFromEnrollment()

        // ✅ Load term bounds for ALL enrollments so calendar auto-switches which classes show by date
        ensureTermBoundsForAllEnrollments()

        // Best-effort: academic year events for currentSemester
        ensureAcademicEventsLoaded(for: currentSemester)
        ensureTermBoundsLoaded(for: currentSemester)
    }

    // MARK: - Public “attempted” helpers (used by CalendarView)

    func didAttemptAcademicEvents(for semester: Semester) -> Bool {
        let ayStart = academicYearStart(for: semester)
        return attemptedAcademicYearStarts.contains(ayStart) || loadedAcademicYearStarts.contains(ayStart)
    }

    func didAttemptTermBounds(for semesterCode: String) -> Bool {
        return attemptedTermBoundsCodes.contains(semesterCode) || termBoundsBySemesterCode[semesterCode] != nil
    }

    // MARK: - Boot/loading overlay control (kept)

    func beginBootLoadingIfNeeded(force: Bool = false) {
        if beganBootLoading && !force { return }
        beganBootLoading = true

        isBootLoading = true
        canSkipBootLoading = false
        updateBootLoadingStatus()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.canSkipBootLoading = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self else { return }
            if self.isBootLoading {
                self.canSkipBootLoading = true
                self.bootLoadingStatusText = "Still loading… (You can continue and it’ll fill in when ready.)"
            }
        }
    }

    func skipBootLoading() {
        isBootLoading = false
    }

    private func updateBootLoadingStatus() {
        let ayStart = academicYearStart(for: currentSemester)
        let code = currentSemester.rawValue

        let didAttemptAcademic = attemptedAcademicYearStarts.contains(ayStart) || loadedAcademicYearStarts.contains(ayStart)
        let didAttemptBounds   = attemptedTermBoundsCodes.contains(code) || termBoundsBySemesterCode[code] != nil

        if !didAttemptAcademic && !didAttemptBounds {
            bootLoadingStatusText = "Fetching academic calendar & term dates…"
        } else if !didAttemptAcademic {
            bootLoadingStatusText = "Fetching academic calendar…"
        } else if !didAttemptBounds {
            bootLoadingStatusText = "Fetching term dates…"
        } else {
            bootLoadingStatusText = "Finalizing…"
        }
    }

    private func refreshBootLoadingStateIfPossible() {
        if !isBootLoading { return }

        let ayStart = academicYearStart(for: currentSemester)
        let code = currentSemester.rawValue

        let didAttemptAcademic = attemptedAcademicYearStarts.contains(ayStart) || loadedAcademicYearStarts.contains(ayStart)
        let didAttemptBounds   = attemptedTermBoundsCodes.contains(code) || termBoundsBySemesterCode[code] != nil

        updateBootLoadingStatus()

        if didAttemptAcademic && didAttemptBounds {
            isBootLoading = false
        }
    }

    // MARK: - Public “ensure loaded”

    func ensureTermBoundsLoaded(for semester: Semester) {
        let code = semester.rawValue
        if termBoundsBySemesterCode[code] != nil { return }

        // ✅ start an attempt immediately (and add a timeout safety)
        if !attemptedTermBoundsCodes.contains(code) {
            attemptedTermBoundsCodes.insert(code)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                self.refreshBootLoadingStateIfPossible()
            }
        }

        AcademicCalendarService.shared.fetchTermBounds(for: semester) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let bounds):
                DispatchQueue.main.async {
                    let interval = DateInterval(start: bounds.start, end: bounds.end)
                    self.termBoundsBySemesterCode[code] = interval
                    self.objectWillChange.send()
                    self.refreshBootLoadingStateIfPossible()
                }
            case .failure(let err):
                print("❌ Failed to load term bounds for \(semester.displayName):", err)
                DispatchQueue.main.async {
                    self.refreshBootLoadingStateIfPossible()
                }
            }
        }
    }

    // ✅ load term bounds for every semester you have enrolled courses in
    func ensureTermBoundsForAllEnrollments() {
        let codes = Set(enrolledCourses.map { $0.semesterCode })
        for c in codes {
            if let sem = Semester(rawValue: c) {
                ensureTermBoundsLoaded(for: sem)
            } else {
                // Unknown code in storage -> don't let it perma-block UI
                attemptedTermBoundsCodes.insert(c)
            }
        }
    }

    func ensureAcademicEventsLoaded(for semester: Semester) {
        let ayStart = academicYearStart(for: semester)
        if loadedAcademicYearStarts.contains(ayStart) { return }

        // ✅ start an attempt immediately (and add a timeout safety)
        if !attemptedAcademicYearStarts.contains(ayStart) {
            attemptedAcademicYearStarts.insert(ayStart)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                self.refreshBootLoadingStateIfPossible()
            }
        }

        AcademicCalendarService.shared.fetchEvents(for: semester) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let evs):
                DispatchQueue.main.async {
                    self.addAcademicEvents(evs)
                    self.loadedAcademicYearStarts.insert(ayStart)
                    self.academicEventsLoaded = true
                    self.refreshBootLoadingStateIfPossible()
                }
            case .failure(let err):
                print("❌ Failed to load academic events for \(semester.displayName):", err)
                DispatchQueue.main.async {
                    self.refreshBootLoadingStateIfPossible()
                }
            }
        }
    }

    // MARK: - Events per day

    func events(on date: Date) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let weekday = calendar.component(.weekday, from: date)

        // quick lookup: enrollmentID -> semesterCode
        let enrollmentSemesterByID: [String: String] = Dictionary(
            uniqueKeysWithValues: enrolledCourses.map { ($0.id, $0.semesterCode) }
        )

        for base in events {
            if base.kind == .classMeeting, let enrollmentID = base.enrollmentID {
                // Template weekly class (only show on matching weekday)
                let baseWeekday = calendar.component(.weekday, from: base.startDate)
                guard baseWeekday == weekday else { continue }

                // Only show this class if date within term bounds
                guard let semCode = enrollmentSemesterByID[enrollmentID],
                      let interval = termBoundsBySemesterCode[semCode] else {
                    continue
                }

                let day = calendar.startOfDay(for: date)
                let s = calendar.startOfDay(for: interval.start)
                let e = calendar.startOfDay(for: interval.end)
                if !(s <= day && day <= e) { continue }

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
                    seriesID: nil,
                    isAllDay: false,
                    kind: .classMeeting
                )

                if hiddenClassOccurrences.contains(copy.interactionKey) { continue }
                result.append(copy)

            } else {
                // Fixed-date (academic or manual)
                if base.isAllDay {
                    if hiddenAllDayEvents.contains(base.interactionKey) { continue }

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

        return result.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay && !$1.isAllDay }
            return $0.startDate < $1.startDate
        }
    }

    // ✅ UPDATED: personal events are now two-tone and brighter by default.
    func addEvent(
        title: String,
        location: String,
        date: Date,
        startTime: Date,
        endTime: Date,
        color: Color = .gray,
        seriesID: UUID? = nil
    ) {
        let start = merge(date: date, time: startTime)
        let end = merge(date: date, time: endTime)

        let bg = lightPalette[2]    // light blue
        let accent = darkPalette[2] // strong blue

        let new = ClassEvent(
            title: title,
            location: location,
            startDate: start,
            endDate: end,
            backgroundColor: bg,
            accentColor: accent,
            enrollmentID: nil,
            seriesID: seriesID,
            isAllDay: false,
            kind: .personal
        )
        events.append(new)
    }

    // ✅ hide all-day event
    func hideAllDayEvent(_ event: ClassEvent) {
        guard event.isAllDay else { return }
        hiddenAllDayEvents.insert(event.interactionKey)
        saveHiddenAllDay()
        objectWillChange.send()
    }

    // ✅ remove manual events
    func removePersonalEvent(_ event: ClassEvent) {
        events.removeAll { $0.id == event.id }
    }

    func removePersonalSeries(seriesID: UUID) {
        events.removeAll { $0.seriesID == seriesID }
    }

    // ✅ hide one class meeting instance
    func hideClassOccurrence(_ event: ClassEvent) {
        guard event.kind == .classMeeting else { return }
        hiddenClassOccurrences.insert(event.interactionKey)
        saveHiddenOccurrences()
        objectWillChange.send()
    }

    // MARK: - Semester switching (Courses tab still uses this)

    func changeSemester(to newSemester: Semester) {
        currentSemester = newSemester
        ensureTermBoundsLoaded(for: newSemester)
        ensureAcademicEventsLoaded(for: newSemester)
        rebuildEventsFromEnrollment()
        updateBootLoadingStatus()
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

    // MARK: - Time conflict detection (TERM-BOUNDS AWARE + CLASSES ONLY)

    private func minutesFromHHMM(_ string: String) -> Int? {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              (0...23).contains(h),
              (0...59).contains(m)
        else { return nil }
        return h * 60 + m
    }

    private func intervalsOverlap(_ a: DateInterval, _ b: DateInterval) -> Bool {
        // inclusive overlap is fine for school terms
        return a.start <= b.end && b.start <= a.end
    }

    /// Which enrolled courses should be considered for conflicts with a new course in `semesterCode`?
    /// - If we know term bounds for both terms: compare only courses whose term bounds overlap.
    /// - If bounds are missing: fall back to same-semester-only (old behavior).
    private func enrollmentsThatOverlapTerm(of semesterCode: String) -> [EnrolledCourse] {
        guard let newInterval = termBoundsBySemesterCode[semesterCode] else {
            // unknown bounds → safest behavior without blocking everything:
            return enrolledCourses.filter { $0.semesterCode == semesterCode }
        }

        return enrolledCourses.filter { existing in
            guard let existingInterval = termBoundsBySemesterCode[existing.semesterCode] else {
                // if existing bounds missing, only treat as overlap when same semester
                return existing.semesterCode == semesterCode
            }
            return intervalsOverlap(newInterval, existingInterval)
        }
    }

    private func hasTimeConflict(for section: CourseSection, semesterCode: String) -> Bool {
        // Make sure we at least kick off loading bounds for this term (async)
        if let sem = Semester(rawValue: semesterCode) {
            ensureTermBoundsLoaded(for: sem)
        }

        // ✅ Only compare against OTHER CLASSES (enrolledCourses), never personal events.
        let existingEnrollments = enrollmentsThatOverlapTerm(of: semesterCode)

        var existingByWeekday: [Int: [(Int, Int)]] = [:]

        for enrollment in existingEnrollments {
            for meeting in enrollment.section.meetings {
                guard let s = minutesFromHHMM(meeting.start),
                      let e = minutesFromHHMM(meeting.end),
                      e > s
                else { continue }

                for d in meeting.days {
                    existingByWeekday[d.calendarWeekday, default: []].append((s, e))
                }
            }
        }

        // Now compare the new section meetings against that map
        for meeting in section.meetings {
            guard let ns = minutesFromHHMM(meeting.start),
                  let ne = minutesFromHHMM(meeting.end),
                  ne > ns
            else { continue }

            for d in meeting.days {
                let list = existingByWeekday[d.calendarWeekday] ?? []
                for (s, e) in list {
                    if ns < e && s < ne {
                        return true
                    }
                }
            }
        }

        return false
    }

    func hasConflict(for course: Course, section: CourseSection) -> Bool {
        hasTimeConflict(for: section, semesterCode: currentSemester.rawValue)
    }

    // MARK: - Prereqs (unchanged)

    private func courseKey(_ course: Course) -> String {
        "\(course.subject)-\(course.number)"
    }

    func prerequisiteCourseIDs(for course: Course) -> [String] {
        let key = courseKey(course)
        let fromGraph = PrereqStore.shared.prereqIDs(for: key)
        if !fromGraph.isEmpty { return fromGraph }

        let texts = course.sections.map { $0.prerequisitesText }.filter { !$0.isEmpty }
        var out: [String] = []
        for t in texts {
            out.append(contentsOf: extractCourseIDs(from: t))
        }
        return Array(Set(out)).sorted()
    }

    private func completedCourseIDs() -> Set<String> {
        var completed: Set<String> = Set(enrolledCourses.map { "\($0.course.subject)-\($0.course.number)" })
        completed.formUnion(Set(assumedBy.keys))
        return completed
    }

    func missingPrerequisites(for course: Course) -> [String] {
        let prereqs = prerequisiteCourseIDs(for: course)
        if prereqs.isEmpty { return [] }

        let completed = completedCourseIDs()
        return prereqs.filter { !completed.contains($0) }
    }

    func prerequisitesDisplayString(for course: Course) -> String? {
        let prereqs = prerequisiteCourseIDs(for: course)
        if !prereqs.isEmpty {
            return prereqs
                .map { $0.replacingOccurrences(of: "-", with: " ") }
                .joined(separator: ", ")
        }

        let texts = course.sections
            .map { $0.prerequisitesText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = texts.first else { return nil }
        return first
    }

    private func extractCourseIDs(from text: String) -> [String] {
        let upper = text.uppercased()

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

        if enrolledCourses.contains(where: { $0.id == id }) { return }

        // ✅ ensure bounds loading is triggered for the target semester
        ensureTermBoundsLoaded(for: currentSemester)

        // ✅ TERM-BOUNDS aware class-only conflict check
        if hasTimeConflict(for: section, semesterCode: currentSemester.rawValue) { return }

        let missing = missingPrerequisites(for: course)
        if !missing.isEmpty {
            assumePrereqs(missing, causedBy: courseKey(course))
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

        ensureTermBoundsForAllEnrollments()
    }

    func removeEnrollment(_ enrollment: EnrolledCourse) {
        // ✅ also remove any saved grade for this enrollment
        clearGrade(for: enrollment.id)

        enrolledCourses.removeAll { $0.id == enrollment.id }
        events.removeAll { $0.enrollmentID == enrollment.id }
        recolorAllEvents()
        saveEnrollment()

        let removedCourseID = "\(enrollment.course.subject)-\(enrollment.course.number)"
        unassumePrereqs(causedBy: removedCourseID)
    }

    // MARK: - Grades (GPA)

    func grade(for enrollmentID: String) -> LetterGrade? {
        guard let raw = gradesByEnrollmentID[enrollmentID] else { return nil }
        return LetterGrade(rawValue: raw)
    }

    func setGrade(_ grade: LetterGrade, for enrollmentID: String) {
        gradesByEnrollmentID[enrollmentID] = grade.rawValue
        saveGrades()
        objectWillChange.send()
    }

    func clearGrade(for enrollmentID: String) {
        gradesByEnrollmentID.removeValue(forKey: enrollmentID)
        saveGrades()
        objectWillChange.send()
    }

    /// Term GPA (unweighted): average of assigned grade points for enrollments in that semesterCode.
    func gpa(for semesterCode: String) -> Double? {
        let entries = enrolledCourses
            .filter { $0.semesterCode == semesterCode }
            .compactMap { e -> (LetterGrade, Double)? in
                guard let g = grade(for: e.id) else { return nil }
                return (g, e.section.credits)
            }

        return GPACalculator.weightedGPA(entries)
    }

    func overallGPA() -> Double? {
        let entries = enrolledCourses.compactMap { e -> (LetterGrade, Double)? in
            guard let g = grade(for: e.id) else { return nil }
            return (g, e.section.credits)
        }

        return GPACalculator.weightedGPA(entries)
    }

    private func saveGrades() {
        UserDefaults.standard.set(gradesByEnrollmentID, forKey: gradesStorageKey)
    }

    private func loadGrades() {
        if let dict = UserDefaults.standard.dictionary(forKey: gradesStorageKey) as? [String: String] {
            gradesByEnrollmentID = dict
        } else {
            gradesByEnrollmentID = [:]
        }

        // Drop grades for enrollments that no longer exist
        let validIDs = Set(enrolledCourses.map { $0.id })
        gradesByEnrollmentID = gradesByEnrollmentID.filter { validIDs.contains($0.key) }
    }

    // MARK: - Assumed prereqs (unchanged)

    private func assumePrereqs(_ prereqIDs: [String], causedBy courseID: String) {
        var changed = false
        let expanded = expandTransitivePrereqs(prereqIDs)

        for p in expanded {
            var reasons = assumedBy[p] ?? []
            if !reasons.contains(courseID) {
                reasons.insert(courseID)
                assumedBy[p] = reasons
                changed = true
            }
        }

        if changed {
            saveAssumedPrereqs()
            objectWillChange.send()
        }
    }

    private func unassumePrereqs(causedBy courseID: String) {
        var changed = false
        var toRemove: [String] = []

        for (assumedCourse, reasons) in assumedBy {
            var r = reasons
            if r.contains(courseID) {
                r.remove(courseID)
                if r.isEmpty {
                    toRemove.append(assumedCourse)
                } else {
                    assumedBy[assumedCourse] = r
                }
                changed = true
            }
        }

        for k in toRemove { assumedBy.removeValue(forKey: k) }

        if changed {
            saveAssumedPrereqs()
            objectWillChange.send()
        }
    }

    private func expandTransitivePrereqs(_ prereqIDs: [String]) -> [String] {
        var out: Set<String> = []
        var stack: [String] = prereqIDs
        var seen: Set<String> = []

        while let cur = stack.popLast() {
            if seen.contains(cur) { continue }
            seen.insert(cur)
            out.insert(cur)

            let next = PrereqStore.shared.prereqIDs(for: cur)
            for n in next where !seen.contains(n) { stack.append(n) }
        }

        return Array(out).sorted()
    }

    private func saveAssumedPrereqs() {
        let dict: [String: [String]] = assumedBy.mapValues { Array($0).sorted() }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            UserDefaults.standard.set(data, forKey: assumedPrereqsStorageKey)
        }
    }

    private func loadAssumedPrereqs() {
        guard let data = UserDefaults.standard.data(forKey: assumedPrereqsStorageKey) else {
            assumedBy = [:]
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let dict = obj as? [String: [String]] {
                var out: [String: Set<String>] = [:]
                for (k, v) in dict { out[k] = Set(v) }
                assumedBy = out
            } else {
                assumedBy = [:]
            }
        } catch {
            assumedBy = [:]
        }
    }

    // MARK: - Academic events

    func addAcademicEvents(_ academicEvents: [AcademicEvent]) {
        for ev in academicEvents {
            let key = "\(ev.title)|\(ev.startDate.timeIntervalSince1970)|\(ev.endDate.timeIntervalSince1970)|\(ev.kind.rawValue)"
            if academicEventKeys.contains(key) { continue }
            academicEventKeys.insert(key)

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
                seriesID: nil,
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
            seriesID: nil,
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

    private func rebuildEventsFromEnrollment() {
        let fixed = events.filter { $0.enrollmentID == nil }  // keep manual + academic
        events = fixed

        for enrollment in enrolledCourses {
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

    // MARK: - Academic year helper

    private func academicYearStart(for semester: Semester) -> Int {
        let year = semester.year
        return semester.isFall ? year : (year - 1)
    }

    // MARK: - Hidden occurrences persistence

    private func saveHiddenOccurrences() {
        let arr = Array(hiddenClassOccurrences)
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: []) {
            UserDefaults.standard.set(data, forKey: hiddenOccurrencesKey)
        }
    }

    private func loadHiddenOccurrences() {
        guard let data = UserDefaults.standard.data(forKey: hiddenOccurrencesKey) else {
            hiddenClassOccurrences = []
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let arr = obj as? [String] {
                hiddenClassOccurrences = Set(arr)
            } else {
                hiddenClassOccurrences = []
            }
        } catch {
            hiddenClassOccurrences = []
        }
    }

    // MARK: - Hidden all-day persistence

    private func saveHiddenAllDay() {
        let arr = Array(hiddenAllDayEvents)
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: []) {
            UserDefaults.standard.set(data, forKey: hiddenAllDayKey)
        }
    }

    private func loadHiddenAllDay() {
        guard let data = UserDefaults.standard.data(forKey: hiddenAllDayKey) else {
            hiddenAllDayEvents = []
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let arr = obj as? [String] {
                hiddenAllDayEvents = Set(arr)
            } else {
                hiddenAllDayEvents = []
            }
        } catch {
            hiddenAllDayEvents = []
        }
    }
}

// MARK: - Semester helpers (file-local)

private extension Semester {
    var year: Int { Int(rawValue.prefix(4)) ?? Calendar.current.component(.year, from: Date()) }
    var month: Int { Int(rawValue.suffix(2)) ?? 1 }
    var isFall: Bool { month == 9 }
    var isSpring: Bool { month == 1 }
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
