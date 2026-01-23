//
// CalendarViewModel.swift
// RPI Central
//

import Foundation
import SwiftUI
import WidgetKit

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

// MARK: - Meeting Overrides + Exam Dates (support CourseDetailView)

struct MeetingOverride: Codable, Equatable {
    var type: MeetingBlockType
}

final class CalendarViewModel: ObservableObject {
    @Published var displayedMonthStart: Date
    @Published var selectedDate: Date

    // ✅ publish widgets when schedule changes
    @Published var events: [ClassEvent] {
        didSet {
            guard !suppressWidgetPublishes else { return }
            scheduleWidgetSnapshotPublish()
        }
    }

    // ✅ publish widgets when enrollments change
    @Published var enrolledCourses: [EnrolledCourse] = [] {
        didSet {
            guard !suppressWidgetPublishes else { return }
            scheduleWidgetSnapshotPublish()
        }
    }

    // default is now spring2026
    @Published var currentSemester: Semester = .spring2026

    @Published private(set) var semesterWindow: [Semester] = []

    // MARK: - Persisted appearance settings

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
    private let notificationsEnabledKey = "settings_notifications_enabled_v1"
    private let minutesBeforeClassKey   = "settings_minutes_before_class_v1"

    @Published var themeColor: Color = .blue {
        didSet {
            let stored = StoredThemeColor.from(color: themeColor)
            UserDefaults.standard.set(stored.rawValue, forKey: themeColorKey)
        }
    }

    @Published var appearanceMode: AppAppearanceMode = .dark {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceModeKey)
        }
    }
    @Published var notificationsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: notificationsEnabledKey)
            applyNotificationScheduling()
        }
    }

    @Published var minutesBeforeClass: Int = 10 {
        didSet {
            UserDefaults.standard.set(minutesBeforeClass, forKey: minutesBeforeClassKey)
            applyNotificationScheduling()
        }
    }

    @Published private(set) var academicEventsLoaded: Bool = false
    @Published private(set) var termBoundsBySemesterCode: [String: DateInterval] = [:]

    @Published var isBootLoading: Bool = true
    @Published var canSkipBootLoading: Bool = false
    @Published var bootLoadingStatusText: String = "Loading calendar…"

    @Published var enforcePrerequisites: Bool = false {
        didSet {
            UserDefaults.standard.set(enforcePrerequisites, forKey: enforcePrereqsKey)
        }
    }
    
    //Notifcation shit
    private func applyNotificationScheduling() {
        // if disabled, wipe pending requests
        if !notificationsEnabled {
            NotificationManager.clearScheduledNotifications()
            return
        }

        NotificationManager.requestAuthorization()

        // reschedule everything
        NotificationManager.clearScheduledNotifications()

        // schedule reminders for all class meetings you currently have loaded
        let classMeetings = events.filter { !$0.isAllDay && $0.kind == .classMeeting }
        for ev in classMeetings {
            NotificationManager.scheduleNotification(for: ev, minutesBefore: minutesBeforeClass)
        }

        #if DEBUG
        print("🔔 Rescheduled notifications:", classMeetings.count, "events", "lead:", minutesBeforeClass)
        #endif
    }

    // MARK: - GPA / Grades (per enrollment)

    @Published private(set) var gradesByEnrollmentID: [String: String] = [:]
    private let gradesStorageKey = "enrollment_grades_v1"

    // MARK: - Meeting overrides + exam dates storage

    // meetingKey -> override
    @Published private(set) var meetingOverridesByKey: [String: MeetingOverride] = [:]
    private let meetingOverridesStorageKey = "meeting_overrides_v2"

    // meetingKey -> [timeIntervalSince1970 (startOfDay)]
    @Published private(set) var examDatesByMeetingKey: [String: [Double]] = [:]
    private let examDatesStorageKey = "exam_dates_by_meeting_key_v2"

    private let calendar = Calendar.current

    private let weekStartDate: Date
    private let weekEndDate: Date

    private let enrolledStorageKey = "enrolled_courses_v1"
    private let enforcePrereqsKey  = "enforce_prereqs_v1"

    private let assumedPrereqsStorageKey = "assumed_prereqs_v1"
    private var assumedBy: [String: Set<String>] = [:]

    private var loadedAcademicYearStarts: Set<Int> = []
    private var attemptedAcademicYearStarts: Set<Int> = []
    private var attemptedTermBoundsCodes: Set<String> = []
    private var beganBootLoading: Bool = false

    private var academicEventKeys: Set<String> = []

    private let hiddenOccurrencesKey = "hidden_class_occurrences_v1"
    private var hiddenClassOccurrences: Set<String> = []

    private let hiddenAllDayKey = "hidden_all_day_events_v1"
    private var hiddenAllDayEvents: Set<String> = []

    private let lightPalette: [Color] = [
        Color(red: 1.0,       green: 0.83529,  blue: 0.87451),
        Color(red: 1.0,       green: 0.91373,  blue: 0.80784),
        Color(red: 0.81176,   green: 0.93725,  blue: 0.98824),
        Color(red: 0.85490,   green: 0.96863,  blue: 0.85882),
        Color(red: 1.0,       green: 0.95686,  blue: 0.81569)
    ]

    private let darkPalette: [Color] = [
        Color(red: 0.99608,   green: 0.13725,  blue: 0.4),
        Color(red: 1.0,       green: 0.58039,  blue: 0.19608),
        Color(red: 0.231,     green: 0.510,    blue: 0.965),
        Color(red: 0.28235,   green: 0.85490,  blue: 0.34510),
        Color(red: 1.0,       green: 0.79216,  blue: 0.26667)
    ]

    // MARK: - Widget publish suppression (bulk updates)
    private var suppressWidgetPublishes: Bool = false

    private func withWidgetPublishingSuppressed(_ body: () -> Void) {
        let wasSuppressed = suppressWidgetPublishes
        suppressWidgetPublishes = true
        body()
        suppressWidgetPublishes = wasSuppressed

        // Outer-most bulk update: coalesce to one publish
        if !wasSuppressed {
            scheduleWidgetSnapshotPublish()
        }
    }

    init() {
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
        // ✅ load persisted notification settings
        if UserDefaults.standard.object(forKey: notificationsEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: notificationsEnabledKey)
        }
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: notificationsEnabledKey)

        let savedMinutes = UserDefaults.standard.integer(forKey: minutesBeforeClassKey)
        self.minutesBeforeClass = savedMinutes == 0 ? 10 : savedMinutes

        // Avoid widget spam during boot rebuild
        withWidgetPublishingSuppressed {
            loadHiddenOccurrences()
            loadHiddenAllDay()
            loadAssumedPrereqs()
            loadEnrollment()
            loadGrades()

            // NEW: load meeting overrides + exam dates
            loadMeetingOverrides()
            loadExamDates()

            rebuildEventsFromEnrollment()
            ensureTermBoundsForAllEnrollments()
            refreshSemesterWindow(anchorPreferred: nil)
        }

        ensureAcademicEventsLoaded(for: currentSemester)
        ensureTermBoundsLoaded(for: currentSemester)

        // ✅ initial publish (coalesced; won’t re-fire during boot rebuild)
        publishWidgetSnapshot()
        applyNotificationScheduling()
    }

    // MARK: - Widgets (AppGroup snapshot publishing)

    private let widgetKindsToReload: [String] = [
        "RPICentralMonthWidget",
        "RPICentralMonthAndTodayWidget"
    ]


    private func widgetPriority(_ kind: CalendarEventKind) -> Int {
        switch kind {
        case .break:         return 0
        case .holiday:       return 1
        case .readingDays:   return 2
        case .finals:        return 3
        case .noClasses:     return 4
        case .followDay:     return 5
        case .academicOther: return 6
        default:             return 9
        }
    }

    /// Identical ordering to MonthGridView.dotColorsForDayEvents, but returns RGBA for widget.
    private func widgetDotColorsForDayEvents(_ events: [ClassEvent]) -> [RGBAColor] {
        var colors: [Color] = []

        let academic = events
            .filter { $0.isAllDay }
            .sorted { widgetPriority($0.kind) < widgetPriority($1.kind) }

        let classes = events
            .filter { !$0.isAllDay && $0.kind == .classMeeting }

        let personal = events
            .filter { !$0.isAllDay && $0.kind == .personal }

        for e in academic { colors.append(e.displayColor) }
        for e in classes  { colors.append(e.displayColor) }
        for e in personal { colors.append(e.displayColor) }

        var unique: [RGBAColor] = []
        unique.reserveCapacity(3)

        for c in colors {
            let rgba = RGBAColor.from(c)
            if !unique.contains(rgba) {
                unique.append(rgba)
                if unique.count >= 3 { break }
            }
        }
        return unique
    }

    private var widgetPublishWorkItem: DispatchWorkItem?

    private var lastWidgetReloadAt: Date = .distantPast

    // ✅ Increase this to stop “Attach to widgets” memory-kill loops.
    private let widgetReloadMinInterval: TimeInterval = 30.0

    private func scheduleWidgetSnapshotPublish() {
        widgetPublishWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.publishWidgetSnapshot()
        }
        widgetPublishWorkItem = work

        // ✅ Coalesce harder to reduce reload spam while user edits calendar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Widget-safe variant: DO NOT require term bounds to exist.
    /// (If bounds exist, we still respect them; if not, we allow events so dots show.)
    private func eventsForWidget(on date: Date) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let weekday = calendar.component(.weekday, from: date)
        let dayStart = calendar.startOfDay(for: date)

        let enrollmentSemesterByID: [String: String] = Dictionary(
            uniqueKeysWithValues: enrolledCourses.map { ($0.id, $0.semesterCode) }
        )

        for base in events {
            if let k = base.meetingKey {
                let nk = normalizeMeetingKey(k)

                print("READ event meetingKey RAW:", k)
                print("READ event meetingKey NORM:", nk)
                print("READ override exists:", meetingOverridesByKey.keys.contains(nk))
                print("READ examDates exists:", examDatesByMeetingKey.keys.contains(nk))
            }
            if base.kind == .classMeeting, let enrollmentID = base.enrollmentID {
                let baseWeekday = calendar.component(.weekday, from: base.startDate)
                guard baseWeekday == weekday else { continue }

                // ✅ If term bounds exist, respect them; if missing, allow (so widget gets dots immediately)
                if let semCode = enrollmentSemesterByID[enrollmentID],
                   let interval = termBoundsBySemesterCode[semCode] {
                    let s = calendar.startOfDay(for: interval.start)
                    let e = calendar.startOfDay(for: interval.end)
                    if !(s <= dayStart && dayStart <= e) { continue }
                }

                // meeting overrides/exam dates (same as events(on:))
                if let key = base.meetingKey {
                    let ov = meetingOverride(for: key)

                    if ov.type == .disabled { continue }

                    if ov.type == .exam {
                        let allowedDays = Set((examDatesByMeetingKey[key] ?? []).map {
                            calendar.startOfDay(for: Date(timeIntervalSince1970: $0))
                        })
                        if !allowedDays.contains(dayStart) { continue }
                    }
                }

                // build the instance on this date (same as events(on:))
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

                guard let newStart = calendar.date(from: startComps),
                      let newEnd   = calendar.date(from: endComps)
                else { continue }

                var title = base.title
                if let key = base.meetingKey {
                    if meetingOverride(for: key).type == .exam {
                        title = "★ \(title)"
                    }
                }

                let copy = ClassEvent(
                    title: title,
                    location: base.location,
                    startDate: newStart,
                    endDate: newEnd,
                    backgroundColor: base.backgroundColor,
                    accentColor: base.accentColor,
                    enrollmentID: base.enrollmentID,
                    seriesID: nil,
                    isAllDay: false,
                    kind: .classMeeting,
                    meetingKey: base.meetingKey.map(normalizeMeetingKey)
                )

                if hiddenClassOccurrences.contains(copy.interactionKey) { continue }
                result.append(copy)

            } else {
                // fixed-date (same as events(on:))
                if base.isAllDay {
                    if hiddenAllDayEvents.contains(base.interactionKey) { continue }
                    let d = dayStart
                    let s = calendar.startOfDay(for: base.startDate)
                    let e = calendar.startOfDay(for: base.endDate)
                    if s <= d && d <= e { result.append(base) }
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

    private func publishWidgetSnapshot() {
        guard let defaults = UserDefaults(suiteName: RPICentralWidgetShared.appGroup) else { return }

        let now = Date()

        let theme: RPICentralWidgetTheme = {
            if themeColor == .red { return .red }
            if themeColor == .green { return .green }
            if themeColor == .purple { return .purple }
            if themeColor == .orange { return .orange }
            return .blue
        }()

        let appearance: RPICentralWidgetAppearance = {
            switch appearanceMode {
            case .system: return .system
            case .light:  return .light
            case .dark:   return .dark
            }
        }()

        let todayEventsApp = eventsForWidget(on: now)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay && !$1.isAllDay }
                return $0.startDate < $1.startDate
            }
            .prefix(12)

        let todayEvents: [WidgetDayEvent] = todayEventsApp.map { e in
            var badge: String? = nil
            if e.kind == .classMeeting, let key = e.meetingKey {
                switch meetingOverride(for: key).type {
                case .exam: badge = "exam"
                case .recitation: badge = "recitation"
                default: badge = nil
                }
            }

            return WidgetDayEvent(
                id: e.id.uuidString,
                title: e.title,
                location: e.location,
                startDate: e.startDate,
                endDate: e.endDate,
                isAllDay: e.isAllDay,
                background: RGBAColor.from(e.backgroundColor),
                accent: RGBAColor.from(e.accentColor),
                badge: badge
            )
        }

        let monthStart = now.startOfMonth(using: calendar)
        let snapYear = calendar.component(.year, from: monthStart)
        let snapMonth = calendar.component(.month, from: monthStart)

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        let nowYear = calendar.component(.year, from: now)
        let nowMonth = calendar.component(.month, from: now)
        let todayDay: Int? = (nowYear == snapYear && nowMonth == snapMonth) ? calendar.component(.day, from: now) : nil

        var markers: [DayMarker] = []
        markers.reserveCapacity(daysInMonth)

        for day in 1...daysInMonth {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let dayEvents = eventsForWidget(on: date)

            let isBreakDay = dayEvents.contains { $0.isAllDay && $0.kind == .break }

            let hasExam = dayEvents.contains(where: { ev in
                if ev.kind == .classMeeting, let key = ev.meetingKey {
                    return meetingOverride(for: key).type == .exam
                }
                return ev.title.hasPrefix("★")
            })

            let dots = widgetDotColorsForDayEvents(dayEvents)
            markers.append(DayMarker(day: day, dotColors: dots, hasExam: hasExam, isBreakDay: isBreakDay))
        }

        let month = MonthSnapshot(
            year: snapYear,
            month: snapMonth,
            firstWeekday: firstWeekday,
            daysInMonth: daysInMonth,
            todayDay: todayDay,
            markers: markers
        )

        let snapshot = WidgetSnapshot(
            generatedAt: now,
            theme: theme,
            appearance: appearance,
            todayEvents: todayEvents,
            month: month
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            defaults.set(data, forKey: RPICentralWidgetShared.snapshotKey)
            defaults.set("wrote snapshot at \(now)", forKey: RPICentralWidgetShared.debugKey)

            #if DEBUG
            let readBack = defaults.data(forKey: RPICentralWidgetShared.snapshotKey)
            print("📦 Widget snapshot write bytes:", data.count, "readBack:", readBack?.count ?? -1)
            #endif

            // ✅ throttle reload spam (fix attach crash/hang)
            let t = Date()
            if t.timeIntervalSince(lastWidgetReloadAt) > widgetReloadMinInterval {
                lastWidgetReloadAt = t
                for kind in widgetKindsToReload {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            }
        } catch {
            // ignore
        }
    }

    // MARK: - Meeting override keys + API (matches CourseDetailView)

    func meetingOverrideKey(enrollmentID: String, course: Course, section: CourseSection, meeting: Meeting) -> String {
        let days = meeting.days.map { "\($0.calendarWeekday)" }.joined(separator: ",")
        let loc = meeting.location
        return "\(enrollmentID)|\(days)|\(meeting.start)-\(meeting.end)"
    }

    func meetingOverride(for key: String) -> MeetingOverride {
        let k = normalizeMeetingKey(key)
        return meetingOverridesByKey[k] ?? MeetingOverride(type: .lecture)
    }

    func setMeetingOverrideType(_ newType: MeetingBlockType, for key: String) {
        let k = normalizeMeetingKey(key)

        meetingOverridesByKey[k] = MeetingOverride(type: newType)
        saveMeetingOverrides()

        // ✅ If user changes away from Exam, wipe stored exam dates for this key.
        if newType != .exam {
            examDatesByMeetingKey.removeValue(forKey: k)
            saveExamDates()
        }

        objectWillChange.send()
        scheduleWidgetSnapshotPublish()
    }

    func examDates(for key: String) -> [Date] {
        let k = normalizeMeetingKey(key)
        let raws = examDatesByMeetingKey[k] ?? []
        return raws
            .map { Date(timeIntervalSince1970: $0) }
            .sorted()
    }

    func setExamDates(_ dates: Set<Date>, for key: String) {
        let k = normalizeMeetingKey(key)

        // Normalize to startOfDay timestamps
        let normalized: [Double] = Array(Set(dates.map {
            calendar.startOfDay(for: $0).timeIntervalSince1970
        })).sorted()

        if normalized.isEmpty {
            // ✅ removing all dates = "delete exam"
            examDatesByMeetingKey.removeValue(forKey: k)
            saveExamDates()

            // ✅ IMPORTANT: if it's currently an exam block, revert it to normal
            if meetingOverridesByKey[k]?.type == .exam {
                meetingOverridesByKey.removeValue(forKey: k) // back to default = lecture
                saveMeetingOverrides()
            }
        } else {
            examDatesByMeetingKey[k] = normalized
            saveExamDates()

            // ensure it's marked as exam if dates exist
            meetingOverridesByKey[k] = MeetingOverride(type: .exam)
            saveMeetingOverrides()
        }

        objectWillChange.send()
        scheduleWidgetSnapshotPublish()
    }

    // For class template instances: find the matching meeting key from the enrolledCourse meeting list.
    private func meetingKeyForTemplateEvent(enrollment: EnrolledCourse, templateStartDate: Date, templateEndDate: Date, templateLocation: String) -> String? {
        let wd = calendar.component(.weekday, from: templateStartDate)

        // extract meeting.location from templateLocation (best-effort)
        // Format you build: "SUBJ NUM · <meeting.location> · CRN XXXX" OR "SUBJ NUM · CRN XXXX"
        var extractedMeetingLoc = ""
        let parts = templateLocation.components(separatedBy: " · ")
        if parts.count >= 3 {
            extractedMeetingLoc = parts[1]
        } else {
            extractedMeetingLoc = ""
        }

        let startStr = hhmm(from: templateStartDate)
        let endStr = hhmm(from: templateEndDate)

        // pick the meeting whose time matches and includes this weekday and location matches (if available)
        for m in enrollment.section.meetings {
            guard m.start == startStr, m.end == endStr else { continue }
            guard m.days.contains(where: { $0.calendarWeekday == wd }) else { continue }

            // if enrollment meeting has a location, require it; otherwise accept blank extracted
            if !m.location.isEmpty && m.location != extractedMeetingLoc { continue }

            return meetingOverrideKey(enrollmentID: enrollment.id, course: enrollment.course, section: enrollment.section, meeting: m)
        }

        // fallback: allow a looser match ignoring location
        for m in enrollment.section.meetings {
            guard m.start == startStr, m.end == endStr else { continue }
            guard m.days.contains(where: { $0.calendarWeekday == wd }) else { continue }
            return meetingOverrideKey(enrollmentID: enrollment.id, course: enrollment.course, section: enrollment.section, meeting: m)
        }

        return nil
    }

    private func hhmm(from date: Date) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        return String(format: "%d:%02d", h, m)
    }

    // MARK: - Semester windowing

    private func refreshSemesterWindow(anchorPreferred: Semester?) {
        let anchor: Semester = {
            if let pref = anchorPreferred { return pref }
            if let sem = semesterContaining(date: selectedDate) { return sem }
            return currentSemester
        }()

        let window = [anchor.previousSemester, anchor, anchor.nextSemester].compactMap { $0 }
        semesterWindow = window

        if currentSemester != anchor {
            currentSemester = anchor
        }

        for sem in window {
            ensureTermBoundsLoaded(for: sem)
            ensureAcademicEventsLoaded(for: sem)
        }
    }

    private func semesterContaining(date: Date) -> Semester? {
        for (code, interval) in termBoundsBySemesterCode {
            guard let sem = Semester(rawValue: code) else { continue }
            let d = calendar.startOfDay(for: date)
            let s = calendar.startOfDay(for: interval.start)
            let e = calendar.startOfDay(for: interval.end)
            if s <= d && d <= e { return sem }
        }
        return nil
    }

    func monthPickerMonthStarts() -> [Date] {
        let cal = calendar

        let intervals: [DateInterval] = semesterWindow.compactMap { sem in
            termBoundsBySemesterCode[sem.rawValue]
        }

        if let minStart = intervals.map(\.start).min(),
           let maxEnd = intervals.map(\.end).max() {
            let startMonth = minStart.startOfMonth(using: cal)
            let endMonth = maxEnd.startOfMonth(using: cal)

            var out: [Date] = []
            var cur = startMonth
            while cur <= endMonth {
                out.append(cur)
                guard let next = cal.date(byAdding: .month, value: 1, to: cur) else { break }
                cur = next
            }
            return out
        }

        let start = (cal.date(byAdding: .month, value: -12, to: selectedDate) ?? selectedDate).startOfMonth(using: cal)
        let end = (cal.date(byAdding: .month, value:  12, to: selectedDate) ?? selectedDate).startOfMonth(using: cal)

        var out: [Date] = []
        var cur = start
        while cur <= end {
            out.append(cur)
            guard let next = cal.date(byAdding: .month, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    // MARK: - Public attempted helpers

    func didAttemptAcademicEvents(for semester: Semester) -> Bool {
        let ayStart = academicYearStart(for: semester)
        return attemptedAcademicYearStarts.contains(ayStart) || loadedAcademicYearStarts.contains(ayStart)
    }

    func didAttemptTermBounds(for semesterCode: String) -> Bool {
        attemptedTermBoundsCodes.contains(semesterCode) || termBoundsBySemesterCode[semesterCode] != nil
    }

    // MARK: - Public selection helpers

    func goToToday() {
        let today = Date()
        selectedDate = today
        displayedMonthStart = today.startOfMonth(using: calendar)
        refreshSemesterWindow(anchorPreferred: nil)
    }

    func setSelectedDate(_ date: Date) {
        selectedDate = date
        displayedMonthStart = date.startOfMonth(using: calendar)
        refreshSemesterWindow(anchorPreferred: nil)
    }

    // MARK: - Boot overlay control

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

    func skipBootLoading() { isBootLoading = false }

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

    // MARK: - Ensure loaded

    func ensureTermBoundsLoaded(for semester: Semester) {
        let code = semester.rawValue
        if termBoundsBySemesterCode[code] != nil { return }

        if !attemptedTermBoundsCodes.contains(code) {
            attemptedTermBoundsCodes.insert(code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.refreshBootLoadingStateIfPossible()
            }
        }

        AcademicCalendarService.shared.fetchTermBounds(for: semester) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let bounds):
                DispatchQueue.main.async {
                    self.termBoundsBySemesterCode[code] = DateInterval(start: bounds.start, end: bounds.end)
                    self.objectWillChange.send()
                    self.refreshSemesterWindow(anchorPreferred: nil)
                    self.refreshBootLoadingStateIfPossible()
                    self.scheduleWidgetSnapshotPublish() // ✅ term gating can change widget "up next"
                }
            case .failure(let err):
                print("❌ Failed to load term bounds for \(semester.displayName):", err)
                DispatchQueue.main.async { self.refreshBootLoadingStateIfPossible() }
            }
        }
    }

    func ensureTermBoundsForAllEnrollments() {
        let codes = Set(enrolledCourses.map { $0.semesterCode })
        for c in codes {
            if let sem = Semester(rawValue: c) {
                ensureTermBoundsLoaded(for: sem)
            } else {
                attemptedTermBoundsCodes.insert(c)
            }
        }
    }

    func ensureAcademicEventsLoaded(for semester: Semester) {
        let ayStart = academicYearStart(for: semester)
        if loadedAcademicYearStarts.contains(ayStart) { return }

        if !attemptedAcademicYearStarts.contains(ayStart) {
            attemptedAcademicYearStarts.insert(ayStart)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.refreshBootLoadingStateIfPossible()
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
                    self.scheduleWidgetSnapshotPublish()
                }
            case .failure(let err):
                print("❌ Failed to load academic events for \(semester.displayName):", err)
                DispatchQueue.main.async { self.refreshBootLoadingStateIfPossible() }
            }
        }
    }

    // MARK: - Events per day (UPDATED for meeting overrides + exam dates)

    func events(on date: Date) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let weekday = calendar.component(.weekday, from: date)
        let dayStart = calendar.startOfDay(for: date)

        let enrollmentByID: [String: EnrolledCourse] = Dictionary(
            uniqueKeysWithValues: enrolledCourses.map { ($0.id, $0) }
        )

        let enrollmentSemesterByID: [String: String] = Dictionary(
            uniqueKeysWithValues: enrolledCourses.map { ($0.id, $0.semesterCode) }
        )

        for base in events {
            if base.kind == .classMeeting, let enrollmentID = base.enrollmentID {
                // weekly templates only show on matching weekday
                let baseWeekday = calendar.component(.weekday, from: base.startDate)
                guard baseWeekday == weekday else { continue }

                // term bounds gate
                guard let semCode = enrollmentSemesterByID[enrollmentID],
                      let interval = termBoundsBySemesterCode[semCode] else { continue }

                let s = calendar.startOfDay(for: interval.start)
                let e = calendar.startOfDay(for: interval.end)
                if !(s <= dayStart && dayStart <= e) { continue }

                // ✅ meeting override lookup (reliable)
                let key: String? = base.meetingKey

                if let key {
                    let ov = meetingOverride(for: key)

                    if ov.type == .disabled {
                        continue
                    }

                    if ov.type == .exam {
                        let nk = normalizeMeetingKey(key)

                        let allowedDays = Set((examDatesByMeetingKey[nk] ?? []).map {
                            calendar.startOfDay(for: Date(timeIntervalSince1970: $0))
                        })

                        if !allowedDays.contains(dayStart) { continue }
                    }
                }

                // build the instance on this date
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

                guard let newStart = calendar.date(from: startComps),
                      let newEnd   = calendar.date(from: endComps)
                else { continue }

                var title = base.title
                if let key {
                    let ov = meetingOverride(for: key)
                    if ov.type == .exam {
                        title = "★ \(title)"
                    }
                }

                let copy = ClassEvent(
                    title: title,
                    location: base.location,
                    startDate: newStart,
                    endDate: newEnd,
                    backgroundColor: base.backgroundColor,
                    accentColor: base.accentColor,
                    enrollmentID: base.enrollmentID,
                    seriesID: nil,
                    isAllDay: false,
                    kind: .classMeeting,
                    meetingKey: base.meetingKey.map(normalizeMeetingKey)
                )

                if hiddenClassOccurrences.contains(copy.interactionKey) { continue }
                result.append(copy)

            } else {
                // fixed-date
                if base.isAllDay {
                    if hiddenAllDayEvents.contains(base.interactionKey) { continue }
                    let d = dayStart
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

    // MARK: - Personal events

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

        let bg = lightPalette[2]
        let accent = darkPalette[2]

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

    func hideAllDayEvent(_ event: ClassEvent) {
        guard event.isAllDay else { return }
        hiddenAllDayEvents.insert(event.interactionKey)
        saveHiddenAllDay()
        objectWillChange.send()
        scheduleWidgetSnapshotPublish()
    }

    func removePersonalEvent(_ event: ClassEvent) {
        events.removeAll { $0.id == event.id }
    }

    func removePersonalSeries(seriesID: UUID) {
        events.removeAll { $0.seriesID == seriesID }
    }

    func hideClassOccurrence(_ event: ClassEvent) {
        guard event.kind == .classMeeting else { return }
        hiddenClassOccurrences.insert(event.interactionKey)
        saveHiddenOccurrences()
        objectWillChange.send()
        scheduleWidgetSnapshotPublish()
    }

    // MARK: - Semester switching

    func changeSemester(to newSemester: Semester) {
        currentSemester = newSemester
        ensureTermBoundsLoaded(for: newSemester)
        ensureAcademicEventsLoaded(for: newSemester)
        rebuildEventsFromEnrollment()
        updateBootLoadingStatus()
        refreshSemesterWindow(anchorPreferred: newSemester)
        scheduleWidgetSnapshotPublish()
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

    // MARK: - Time conflict detection (unchanged)

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
        a.start <= b.end && b.start <= a.end
    }

    private func enrollmentsThatOverlapTerm(of semesterCode: String) -> [EnrolledCourse] {
        guard let newInterval = termBoundsBySemesterCode[semesterCode] else {
            return enrolledCourses.filter { $0.semesterCode == semesterCode }
        }

        return enrolledCourses.filter { existing in
            guard let existingInterval = termBoundsBySemesterCode[existing.semesterCode] else {
                return existing.semesterCode == semesterCode
            }
            return intervalsOverlap(newInterval, existingInterval)
        }
    }

    private func hasTimeConflict(for section: CourseSection, semesterCode: String) -> Bool {
        if let sem = Semester(rawValue: semesterCode) { ensureTermBoundsLoaded(for: sem) }

        let existingEnrollments = enrollmentsThatOverlapTerm(of: semesterCode)
        var existingByWeekday: [Int: [(Int, Int)]] = [:]

        for enrollment in existingEnrollments {
            for meeting in enrollment.section.meetings {
                guard let s = minutesFromHHMM(meeting.start),
                      let e = minutesFromHHMM(meeting.end),
                      e > s else { continue }

                for d in meeting.days {
                    existingByWeekday[d.calendarWeekday, default: []].append((s, e))
                }
            }
        }

        for meeting in section.meetings {
            guard let ns = minutesFromHHMM(meeting.start),
                  let ne = minutesFromHHMM(meeting.end),
                  ne > ns else { continue }

            for d in meeting.days {
                let list = existingByWeekday[d.calendarWeekday] ?? []
                for (s, e) in list {
                    if ns < e && s < ne { return true }
                }
            }
        }

        return false
    }

    func hasConflict(for course: Course, section: CourseSection) -> Bool {
        hasTimeConflict(for: section, semesterCode: currentSemester.rawValue)
    }

    // MARK: - Prereqs (unchanged)

    private func courseKey(_ course: Course) -> String { "\(course.subject)-\(course.number)" }

    func prerequisiteCourseIDs(for course: Course) -> [String] {
        let key = courseKey(course)
        let fromGraph = PrereqStore.shared.prereqIDs(for: key)
        if !fromGraph.isEmpty { return fromGraph }

        let texts = course.sections.map { $0.prerequisitesText }.filter { !$0.isEmpty }
        var out: [String] = []
        for t in texts { out.append(contentsOf: extractCourseIDs(from: t)) }
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
            return prereqs.map { $0.replacingOccurrences(of: "-", with: " ") }.joined(separator: ", ")
        }

        let texts = course.sections
            .map { $0.prerequisitesText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return texts.first
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
                          let r2 = Range(m.range(at: 2), in: upper) else { continue }
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

        ensureTermBoundsLoaded(for: currentSemester)
        if hasTimeConflict(for: section, semesterCode: currentSemester.rawValue) { return }

        let missing = missingPrerequisites(for: course)
        if !missing.isEmpty {
            assumePrereqs(missing, causedBy: courseKey(course))
        }

        withWidgetPublishingSuppressed {
            let enrollment = EnrolledCourse(
                id: id,
                course: course,
                section: section,
                semesterCode: currentSemester.rawValue
            )
            enrolledCourses.append(enrollment)

            for meeting in section.meetings {
                // ✅ stable meeting key (NO location dependency)
                let key = meetingOverrideKey(
                    enrollmentID: id,
                    course: course,
                    section: section,
                    meeting: meeting
                )

                for day in meeting.days {
                    guard let classDate = firstDate(onOrAfter: weekStartDate, weekday: day.calendarWeekday) else { continue }

                    generateSingleWeekEvent(
                        course: course,
                        section: section,
                        meeting: meeting,
                        date: classDate,
                        enrollmentID: id,
                        meetingKey: key
                    )
                }
            }

            recolorAllEvents()
            saveEnrollment()
            ensureTermBoundsForAllEnrollments()
            refreshSemesterWindow(anchorPreferred: nil)
        }
    }

    func removeEnrollment(_ enrollment: EnrolledCourse) {
        withWidgetPublishingSuppressed {
            clearGrade(for: enrollment.id)

            enrolledCourses.removeAll { $0.id == enrollment.id }
            events.removeAll { $0.enrollmentID == enrollment.id }
            recolorAllEvents()
            saveEnrollment()

            let removedCourseID = "\(enrollment.course.subject)-\(enrollment.course.number)"
            unassumePrereqs(causedBy: removedCourseID)

            refreshSemesterWindow(anchorPreferred: nil)
        }
    }

    // MARK: - Grades (unchanged)

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
        withWidgetPublishingSuppressed {
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
    }

    // MARK: - Event creation helpers

    fileprivate func generateSingleWeekEvent(
        course: Course,
        section: CourseSection,
        meeting: Meeting,
        date: Date,
        enrollmentID: String,
        meetingKey: String           // ✅ NEW
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

        // ✅ location should not include CRN anymore
        let location = meeting.location.isEmpty ? "" : meeting.location

        // ✅ attach stable meeting key so overrides/exam dates work
        let mKey = meetingOverrideKey(
            enrollmentID: enrollmentID,
            course: course,
            section: section,
            meeting: meeting
        )

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
            kind: .classMeeting,
            meetingKey: normalizeMeetingKey(meetingKey)
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
        withWidgetPublishingSuppressed {
            let fixed = events.filter { $0.enrollmentID == nil }
            events = fixed

            for enrollment in enrolledCourses {
                let course = enrollment.course
                let section = enrollment.section
                let id = enrollment.id

                for meeting in section.meetings {
                    for day in meeting.days {
                        guard let classDate = firstDate(onOrAfter: weekStartDate, weekday: day.calendarWeekday) else { continue }

                        // ✅ CRITICAL: stable meetingKey (NO location)
                        let key = meetingOverrideKey(
                            enrollmentID: id,
                            course: course,
                            section: section,
                            meeting: meeting
                        )

                        generateSingleWeekEvent(
                            course: course,
                            section: section,
                            meeting: meeting,
                            date: classDate,
                            enrollmentID: id,
                            meetingKey: key          // ✅ NEW
                        )
                    }
                }
            }

            recolorAllEvents()
        }
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

    // MARK: - Meeting overrides persistence

    private func saveMeetingOverrides() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(meetingOverridesByKey) {
            UserDefaults.standard.set(data, forKey: meetingOverridesStorageKey)
        }
    }

    private func loadMeetingOverrides() {
        guard let data = UserDefaults.standard.data(forKey: meetingOverridesStorageKey) else {
            meetingOverridesByKey = [:]
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([String: MeetingOverride].self, from: data) {
            // ✅ migrate keys (old -> new)
            var migrated: [String: MeetingOverride] = [:]
            migrated.reserveCapacity(loaded.count)

            for (k, v) in loaded {
                migrated[normalizeMeetingKey(k)] = v
            }

            meetingOverridesByKey = migrated
        } else {
            meetingOverridesByKey = [:]
        }
    }

    // MARK: - Exam dates persistence (RELIABLE + MIGRATION)

    private func saveExamDates() {
        // Store as Data via JSONEncoder (reliable)
        do {
            let data = try JSONEncoder().encode(examDatesByMeetingKey)
            UserDefaults.standard.set(data, forKey: examDatesStorageKey)
        } catch {
            // fallback: best effort
            UserDefaults.standard.set(examDatesByMeetingKey, forKey: examDatesStorageKey)
        }
    }

    private func loadExamDates() {
        // ✅ New format (Data)
        if let data = UserDefaults.standard.data(forKey: examDatesStorageKey),
           let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            examDatesByMeetingKey = migrateExamKeysIfNeeded(decoded)
            return
        }

        // ✅ Old format fallback (Property list dictionary)
        if let raw = UserDefaults.standard.dictionary(forKey: examDatesStorageKey) {
            var out: [String: [Double]] = [:]
            out.reserveCapacity(raw.count)

            for (k, v) in raw {
                if let arr = v as? [Double] {
                    out[k] = arr
                } else if let nsArr = v as? [NSNumber] {
                    out[k] = nsArr.map { $0.doubleValue }
                } else if let anyArr = v as? [Any] {
                    let doubles = anyArr.compactMap { item -> Double? in
                        if let d = item as? Double { return d }
                        if let n = item as? NSNumber { return n.doubleValue }
                        return nil
                    }
                    if !doubles.isEmpty { out[k] = doubles }
                }
            }

            examDatesByMeetingKey = migrateExamKeysIfNeeded(out)
            return
        }

        examDatesByMeetingKey = [:]
    }

    // ✅ Migration: old keys used to be "enrollment|days|time|location"
    // new keys are "enrollment|days|time"
    private func migrateExamKeysIfNeeded(_ dict: [String: [Double]]) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        out.reserveCapacity(dict.count)

        for (k, v) in dict {
            let newKey = normalizeMeetingKey(k)

            // merge in case collisions happen: keep the union (dedup)
            let merged = Set((out[newKey] ?? []) + v)
            out[newKey] = Array(merged).sorted()
        }
        return out
    }

    // Accepts either old key or new key and returns new stable key
    private func normalizeMeetingKey(_ key: String) -> String {
        let parts = key.components(separatedBy: "|")

        // old: enrollment|days|time|loc   (>=4)
        if parts.count >= 3 {
            return "\(parts[0])|\(parts[1])|\(parts[2])"
        }

        // fallback: if somehow malformed, just return original
        return key
    }
    
}

// MARK: - Semester helpers (file-local)

private extension Semester {
    var year: Int { Int(rawValue.prefix(4)) ?? Calendar.current.component(.year, from: Date()) }
    var month: Int { Int(rawValue.suffix(2)) ?? 1 }
    var isFall: Bool { month == 9 }
    var isSpring: Bool { month == 1 }

    var previousSemester: Semester? {
        let all = Semester.allCases.sorted { $0.rawValue < $1.rawValue }
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }

    var nextSemester: Semester? {
        let all = Semester.allCases.sorted { $0.rawValue < $1.rawValue }
        guard let i = all.firstIndex(of: self), i < all.count - 1 else { return nil }
        return all[i + 1]
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
