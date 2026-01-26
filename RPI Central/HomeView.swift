//
//  HomeView.swift
//  RPI Central
//

import SwiftUI

// MARK: - Models + Managers (stored locally in this file to avoid file explosion)

enum CourseTaskKind: String, CaseIterable, Identifiable, Codable {
    case assignment
    case exam
    case quiz
    case project
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .assignment: return "Assignment"
        case .exam:       return "Exam"
        case .quiz:       return "Quiz"
        case .project:    return "Project"
        case .other:      return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .assignment: return "doc.text"
        case .exam:       return "star.circle.fill"
        case .quiz:       return "checkmark.seal"
        case .project:    return "hammer.fill"
        case .other:      return "tag"
        }
    }
}

struct CourseTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    /// If set, task is associated to a course enrollment
    var enrollmentID: String?

    var title: String
    var kind: CourseTaskKind
    var dueDate: Date

    /// Notification offsets in minutes before dueDate (e.g. 10080 = 7d, 1440 = 1d, 60 = 1h)
    var reminderOffsetsMinutes: [Int] = [10080, 1440]

    var notes: String = ""
}

final class TasksManager: ObservableObject {
    @Published var tasks: [CourseTask] = [] {
        didSet { save() }
    }

    private let storageKey = "courseTasks.v1"

    init() {
        load()
    }

    func upcomingTasks(withinDays days: Int) -> [CourseTask] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return tasks
            .filter { $0.dueDate >= now && $0.dueDate <= end }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func add(_ t: CourseTask) {
        tasks.append(t)
        scheduleNotifications(for: t)
    }

    func update(_ t: CourseTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks[idx] = t
        NotificationManager.clearTaskNotifications(taskID: t.id)
        scheduleNotifications(for: t)
    }

    func delete(_ t: CourseTask) {
        tasks.removeAll { $0.id == t.id }
        NotificationManager.clearTaskNotifications(taskID: t.id)
    }

    func delete(at offsets: IndexSet) {
        for i in offsets {
            let t = tasks[i]
            NotificationManager.clearTaskNotifications(taskID: t.id)
        }
        tasks.remove(atOffsets: offsets)
    }

    private func scheduleNotifications(for t: CourseTask) {
        for offset in t.reminderOffsetsMinutes {
            NotificationManager.scheduleTaskReminder(task: t, minutesBefore: offset)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            tasks = []
            return
        }
        if let decoded = try? JSONDecoder().decode([CourseTask].self, from: data) {
            tasks = decoded
        } else {
            tasks = []
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Meal plan (swipe tracker)

struct MealPlanState: Codable, Equatable {
    var swipesPerWeek: Int = 19
    var usedThisWeek: Int = 0

    /// 1 = Sunday ... 7 = Saturday
    var resetWeekday: Int = 1  // Sunday

    /// last reset timestamp
    var lastReset: Date = Date()
}

final class MealPlanManager: ObservableObject {
    @Published var state: MealPlanState = MealPlanState() {
        didSet { save() }
    }

    private let storageKey = "mealPlanState.v1"

    init() {
        load()
        refreshIfNeeded()
    }

    var remaining: Int {
        max(0, state.swipesPerWeek - state.usedThisWeek)
    }

    func logSwipe() {
        refreshIfNeeded()
        state.usedThisWeek += 1
    }

    func undoSwipe() {
        refreshIfNeeded()
        state.usedThisWeek = max(0, state.usedThisWeek - 1)
    }

    func resetNow() {
        state.usedThisWeek = 0
        state.lastReset = Date()
    }

    func refreshIfNeeded() {
        let now = Date()

        // Force week start to Sunday 12:00 AM (regardless of locale)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 1 // Sunday

        let startOfThisResetWeek = mostRecentWeekdayStart(for: 1, reference: now, calendar: cal)
        if state.lastReset < startOfThisResetWeek {
            state.usedThisWeek = 0
            state.lastReset = now
        }
    }

    private func mostRecentWeekdayStart(for weekday: Int, reference: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: reference)
        let todayWeekday = calendar.component(.weekday, from: todayStart)

        var daysBack = todayWeekday - weekday
        if daysBack < 0 { daysBack += 7 }

        let targetDay = calendar.date(byAdding: .day, value: -daysBack, to: todayStart) ?? todayStart
        return targetDay
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            state = MealPlanState()
            return
        }
        if let decoded = try? JSONDecoder().decode(MealPlanState.self, from: data) {
            state = decoded
        } else {
            state = MealPlanState()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Pomodoro timer (simple)

struct PomodoroPreset: Codable, Equatable {
    var focusMinutes: Int = 25
    var breakMinutes: Int = 5
}

final class PomodoroSettingsManager: ObservableObject {
    @Published var preset: PomodoroPreset = PomodoroPreset() {
        didSet { save() }
    }

    private let storageKey = "pomodoroPreset.v1"

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode(PomodoroPreset.self, from: data) {
            preset = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    @StateObject private var tasksManager = TasksManager()
    @StateObject private var mealPlanManager = MealPlanManager()
    @StateObject private var pomodoroSettings = PomodoroSettingsManager()

    @State private var showAllTasks = false
    @State private var showTaskEditor = false
    @State private var editingTask: CourseTask? = nil

    @State private var showMealSettings = false
    @State private var showTimer = false

    // ✅ force refresh when meeting-block exam dates change (CalendarViewModel sends objectWillChange)
    @State private var upcomingRefreshToken = UUID()

    private var groupedBySemester: [String: [EnrolledCourse]] {
        Dictionary(grouping: calendarViewModel.enrolledCourses, by: { $0.semesterCode })
    }

    private var sortedSemesterCodes: [String] {
        groupedBySemester.keys.sorted(by: >)
    }
    // MARK: - Current semester filtering for Upcoming + Task Editor

    private var currentSemesterCode: String? {
        // currentSemester is a non-optional Semester
        return calendarViewModel.currentSemester.rawValue
    }

    private var currentSemesterEnrollments: [EnrolledCourse] {
        guard let code = currentSemesterCode else { return calendarViewModel.enrolledCourses }
        return calendarViewModel.enrolledCourses.filter { $0.semesterCode == code }
    }

    private func isEnrollmentInCurrentSemester(_ enrollmentID: String?) -> Bool {
        guard let code = currentSemesterCode else { return true }
        guard let eid = enrollmentID else { return true }
        guard let e = calendarViewModel.enrolledCourses.first(where: { $0.id == eid }) else { return true }
        return e.semesterCode == code
    }

    var body: some View {
        NavigationStack {
            List {
                // GPA
                Section {
                    HStack {
                        Text("Overall GPA")
                            .font(.headline)
                        Spacer()
                        Text(GPACalculator.format(calendarViewModel.overallGPA()))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(sortedSemesterCodes, id: \.self) { semCode in
                    let enrollments = groupedBySemester[semCode] ?? []
                    let semesterName = Semester(rawValue: semCode)?.displayName ?? semCode

                    Section {
                        ForEach(enrollments, id: \.id) { enrollment in
                            HStack(spacing: 12) {
                                // LEFT: course info (takes remaining width)
                                NavigationLink {
                                    CourseDetailView(course: enrollment.course)
                                        .environmentObject(calendarViewModel)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(enrollment.course.subject) \(enrollment.course.number)")
                                            .font(.headline)
                                            .lineLimit(1)

                                        Text(enrollment.course.title)
                                            .font(.subheadline)
                                            .lineLimit(1)

                                        if let firstMeeting = enrollment.section.meetings.first {
                                            Text(firstMeeting.humanReadableSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        if !enrollment.section.instructor.isEmpty {
                                            Text(enrollment.section.instructor)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .layoutPriority(1)

                                // RIGHT: grade capsule (guaranteed visible)
                                GradeBreakdownButton(enrollmentID: enrollment.id)
                                    .environmentObject(calendarViewModel)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .layoutPriority(2)
                            }
                        }
                        .onDelete { offsets in
                            let toDelete = offsets.map { enrollments[$0] }
                            for e in toDelete {
                                calendarViewModel.removeEnrollment(e)
                            }
                        }
                    } header: {
                        HStack {
                            Text(semesterName)
                            Spacer()
                            let termGPA = calendarViewModel.gpa(for: semCode)
                            Text("GPA \(GPACalculator.format(termGPA))")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }

                if calendarViewModel.enrolledCourses.isEmpty {
                    Text("No courses yet. Add some from the Courses tab.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("RPI Central")
        }
    }
}

// MARK: - Meeting helper

extension Meeting {
    var humanReadableSummary: String {
        let daysString = days.map { $0.shortName }.joined(separator: ", ")

        if location.isEmpty {
            return "\(daysString) \(start)–\(end)"
        } else {
            return "\(daysString) \(start)–\(end) · \(location)"
        }
    }
}
