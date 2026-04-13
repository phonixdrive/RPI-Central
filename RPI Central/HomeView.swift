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

    static let storageKey = "courseTasks.v1"
    private static let notificationsEnabledKey = "settings_notifications_enabled_v1"
    private var syncObserver: NSObjectProtocol?

    init() {
        load()
        rescheduleStoredNotifications()
        syncObserver = NotificationCenter.default.addObserver(
            forName: .appStateSyncDidApplyLocalState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromStore()
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
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
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
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
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func reloadFromStore() {
        load()
        rescheduleStoredNotifications()
    }

    static func loadStoredTasks() -> [CourseTask] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CourseTask].self, from: data) else {
            return []
        }
        return decoded
    }

    static func replaceStoredTasks(_ tasks: [CourseTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func rescheduleStoredNotifications() {
        NotificationManager.clearAllTaskNotifications()
        let notificationsEnabled = UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
        guard notificationsEnabled else { return }
        for task in tasks {
            scheduleNotifications(for: task)
        }
    }
}

private func taskRelativeDueText(to due: Date, now: Date = Date()) -> String {
    let delta = due.timeIntervalSince(now)
    if delta > 0 {
        let minutes = max(1, Int(delta / 60))
        if minutes < 60 { return "\(minutes)m" }

        let hours = Int(delta / 3600)
        if hours < 24 { return "\(hours)h" }

        if Calendar.current.isDateInTomorrow(due) {
            return "Tomorrow (\(hours)h)"
        }

        let days = max(1, Int(ceil(delta / 86400)))
        if days < 14 { return "\(days)d" }

        let weeks = max(2, Int(Double(days) / 7.0))
        return "\(weeks)w"
    }

    let overdue = abs(delta)
    let minutes = max(1, Int(overdue / 60))
    if minutes < 60 { return "\(minutes)m ago" }

    let hours = Int(overdue / 3600)
    if hours < 24 { return "\(hours)h ago" }

    let days = Int(overdue / 86400)
    if days == 1 { return "Yesterday" }
    if days < 14 { return "\(days)d ago" }

    let weeks = max(2, Int(Double(days) / 7.0))
    return "\(weeks)w ago"
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

    static let storageKey = "mealPlanState.v1"
    private var syncObserver: NSObjectProtocol?

    init() {
        load()
        refreshIfNeeded()
        syncObserver = NotificationCenter.default.addObserver(
            forName: .appStateSyncDidApplyLocalState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromStore()
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
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
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
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
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func reloadFromStore() {
        load()
        refreshIfNeeded()
    }

    static func loadStoredState() -> MealPlanState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MealPlanState.self, from: data) else {
            return MealPlanState()
        }
        return decoded
    }

    static func replaceStoredState(_ state: MealPlanState) {
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

    static let storageKey = "pomodoroPreset.v1"
    private var syncObserver: NSObjectProtocol?

    init() {
        load()
        syncObserver = NotificationCenter.default.addObserver(
            forName: .appStateSyncDidApplyLocalState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromStore()
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode(PomodoroPreset.self, from: data) {
            preset = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func reloadFromStore() {
        load()
    }

    static func loadStoredPreset() -> PomodoroPreset {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PomodoroPreset.self, from: data) else {
            return PomodoroPreset()
        }
        return decoded
    }

    static func replaceStoredPreset(_ preset: PomodoroPreset) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @AppStorage(DiningFavoritesStore.storageKey) private var diningFavoriteVenueNamesStorage = "[]"

    @StateObject private var tasksManager = TasksManager()
    @StateObject private var mealPlanManager = MealPlanManager()
    @StateObject private var flexDollarsManager = FlexDollarsManager()
    @StateObject private var pomodoroSettings = PomodoroSettingsManager()

    @State private var showAllTasks = false
    @State private var showTaskEditor = false
    @State private var editingTask: CourseTask? = nil

    @State private var showMealSettings = false
    @State private var showFlexDollarPlanner = false
    @State private var showFlexDollarUpdate = false
    @State private var showTimer = false
    @State private var editingSemesterGPA: Semester? = nil

    private var groupedBySemester: [String: [EnrolledCourse]] {
        Dictionary(grouping: calendarViewModel.enrolledCourses, by: { $0.semesterCode })
    }

    private var sortedSemesters: [Semester] {
        calendarViewModel.displayedAcademicSemesters()
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

    private var favoriteDiningVenues: [DiningVenue] {
        let favoriteNames = Set(DiningFavoritesStore.decode(diningFavoriteVenueNamesStorage))
        return DiningHoursData.venues
            .filter { favoriteNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isEnrollmentInCurrentSemester(_ enrollmentID: String?) -> Bool {
        guard let code = currentSemesterCode else { return true }
        guard let eid = enrollmentID else { return true }
        guard let e = calendarViewModel.enrolledCourses.first(where: { $0.id == eid }) else { return true }
        return e.semesterCode == code
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

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

                    ForEach(calendarViewModel.homeSectionOrder) { section in
                        if calendarViewModel.isHomeSectionEnabled(section) {
                            homeDashboardSection(section)
                        }
                    }

                    // Your existing per-semester enrollment list
                    ForEach(sortedSemesters) { semester in
                        let semCode = semester.rawValue
                        let enrollments = groupedBySemester[semCode] ?? []
                        let semesterName = semester.displayName

                        Section {
                            ForEach(enrollments, id: \.id) { enrollment in
                                HStack(spacing: 12) {
                                    NavigationLink {
                                        CourseDetailView(course: enrollment.course, displaySemester: semester)
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

                            if enrollments.isEmpty {
                                Text("No courses recorded for this semester.")
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                editingSemesterGPA = semester
                            } label: {
                                Label(
                                    calendarViewModel.semesterGPAOverride(for: semCode) == nil ? "Set Semester GPA" : "Edit Semester GPA",
                                    systemImage: "slider.horizontal.3"
                                )
                                .foregroundStyle(calendarViewModel.themeColor)
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
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("RPI Central")
            .tint(calendarViewModel.themeColor)
            .task(id: calendarViewModel.currentSemester.rawValue) {
                calendarViewModel.ensureTermBoundsLoaded(for: calendarViewModel.currentSemester)
                normalizeExistingExamTasksIfNeeded()
            }

            // Prevent “View all” closing from auto-opening the task editor
            .onChange(of: showAllTasks) {
                let isShowing = showAllTasks
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
                        calendarExamItems: upcomingExamItems(days: 120),
                        lmsCalendarItems: upcomingLMSCalendarItems(days: 120)
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
                            let normalized = normalizedExamTask(saved)
                            if tasksManager.tasks.contains(where: { $0.id == normalized.id }) {
                                tasksManager.update(normalized)
                            } else {
                                tasksManager.add(normalized)
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

            .sheet(isPresented: $showFlexDollarPlanner) {
                NavigationStack {
                    FlexDollarsPlannerView(
                        semester: calendarViewModel.currentSemester,
                        termBounds: calendarViewModel.termBoundsBySemesterCode[calendarViewModel.currentSemester.rawValue],
                        manager: flexDollarsManager,
                        themeColor: calendarViewModel.themeColor
                    )
                }
            }

            .sheet(isPresented: $showFlexDollarUpdate) {
                NavigationStack {
                    FlexDollarsBalanceUpdateView(
                        semester: calendarViewModel.currentSemester,
                        manager: flexDollarsManager,
                        themeColor: calendarViewModel.themeColor
                    )
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

            .sheet(item: $editingSemesterGPA) { semester in
                NavigationStack {
                    SemesterGPAOverrideEditorView(semester: semester)
                        .environmentObject(calendarViewModel)
                }
            }
        }
    }

    @ViewBuilder
    private func homeDashboardSection(_ section: HomeDashboardSection) -> some View {
        switch section {
        case .shuttleTracker:
            shuttleTrackerSection
        case .diningHours:
            diningHoursSection
        case .upcoming:
            upcomingSection
        case .mealSwipes:
            mealSwipesSection
        case .flexDollars:
            flexDollarsSection
        case .studyTimer:
            studyTimerSection
        }
    }

    private var shuttleTrackerSection: some View {
        Section {
            NavigationLink {
                ShuttleTrackerFeatureView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bus.fill")
                        .font(.title3)
                        .foregroundStyle(calendarViewModel.themeColor)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shuttle Tracker")
                            .font(.headline)
                        Text("Open live campus shuttle map")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Campus Tools")
        }
    }

    private var diningHoursSection: some View {
        Section {
            NavigationLink {
                DiningHoursView(themeColor: calendarViewModel.themeColor)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.title3)
                        .foregroundStyle(calendarViewModel.themeColor)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dining Hours")
                            .font(.headline)

                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            if favoriteDiningVenues.isEmpty {
                                let openCount = DiningHoursData.venues.filter {
                                    $0.status(at: context.date).isOpen
                                }.count

                                Text(openCount == 1 ? "1 location open right now" : "\(openCount) locations open right now")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(favoriteDiningVenues.prefix(3)), id: \.id) { venue in
                                        let status = venue.status(at: context.date)
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(status.isOpen ? Color.green : Color.secondary)
                                                .frame(width: 6, height: 6)
                                            Text("\(venue.name) · \(status.detailText)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Campus Dining")
        }
    }

    private var upcomingSection: some View {
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
                        onImportExamReminder: { examTitle, examDate, enrollmentID in
                            let prefill = CourseTask(
                                id: UUID(),
                                enrollmentID: enrollmentID,
                                title: examTitle,
                                kind: .exam,
                                dueDate: examDate,
                                reminderOffsetsMinutes: [10080, 1440, 60],
                                notes: "Imported from meeting block exam."
                            )
                            editingTask = prefill
                            showTaskEditor = true
                        },
                        onDeleteLMSItem: { event in
                            calendarViewModel.hideLMSImportedEvent(event)
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

                        if case .lmsCalendarEvent(let event, _) = item.source {
                            Button(role: .destructive) {
                                calendarViewModel.hideLMSImportedEvent(event)
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
                        .foregroundStyle(calendarViewModel.themeColor)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    showAllTasks = true
                } label: {
                    Text("View all")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .tint(calendarViewModel.themeColor)
        } header: {
            Text("Upcoming (Assignments + Exams)")
        }
    }

    private var mealSwipesSection: some View {
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
                            .foregroundStyle(Color.white.opacity(0.95))
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
                        .foregroundStyle(calendarViewModel.themeColor)
                }
                .buttonStyle(.bordered)
                .tint(calendarViewModel.themeColor)

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
    }

    private var studyTimerSection: some View {
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
    }

    private var flexDollarsSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 3600)) { context in
                let snapshot = FlexDollarPlanner.snapshot(
                    semester: calendarViewModel.currentSemester,
                    state: flexDollarsManager.state(for: calendarViewModel.currentSemester.rawValue),
                    termBounds: calendarViewModel.termBoundsBySemesterCode[calendarViewModel.currentSemester.rawValue],
                    now: context.date
                )

                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Balance")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(snapshot.balanceText)
                                    .font(.title3.weight(.bold))
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Safe pace")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(snapshot.weeklyBudgetText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(calendarViewModel.themeColor)
                            }
                        }

                        if let planName = snapshot.planName {
                            Text(planName)
                                .font(.subheadline.weight(.medium))
                        }

                        Text(snapshot.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Set your dining plan or current balance to start tracking flex dollars.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            if snapshot == nil {
                                showFlexDollarPlanner = true
                            } else {
                                showFlexDollarUpdate = true
                            }
                        } label: {
                            Label(snapshot == nil ? "Set up" : "Update", systemImage: "dollarsign.circle")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(calendarViewModel.themeColor)

                        if snapshot != nil {
                            Button {
                                showFlexDollarPlanner = true
                            } label: {
                                Label("Planner", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        } header: {
            Text("Flex Dollars")
        }
    }

    // MARK: - Upcoming merging (Tasks + Exam events)

    fileprivate enum UpcomingSource: Equatable {
        case task(CourseTask)
        case calendarExam(title: String, date: Date, enrollmentID: String?)
        case lmsCalendarEvent(StoredPersonalEvent, enrollmentID: String?)
    }

    fileprivate struct UpcomingItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let due: Date
        let icon: String
        let source: UpcomingSource
        let isAllDay: Bool

        var dueText: String {
            let df = DateFormatter()

            if isAllDay {
                df.dateFormat = "M/d"
                return df.string(from: due)
            }

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
            if isAllDay {
                let adjustedDue = Calendar.current.date(
                    bySettingHour: 23,
                    minute: 59,
                    second: 0,
                    of: due
                ) ?? due
                return taskRelativeDueText(to: adjustedDue)
            }
            return taskRelativeDueText(to: due)
        }
    }

    private func combinedUpcomingItems(days: Int) -> [UpcomingItem] {
        let examItems = upcomingExamItems(days: days)
        let lmsItems = upcomingLMSCalendarItems(days: days)

        // De-dupe custom exams when an official exam block already exists.
        let examTimes: Set<Int> = Set(examItems.map { Int($0.due.timeIntervalSince1970) })
        let officialExamDayKeys: Set<String> = Set(
            examItems.compactMap { item in
                guard case .calendarExam(_, _, let enrollmentID) = item.source,
                      let enrollmentID else {
                    return nil
                }
                return examDayKey(enrollmentID: enrollmentID, date: item.due)
            }
        )

        let taskItems: [UpcomingItem] = tasksManager.upcomingTasks(withinDays: days)
            // ✅ hide tasks from other semesters in "Upcoming"
            .filter { t in
                isEnrollmentInCurrentSemester(t.enrollmentID)
            }
            .filter { t in
                guard t.kind == .exam else { return true }
                if examTimes.contains(Int(t.dueDate.timeIntervalSince1970)) {
                    return false
                }
                guard let enrollmentID = t.enrollmentID else { return true }
                return !officialExamDayKeys.contains(examDayKey(enrollmentID: enrollmentID, date: t.dueDate))
            }
            .map { t in
                let subtitle = subtitleForTask(t)
                return UpcomingItem(
                    id: "task-\(t.id.uuidString)",
                    title: t.title,
                    subtitle: subtitle,
                    due: t.dueDate,
                    icon: t.kind.systemImage,
                    source: .task(t),
                    isAllDay: false
                )
            }

        return (taskItems + examItems + lmsItems)
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
                        source: .calendarExam(title: cleanTitle, date: ev.startDate, enrollmentID: ev.enrollmentID),
                        isAllDay: false
                    )
                )
            }

            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
        }

        return items.sorted { $0.due < $1.due }
    }

    private func upcomingLMSCalendarItems(days: Int) -> [UpcomingItem] {
        let calendar = Calendar.current
        let now = Date()
        let end = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let currentTermBounds = currentSemesterCode.flatMap { calendarViewModel.termBoundsBySemesterCode[$0] }

        return calendarViewModel.lmsImportedPersonalEvents()
            .filter { event in
                let dueDate = displayDueDate(forLMSImportedEvent: event)
                guard dueDate >= now && dueDate <= end else { return false }
                guard let currentTermBounds else { return true }

                let dayStart = calendar.startOfDay(for: event.startDate)
                let intervalStart = calendar.startOfDay(for: currentTermBounds.start)
                let intervalEnd = calendar.startOfDay(for: currentTermBounds.end)
                return intervalStart <= dayStart && dayStart <= intervalEnd
            }
            .map { event in
                let matchedEnrollment = matchedEnrollmentForLMSImportedEvent(event)
                return UpcomingItem(
                    id: "lms-\(event.id.uuidString)",
                    title: event.title,
                    subtitle: subtitleForLMSImportedEvent(event, matchedEnrollment: matchedEnrollment),
                    due: displayDueDate(forLMSImportedEvent: event),
                    icon: "calendar.badge.clock",
                    source: .lmsCalendarEvent(event, enrollmentID: matchedEnrollment?.id),
                    isAllDay: event.isAllDay ?? false
                )
            }
    }

    private func displayDueDate(forLMSImportedEvent event: StoredPersonalEvent) -> Date {
        guard event.isAllDay ?? false else { return event.startDate }
        return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: event.startDate) ?? event.startDate
    }

    private func subtitleForLMSImportedEvent(_ event: StoredPersonalEvent, matchedEnrollment: EnrolledCourse?) -> String {
        if let matchedEnrollment {
            return "Blackboard • \(matchedEnrollment.course.title)"
        }
        if !event.location.isEmpty {
            return "Blackboard • \(event.location)"
        }
        return "Blackboard"
    }

    private func matchedEnrollmentForLMSImportedEvent(_ event: StoredPersonalEvent) -> EnrolledCourse? {
        if let storedMatch = calendarViewModel.enrollment(withID: event.relatedEnrollmentID) {
            return storedMatch
        }

        let prioritizedEnrollments: [EnrolledCourse]
        if let currentSemesterCode {
            let current = calendarViewModel.enrolledCourses.filter { $0.semesterCode == currentSemesterCode }
            prioritizedEnrollments = current.isEmpty ? calendarViewModel.enrolledCourses : current
        } else {
            prioritizedEnrollments = calendarViewModel.enrolledCourses
        }

        let upperTitle = event.title.uppercased()
        let canonicalID = canonicalCourseID(event.title)
        if let canonicalMatch = prioritizedEnrollments.first(where: { $0.course.id == canonicalID }) {
            return canonicalMatch
        }

        if let embeddedCodeMatch = prioritizedEnrollments.first(where: { enrollment in
            let subject = enrollment.course.subject.uppercased()
            let number = enrollment.course.number.uppercased()
            let variants = [
                "\(subject) \(number)",
                "\(subject)-\(number)",
                "\(subject)\(number)"
            ]
            return variants.contains(where: { upperTitle.contains($0) })
        }) {
            return embeddedCodeMatch
        }

        let normalizedTitle = normalizedUpcomingSearchText(event.title)
        return prioritizedEnrollments.first { enrollment in
            let courseName = normalizedUpcomingSearchText(enrollment.course.title)
            return !courseName.isEmpty && normalizedTitle.contains(courseName)
        }
    }

    private func normalizedUpcomingSearchText(_ text: String) -> String {
        let lowered = text.lowercased()
        let normalizedScalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(normalizedScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func timeRangeText(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return "\(df.string(from: start))–\(df.string(from: end))"
    }

    private func officialExamStartDate(for enrollmentID: String, onSameDayAs date: Date) -> Date? {
        let calendar = Calendar.current
        return calendarViewModel.events
            .filter { event in
                event.kind == .classMeeting &&
                event.title.hasPrefix("★") &&
                event.enrollmentID == enrollmentID &&
                calendar.isDate(event.startDate, inSameDayAs: date)
            }
            .map(\.startDate)
            .min()
    }

    private func normalizedExamTask(_ task: CourseTask) -> CourseTask {
        guard task.kind == .exam,
              let enrollmentID = task.enrollmentID,
              let officialExamStart = officialExamStartDate(for: enrollmentID, onSameDayAs: task.dueDate) else {
            return task
        }

        var normalized = task
        normalized.dueDate = officialExamStart
        return normalized
    }

    private func examDayKey(enrollmentID: String, date: Date) -> String {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return "\(enrollmentID)|\(Int(startOfDay.timeIntervalSince1970))"
    }

    private func normalizeExistingExamTasksIfNeeded() {
        for task in tasksManager.tasks where task.kind == .exam {
            let normalized = normalizedExamTask(task)
            if normalized != task {
                tasksManager.update(normalized)
            }
        }
    }
}

// MARK: - Upcoming Row (Home screen)

private struct UpcomingRow: View {
    let item: HomeView.UpcomingItem
    let themeColor: Color

    let onEditTask: (CourseTask) -> Void
    let onDeleteTask: (CourseTask) -> Void
    let onImportExamReminder: (_ title: String, _ date: Date, _ enrollmentID: String?) -> Void
    let onDeleteLMSItem: (StoredPersonalEvent) -> Void

    @ViewBuilder
    private var rowContent: some View {
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(themeColor.opacity(0.95))

            if case .task(let t) = item.source {
                Button {
                    onEditTask(t)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }

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

            if case .lmsCalendarEvent(let event, _) = item.source {
                Button(role: .destructive) {
                    onDeleteLMSItem(event)
                } label: {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(.leading, 4)
            }

            // ✅ Only the bell opens the editor for exam blocks
            if case .calendarExam(let title, let date, let enrollmentID) = item.source {
                Button {
                    onImportExamReminder(title, date, enrollmentID)
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
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    let enrollments: [EnrolledCourse]
    let themeColor: Color
    let calendarExamItems: [HomeView.UpcomingItem]
    let lmsCalendarItems: [HomeView.UpcomingItem]

    @Environment(\.dismiss) private var dismiss
    @State private var showTaskEditor = false
    @State private var editingTask: CourseTask? = nil

    private var upcomingTasks: [CourseTask] {
        tasksManager.tasks
            .filter { $0.dueDate >= Date() }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private var oldTasks: [CourseTask] {
        tasksManager.tasks
            .filter { $0.dueDate < Date() }
            .sorted { $0.dueDate > $1.dueDate }
    }

    private func officialExamStartDate(for enrollmentID: String, onSameDayAs date: Date) -> Date? {
        calendarExamItems
            .compactMap { item -> Date? in
                guard case .calendarExam(_, let examDate, let itemEnrollmentID) = item.source,
                      itemEnrollmentID == enrollmentID,
                      Calendar.current.isDate(examDate, inSameDayAs: date) else {
                    return nil
                }
                return examDate
            }
            .min()
    }

    private func normalizedExamTask(_ task: CourseTask) -> CourseTask {
        guard task.kind == .exam,
              let enrollmentID = task.enrollmentID,
              let officialExamStart = officialExamStartDate(for: enrollmentID, onSameDayAs: task.dueDate) else {
            return task
        }

        var normalized = task
        normalized.dueDate = officialExamStart
        return normalized
    }

    var body: some View {
        List {
            Section("Assignments / Custom Items") {
                if upcomingTasks.isEmpty {
                    Text("No tasks yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(upcomingTasks) { t in
                        taskRow(t)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    tasksManager.delete(t)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !oldTasks.isEmpty {
                Section("Old Assignments / Items") {
                    ForEach(oldTasks) { t in
                        taskRow(t)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    tasksManager.delete(t)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
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
                                let enrollmentID: String?
                                if case .calendarExam(_, _, let itemEnrollmentID) = item.source {
                                    enrollmentID = itemEnrollmentID
                                } else {
                                    enrollmentID = nil
                                }

                                let prefill = CourseTask(
                                    id: UUID(),
                                    enrollmentID: enrollmentID,
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

            Section("Blackboard Calendar") {
                if lmsCalendarItems.isEmpty {
                    Text("No upcoming Blackboard items.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lmsCalendarItems.prefix(50), id: \.id) { item in
                        UpcomingRow(
                            item: item,
                            themeColor: themeColor,
                            onEditTask: { _ in },
                            onDeleteTask: { _ in },
                            onImportExamReminder: { _, _, _ in },
                            onDeleteLMSItem: { event in
                                calendarViewModel.hideLMSImportedEvent(event)
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if case let .lmsCalendarEvent(event, _) = item.source {
                                Button(role: .destructive) {
                                    calendarViewModel.hideLMSImportedEvent(event)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
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
                            let normalized = normalizedExamTask(saved)
                            if tasksManager.tasks.contains(where: { $0.id == normalized.id }) {
                                tasksManager.update(normalized)
                            } else {
                                tasksManager.add(normalized)
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

    @ViewBuilder
    private func taskRow(_ t: CourseTask) -> some View {
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

                Text(taskRelativeDueText(to: t.dueDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(dateText(t.dueDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reminder edit sheet helper

private struct ReminderEditItem: Identifiable, Equatable {
    let minutes: Int
    var id: Int { minutes }
}

private struct SemesterGPAOverrideEditorView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    let semester: Semester

    @State private var gpa: Double = 0
    @State private var credits: Double = 16

    var body: some View {
        Form {
            Section(semester.displayName) {
                HStack {
                    Text("Semester GPA")
                    Spacer()
                    TextField("0.00", value: $gpa, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }

                HStack {
                    Text("Credits")
                    Spacer()
                    TextField("0", value: $credits, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }

            Section {
                Button("Save") {
                    calendarViewModel.setSemesterGPAOverride(
                        for: semester.rawValue,
                        gpa: max(0, min(4, gpa)),
                        credits: max(0, credits)
                    )
                    dismiss()
                }

                if calendarViewModel.semesterGPAOverride(for: semester.rawValue) != nil {
                    Button(role: .destructive) {
                        calendarViewModel.clearSemesterGPAOverride(for: semester.rawValue)
                        dismiss()
                    } label: {
                        Text("Clear Override")
                    }
                }
            }
        }
        .navigationTitle("Semester GPA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            if let override = calendarViewModel.semesterGPAOverride(for: semester.rawValue) {
                gpa = override.gpa
                credits = override.credits
            }
        }
    }
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
