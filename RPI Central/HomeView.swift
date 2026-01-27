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

                // UPCOMING (Assignments + Exam blocks)
                Section {
                    let upcoming = Array(combinedUpcomingItems(days: 14).prefix(4))

                    if upcoming.isEmpty {
                        Text("No upcoming items. Add an assignment or exam.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(upcoming, id: \.id) { item in
                            UpcomingRow(
                                item: item,
                                themeColor: calendarViewModel.themeColor,
                                onEditTask: { t in
                                    editingTask = t
                                    showTaskEditor = true
                                },
                                onDeleteTask: { t in
                                    tasksManager.delete(t)
                                },
                                onImportExamReminder: { examTitle, examDate in
                                    let prefill = CourseTask(
                                        id: UUID(),
                                        enrollmentID: nil,
                                        title: examTitle,
                                        kind: .exam,
                                        dueDate: examDate,
                                        reminderOffsetsMinutes: [10080, 1440, 60],
                                        notes: "Imported from meeting block exam."
                                    )
                                    editingTask = prefill
                                    showTaskEditor = true
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if case .task(let t) = item.source {
                                    Button(role: .destructive) {
                                        tasksManager.delete(t)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            editingTask = nil
                            showTaskEditor = true
                        } label: {
                            Label("Add", systemImage: "plus.circle.fill")
                        }

                        Spacer()

                        Button {
                            showAllTasks = true
                        } label: {
                            Text("View all")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .tint(calendarViewModel.themeColor)
                } header: {
                    Text("Upcoming (Assignments + Exams)")
                }
                .id(upcomingRefreshToken)

                // MEAL PLAN
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(mealPlanManager.remaining)")
                                .font(.title3.weight(.bold))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(mealPlanManager.state.usedThisWeek)/\(mealPlanManager.state.swipesPerWeek)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            mealPlanManager.logSwipe()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "fork.knife")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.white.opacity(0.95)) // ✅ visible icon
                                Text("Use swipe")
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(calendarViewModel.themeColor)

                        Button {
                            mealPlanManager.undoSwipe()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            showMealSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Meal Swipes")
                }
                .onAppear {
                    mealPlanManager.refreshIfNeeded()
                }

                // STUDY TIMER
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pomodoro")
                                .font(.subheadline.weight(.semibold))
                            Text("\(pomodoroSettings.preset.focusMinutes)m focus • \(pomodoroSettings.preset.breakMinutes)m break")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            showTimer = true
                        } label: {
                            Text("Start")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Study Timer")
                }

                // Your existing per-semester enrollment list
                ForEach(sortedSemesterCodes, id: \.self) { semCode in
                    let enrollments = groupedBySemester[semCode] ?? []
                    let semesterName = Semester(rawValue: semCode)?.displayName ?? semCode

                    Section {
                        ForEach(enrollments, id: \.id) { enrollment in
                            HStack(spacing: 12) {
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
            .tint(calendarViewModel.themeColor)

            .onReceive(calendarViewModel.objectWillChange) { _ in
                upcomingRefreshToken = UUID()
            }

            // Prevent “View all” closing from auto-opening the task editor
            .onChange(of: showAllTasks) { isShowing in
                if !isShowing {
                    showTaskEditor = false
                    editingTask = nil
                }
            }

            .sheet(isPresented: $showAllTasks) {
                NavigationStack {
                    TasksListView(
                        tasksManager: tasksManager,
                        enrollments: currentSemesterEnrollments,
                        themeColor: calendarViewModel.themeColor,
                        calendarExamItems: upcomingExamItems(days: 120)
                    )
                }
            }

            .sheet(isPresented: $showTaskEditor, onDismiss: { editingTask = nil }) {
                NavigationStack {
                    TaskEditorView(
                        themeColor: calendarViewModel.themeColor,
                        enrollments: currentSemesterEnrollments,
                        existing: editingTask,
                        onSave: { saved in
                            if tasksManager.tasks.contains(where: { $0.id == saved.id }) {
                                tasksManager.update(saved)
                            } else {
                                tasksManager.add(saved)
                            }
                            showTaskEditor = false
                        },
                        onCancel: {
                            showTaskEditor = false
                        }
                    )
                }
            }

            .sheet(isPresented: $showMealSettings) {
                NavigationStack {
                    MealPlanSettingsView(themeColor: calendarViewModel.themeColor, manager: mealPlanManager)
                }
            }

            .sheet(isPresented: $showTimer) {
                NavigationStack {
                    PomodoroTimerView(
                        themeColor: calendarViewModel.themeColor,
                        settings: pomodoroSettings
                    )
                }
            }
        }
    }

    // MARK: - Upcoming merging (Tasks + Exam events)

    fileprivate enum UpcomingSource: Equatable {
        case task(CourseTask)
        case calendarExam(title: String, date: Date)
    }

    fileprivate struct UpcomingItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let due: Date
        let icon: String
        let source: UpcomingSource

        var dueText: String {
            let df = DateFormatter()

            // If it's exactly on the hour, show "1/30 10 AM"
            // Otherwise show "1/30 10:15 AM"
            let minute = Calendar.current.component(.minute, from: due)
            if minute == 0 {
                df.dateFormat = "M/d h a"
            } else {
                df.dateFormat = "M/d h:mm a"
            }

            return df.string(from: due)
        }

        var relativeText: String {
            let now = Date()
            let delta = due.timeIntervalSince(now)
            if delta <= 0 { return "Now" }

            let minutes = Int(delta / 60)
            if minutes < 60 { return "\(minutes)m" }

            let hours = Int(delta / 3600)
            if hours < 24 { return "\(hours)h" }

            let days = Int(delta / 86400)
            if days == 1 { return "Tomorrow" }
            if days < 14 { return "\(days)d" }

            let weeks = max(2, Int(Double(days) / 7.0))
            return "\(weeks)w"
        }
    }

    private func combinedUpcomingItems(days: Int) -> [UpcomingItem] {
        let examItems = upcomingExamItems(days: days)

        // De-dupe: if user created an Exam task with exact same timestamp as an exam block, show the task only
        let examTimes: Set<Int> = Set(examItems.map { Int($0.due.timeIntervalSince1970) })

        let taskItems: [UpcomingItem] = tasksManager.upcomingTasks(withinDays: days)
            // ✅ hide tasks from other semesters in "Upcoming"
            .filter { t in
                isEnrollmentInCurrentSemester(t.enrollmentID)
            }
            .filter { t in
                guard t.kind == .exam else { return true }
                return !examTimes.contains(Int(t.dueDate.timeIntervalSince1970))
            }
            .map { t in
                let subtitle = subtitleForTask(t)
                return UpcomingItem(
                    id: "task-\(t.id.uuidString)",
                    title: t.title,
                    subtitle: subtitle,
                    due: t.dueDate,
                    icon: t.kind.systemImage,
                    source: .task(t)
                )
            }

        return (taskItems + examItems)
            .sorted { $0.due < $1.due }
    }

    private func subtitleForTask(_ t: CourseTask) -> String {
        if let eid = t.enrollmentID,
           let e = calendarViewModel.enrolledCourses.first(where: { $0.id == eid }) {
            // ✅ Show real course name instead of "ECON 4310"
            return "\(t.kind.label) • \(e.course.title)"
        }
        return t.kind.label
    }

    private func upcomingExamItems(days: Int) -> [UpcomingItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: days, to: start) ?? start

        var items: [UpcomingItem] = []
        var seen: Set<String> = []

        var d = start
        while d <= end {
            let evs = calendarViewModel.events(on: d)
            for ev in evs {
                guard ev.kind == .classMeeting else { continue }
                guard ev.title.hasPrefix("★") else { continue }

                // ✅ hide exam blocks that belong to other semesters
                if let code = currentSemesterCode,
                   let eid = ev.enrollmentID,
                   let e = calendarViewModel.enrolledCourses.first(where: { $0.id == eid }),
                   e.semesterCode != code {
                    continue
                }

                let key = "\(ev.meetingKey ?? "nil")|\(Int(ev.startDate.timeIntervalSince1970))|\(Int(ev.endDate.timeIntervalSince1970))|\(ev.enrollmentID ?? "nil")"
                if seen.contains(key) { continue }
                seen.insert(key)

                let cleanTitle = ev.title.replacingOccurrences(of: "★ ", with: "")
                let subtitle = "Exam • \(timeRangeText(ev.startDate, ev.endDate))"

                items.append(
                    UpcomingItem(
                        id: "exam-\(key)",
                        title: cleanTitle,
                        subtitle: subtitle,
                        due: ev.startDate,
                        icon: "star.circle.fill",
                        source: .calendarExam(title: cleanTitle, date: ev.startDate)
                    )
                )
            }

            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
        }

        return items.sorted { $0.due < $1.due }
    }

    private func timeRangeText(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return "\(df.string(from: start))–\(df.string(from: end))"
    }
}

// MARK: - Upcoming Row (Home screen)

private struct UpcomingRow: View {
    let item: HomeView.UpcomingItem
    let themeColor: Color

    let onEditTask: (CourseTask) -> Void
    let onDeleteTask: (CourseTask) -> Void
    let onImportExamReminder: (_ title: String, _ date: Date) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(themeColor.opacity(0.95))

            Button {
                if case .task(let t) = item.source {
                    onEditTask(t)
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(item.relativeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(item.dueText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled({
                if case .calendarExam = item.source { return true }
                return false
            }())

            // ✅ Remove button for tasks (and only tasks)
            if case .task(let t) = item.source {
                Button(role: .destructive) {
                    onDeleteTask(t)
                } label: {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.leading, 4)
            }

            // ✅ Only the bell opens the editor for exam blocks
            if case .calendarExam(let title, let date) = item.source {
                Button {
                    onImportExamReminder(title, date)
                } label: {
                    Image(systemName: "bell.badge")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(themeColor, .secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - Tasks List (full view)

private struct TasksListView: View {
    @ObservedObject var tasksManager: TasksManager
    let enrollments: [EnrolledCourse]
    let themeColor: Color
    let calendarExamItems: [HomeView.UpcomingItem]

    @Environment(\.dismiss) private var dismiss
    @State private var showTaskEditor = false
    @State private var editingTask: CourseTask? = nil

    var body: some View {
        List {
            Section("Assignments / Custom Items") {
                if tasksManager.tasks.isEmpty {
                    Text("No tasks yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tasksManager.tasks.sorted(by: { $0.dueDate < $1.dueDate })) { t in
                        Button {
                            editingTask = t
                            showTaskEditor = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: t.kind.systemImage)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(themeColor.opacity(0.95))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)

                                    Text(taskSubtitle(t))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(relativeText(to: t.dueDate))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Text(dateText(t.dueDate))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: tasksManager.delete)
                }
            }

            Section("Exam Blocks (from Meeting Overrides)") {
                if calendarExamItems.isEmpty {
                    Text("No upcoming exam blocks.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarExamItems.prefix(30), id: \.id) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(themeColor.opacity(0.95))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(item.relativeText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(item.dueText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            // Sync: create reminders from exam blocks
                            Button {
                                let prefill = CourseTask(
                                    id: UUID(),
                                    enrollmentID: nil,
                                    title: item.title,
                                    kind: .exam,
                                    dueDate: item.due,
                                    reminderOffsetsMinutes: [10080, 1440, 60],
                                    notes: "Imported from meeting block exam."
                                )
                                editingTask = prefill
                                showTaskEditor = true
                            } label: {
                                Image(systemName: "bell.badge")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(themeColor, .secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 6)
                        }
                    }
                }
            }
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.inline)
        .tint(themeColor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingTask = nil
                    showTaskEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showTaskEditor, onDismiss: { editingTask = nil }) {
            NavigationStack {
                TaskEditorView(
                    themeColor: themeColor,
                    enrollments: enrollments,
                    existing: editingTask,
                    onSave: { saved in
                        if tasksManager.tasks.contains(where: { $0.id == saved.id }) {
                            tasksManager.update(saved)
                        } else {
                            tasksManager.add(saved)
                        }
                        showTaskEditor = false
                    },
                    onCancel: {
                        showTaskEditor = false
                    }
                )
            }
        }
    }

    private func taskSubtitle(_ t: CourseTask) -> String {
        if let eid = t.enrollmentID,
           let e = enrollments.first(where: { $0.id == eid }) {
            return "\(t.kind.label) • \(e.course.subject) \(e.course.number)"
        }
        return t.kind.label
    }

    private func dateText(_ d: Date) -> String {
        let df = DateFormatter()

        // If exactly on the hour: "1/30 10 AM"
        // Otherwise: "1/30 10:15 AM"
        let minute = Calendar.current.component(.minute, from: d)
        if minute == 0 {
            df.dateFormat = "M/d h a"
        } else {
            df.dateFormat = "M/d h:mm a"
        }

        return df.string(from: d)
    }

    private func relativeText(to due: Date) -> String {
        let now = Date()
        let delta = due.timeIntervalSince(now)
        if delta <= 0 { return "Now" }

        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = Int(delta / 3600)
        if hours < 24 { return "\(hours)h" }

        let days = Int(delta / 86400)
        if days == 1 { return "Tomorrow" }
        if days < 14 { return "\(days)d" }

        let weeks = max(2, Int(Double(days) / 7.0))
        return "\(weeks)w"
    }
}

// MARK: - Reminder edit sheet helper

private struct ReminderEditItem: Identifiable, Equatable {
    let minutes: Int
    var id: Int { minutes }
}

// MARK: - Task Editor

private struct TaskEditorView: View {
    let themeColor: Color
    let enrollments: [EnrolledCourse]
    let existing: CourseTask?

    let onSave: (CourseTask) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var title: String = ""
    @State private var kind: CourseTaskKind = .assignment
    @State private var dueDate: Date = Date()
    @State private var enrollmentID: String? = nil
    @State private var notes: String = ""

    // reminder offsets in minutes
    @State private var reminderOffsets: [Int] = [10080, 1440]

    // add custom (days/hours/minutes)
    @State private var customDays: String = "0"
    @State private var customHours: String = "0"
    @State private var customMinutes: String = "0"
    
    private func defaultDueDateAt1159PM() -> Date {
        var cal = Calendar.current
        cal.timeZone = .current

        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        let today1159 = cal.date(bySettingHour: 23, minute: 59, second: 0, of: todayStart) ?? now
        if now <= today1159 {
            return today1159
        }

        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let tomorrow1159 = cal.date(bySettingHour: 23, minute: 59, second: 0, of: tomorrowStart) ?? now
        return tomorrow1159
    }

    // edit existing reminder
    @State private var editingReminder: ReminderEditItem? = nil

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: $title)
                    .focused($focused)
                    .foregroundStyle(themeColor)

                Picker("Type", selection: $kind) {
                    ForEach(CourseTaskKind.allCases) { k in
                        Label(k.label, systemImage: k.systemImage).tag(k)
                    }
                }

                DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])

                // ✅ show real course names
                Picker("Course (optional)", selection: Binding(
                    get: { enrollmentID ?? "__none__" },
                    set: { v in enrollmentID = (v == "__none__") ? nil : v }
                )) {
                    Text("None").tag("__none__")
                    ForEach(enrollments, id: \.id) { e in
                        Text("\(e.course.subject) \(e.course.number) • \(e.course.title)")
                            .tag(e.id)
                    }
                }
            }

            Section("Reminders") {
                if reminderOffsets.isEmpty {
                    Text("No reminders set.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reminderOffsets.sorted(by: >), id: \.self) { off in
                        HStack {
                            Text("Before due")
                            Spacer()
                            Text(formatOffset(off))
                                .foregroundStyle(.secondary)

                            Button {
                                editingReminder = ReminderEditItem(minutes: off)
                            } label: {
                                Image(systemName: "pencil")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(themeColor)
                            .padding(.leading, 8)

                            Button(role: .destructive) {
                                reminderOffsets.removeAll { $0 == off }
                                reminderOffsets = Array(Set(reminderOffsets)).sorted()
                            } label: {
                                Image(systemName: "trash")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .padding(.leading, 6)
                        }
                    }
                }

                // Quick actions
                HStack(spacing: 10) {
                    Button("7d") { addOffset(10080) }
                        .buttonStyle(.bordered)
                    Button("1d") { addOffset(1440) }
                        .buttonStyle(.bordered)
                    Button("1h") { addOffset(60) }
                        .buttonStyle(.bordered)
                }
                .tint(themeColor)

                // Custom input
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Days", text: $customDays)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)

                        TextField("Hours", text: $customHours)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)

                        TextField("Minutes", text: $customMinutes)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)

                        Spacer()
                    }

                    Button {
                        addCustomOffsetFromInputs()
                    } label: {
                        Label("Add reminder", systemImage: "plus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.8))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor)
                }
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 110)
            }
        }
        .navigationTitle(existing == nil ? "New Task" : "Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .tint(themeColor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

                    let out = CourseTask(
                        id: existing?.id ?? UUID(),
                        enrollmentID: enrollmentID,
                        title: cleanedTitle,
                        kind: kind,
                        dueDate: dueDate,
                        reminderOffsetsMinutes: reminderOffsets.sorted(by: >),
                        notes: notes
                    )
                    onSave(out)
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .sheet(item: $editingReminder) { item in
            ReminderOffsetEditorSheet(
                themeColor: themeColor,
                originalMinutes: item.minutes,
                onSave: { newMinutes in
                    // replace
                    reminderOffsets.removeAll { $0 == item.minutes }
                    if newMinutes > 0 {
                        reminderOffsets.append(newMinutes)
                    }
                    reminderOffsets = Array(Set(reminderOffsets)).sorted()
                },
                onDelete: {
                    reminderOffsets.removeAll { $0 == item.minutes }
                    reminderOffsets = Array(Set(reminderOffsets)).sorted()
                }
            )
        }
        .onAppear {
            if let existing {
                title = existing.title
                kind = existing.kind
                dueDate = existing.dueDate
                enrollmentID = existing.enrollmentID
                notes = existing.notes
                reminderOffsets = existing.reminderOffsetsMinutes
            } else {
                title = ""
                kind = .assignment
                dueDate = defaultDueDateAt1159PM()
                enrollmentID = nil
                notes = ""
                reminderOffsets = [10080, 1440]
            }

            reminderOffsets = Array(Set(reminderOffsets)).sorted()
        }
    }

    private func addOffset(_ minutes: Int) {
        guard minutes > 0 else { return }
        reminderOffsets.append(minutes)
        reminderOffsets = Array(Set(reminderOffsets)).sorted()
    }

    private func addCustomOffsetFromInputs() {
        let d = Int(customDays) ?? 0
        let h = Int(customHours) ?? 0
        let m = Int(customMinutes) ?? 0

        let total = d * 1440 + h * 60 + m
        guard total > 0 else { return }

        addOffset(total)

        customDays = "0"
        customHours = "0"
        customMinutes = "0"
    }

    private func formatOffset(_ minutes: Int) -> String {
        var remaining = max(0, minutes)
        let days = remaining / 1440
        remaining -= days * 1440
        let hours = remaining / 60
        remaining -= hours * 60
        let mins = remaining

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 { parts.append("\(mins)m") }

        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }
}

// MARK: - Reminder Editor Sheet

private struct ReminderOffsetEditorSheet: View {
    let themeColor: Color
    let originalMinutes: Int
    let onSave: (Int) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var days: String = "0"
    @State private var hours: String = "0"
    @State private var minutes: String = "0"

    var body: some View {
        NavigationStack {
            Form {
                Section("Edit reminder") {
                    HStack(spacing: 10) {
                        TextField("Days", text: $days)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)

                        TextField("Hours", text: $hours)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 90)

                        TextField("Minutes", text: $minutes)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)

                        Spacer()
                    }

                    Text("Current: \(formatOffset(originalMinutes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Quick set") {
                    HStack(spacing: 10) {
                        Button("7d") { setFrom(totalMinutes: 10080) }
                            .buttonStyle(.bordered)
                        Button("1d") { setFrom(totalMinutes: 1440) }
                            .buttonStyle(.bordered)
                        Button("1h") { setFrom(totalMinutes: 60) }
                            .buttonStyle(.bordered)
                    }
                    .tint(themeColor)
                }

                Section {
                    Button("Remove reminder", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .tint(themeColor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let new = parseToMinutes()
                        if new > 0 {
                            onSave(new)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                setFrom(totalMinutes: originalMinutes)
            }
        }
    }

    private func parseToMinutes() -> Int {
        let d = Int(days) ?? 0
        let h = Int(hours) ?? 0
        let m = Int(minutes) ?? 0
        return max(0, d * 1440 + h * 60 + m)
    }

    private func setFrom(totalMinutes: Int) {
        var remaining = max(0, totalMinutes)
        let d = remaining / 1440
        remaining -= d * 1440
        let h = remaining / 60
        remaining -= h * 60
        let m = remaining

        days = "\(d)"
        hours = "\(h)"
        minutes = "\(m)"
    }

    private func formatOffset(_ minutes: Int) -> String {
        var remaining = max(0, minutes)
        let d = remaining / 1440
        remaining -= d * 1440
        let h = remaining / 60
        remaining -= h * 60
        let m = remaining

        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }
}

// MARK: - Meal Plan Settings View

private struct MealPlanSettingsView: View {
    let themeColor: Color
    @ObservedObject var manager: MealPlanManager

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Plan") {
                Stepper("Swipes per week: \(manager.state.swipesPerWeek)", value: Binding(
                    get: { manager.state.swipesPerWeek },
                    set: { manager.state.swipesPerWeek = max(0, $0) }
                ), in: 0...40)

                Text("Resets every Sunday at 12:00 AM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                Button("Reset now") {
                    manager.resetNow()
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Meal Plan")
        .navigationBarTitleDisplayMode(.inline)
        .tint(themeColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - Pomodoro Timer View

private struct PomodoroTimerView: View {
    let themeColor: Color
    @ObservedObject var settings: PomodoroSettingsManager

    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var isBreak = false
    @State private var remainingSeconds: Int = 0

    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(isBreak ? "Break" : "Focus")
                    .font(.title2.weight(.bold))

                Text(timeString(remainingSeconds))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.top, 20)

            HStack(spacing: 12) {
                Button(isRunning ? "Pause" : "Start") {
                    if isRunning { pause() } else { start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(themeColor)

                Button("Reset") { reset() }
                    .buttonStyle(.bordered)
            }

            Form {
                Section("Preset") {
                    Stepper("Focus: \(settings.preset.focusMinutes) min", value: Binding(
                        get: { settings.preset.focusMinutes },
                        set: { settings.preset.focusMinutes = max(1, $0) }
                    ), in: 1...180)

                    Stepper("Break: \(settings.preset.breakMinutes) min", value: Binding(
                        get: { settings.preset.breakMinutes },
                        set: { settings.preset.breakMinutes = max(1, $0) }
                    ), in: 1...60)
                }

                Section {
                    Text("When a session ends, you’ll get a notification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Study Timer")
        .navigationBarTitleDisplayMode(.inline)
        .tint(themeColor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    stopTimer()
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    stopTimer()
                    dismiss()
                }
            }
        }
        .onAppear {
            remainingSeconds = settings.preset.focusMinutes * 60
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func start() {
        if remainingSeconds <= 0 {
            remainingSeconds = (isBreak ? settings.preset.breakMinutes : settings.preset.focusMinutes) * 60
        }

        isRunning = true
        stopTimer()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            tick()
        }
    }

    private func pause() {
        isRunning = false
        stopTimer()
    }

    private func reset() {
        isRunning = false
        stopTimer()
        isBreak = false
        remainingSeconds = settings.preset.focusMinutes * 60
    }

    private func tick() {
        guard remainingSeconds > 0 else {
            finishPhase()
            return
        }
        remainingSeconds -= 1
        if remainingSeconds == 0 {
            finishPhase()
        }
    }

    private func finishPhase() {
        stopTimer()
        isRunning = false

        NotificationManager.requestAuthorization()
        NotificationManager.scheduleTimerFinishedNotification(isBreak: isBreak)

        isBreak.toggle()
        remainingSeconds = (isBreak ? settings.preset.breakMinutes : settings.preset.focusMinutes) * 60
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timeString(_ sec: Int) -> String {
        let m = max(0, sec) / 60
        let s = max(0, sec) % 60
        return String(format: "%02d:%02d", m, s)
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
