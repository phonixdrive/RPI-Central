import Foundation
import SwiftUI

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

extension Notification.Name {
    static let appStateSyncDidApplyLocalState = Notification.Name("appStateSyncDidApplyLocalState")
}

enum SyncISO8601 {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }
}

struct PhoneWebAppSettings: Codable {
    var themeColor: String
    var appearanceMode: String
    var currentSemester: String
    var visibleSemester: String
    var academicHistoryStartSemester: String
    var enforcePrerequisites: Bool
    var lmsCalendarFeedURL: String
    var lmsCalendarAutoDailySyncEnabled: Bool
    var lmsCalendarLastSyncAt: String?
    var shuttleRefreshIntervalSeconds: Int
    var socialFeedRefreshIntervalSeconds: Int
    var socialFeedNotificationsEnabled: Bool
    var socialDemoToolsEnabled: Bool
    var showCampusWideGroup: Bool
    var homeSectionOrder: [String]
    var hiddenHomeSections: [String]
    var calendarDisplayMode: String
}

struct PhoneWebMeetingOverride: Codable {
    var type: String
}

struct PhoneWebMeeting: Codable {
    var days: [String]
    var start: String
    var end: String
    var location: String

    init(days: [String], start: String, end: String, location: String) {
        self.days = days
        self.start = start
        self.end = end
        self.location = location
    }

    init(_ meeting: Meeting) {
        self.days = meeting.days.map(\.rawValue)
        self.start = meeting.start
        self.end = meeting.end
        self.location = meeting.location
    }

    var meetingValue: Meeting {
        Meeting(
            days: days.compactMap(Weekday.init(rawValue:)),
            start: start,
            end: end,
            location: location
        )
    }
}

struct PhoneWebCourseSection: Codable {
    var id: String
    var crn: Int?
    var section: String
    var instructor: String
    var meetings: [PhoneWebMeeting]
    var prerequisitesText: String
    var prerequisiteExpression: PrerequisiteExpression?
    var credits: Double

    init(_ section: CourseSection) {
        self.id = section.id
        self.crn = section.crn
        self.section = section.section
        self.instructor = section.instructor
        self.meetings = section.meetings.map(PhoneWebMeeting.init)
        self.prerequisitesText = section.prerequisitesText
        self.prerequisiteExpression = section.prerequisiteExpression
        self.credits = section.credits
    }

    var courseSectionValue: CourseSection {
        CourseSection(
            crn: crn,
            section: section,
            instructor: instructor,
            meetings: meetings.map(\.meetingValue),
            prerequisitesText: prerequisitesText,
            prerequisiteExpression: prerequisiteExpression,
            credits: credits
        )
    }
}

struct PhoneWebCourse: Codable {
    var id: String
    var subject: String
    var number: String
    var title: String
    var description: String
    var sections: [PhoneWebCourseSection]

    init(_ course: Course) {
        self.id = course.id
        self.subject = course.subject
        self.number = course.number
        self.title = course.title
        self.description = course.description
        self.sections = course.sections.map(PhoneWebCourseSection.init)
    }

    var courseValue: Course {
        Course(
            subject: subject,
            number: number,
            title: title,
            description: description,
            sections: sections.map(\.courseSectionValue)
        )
    }
}

struct PhoneWebEnrolledCourse: Codable {
    var id: String
    var course: PhoneWebCourse
    var section: PhoneWebCourseSection
    var semesterCode: String

    init(_ enrollment: EnrolledCourse) {
        self.id = enrollment.id
        self.course = PhoneWebCourse(enrollment.course)
        self.section = PhoneWebCourseSection(enrollment.section)
        self.semesterCode = enrollment.semesterCode
    }

    var enrolledCourseValue: EnrolledCourse {
        EnrolledCourse(
            id: id,
            course: course.courseValue,
            section: section.courseSectionValue,
            semesterCode: semesterCode
        )
    }
}

struct PhoneWebCourseTask: Codable {
    var id: String
    var enrollmentID: String?
    var title: String
    var kind: String
    var dueDate: String
    var reminderOffsetsMinutes: [Int]
    var notes: String

    init(_ task: CourseTask) {
        self.id = task.id.uuidString
        self.enrollmentID = task.enrollmentID
        self.title = task.title
        self.kind = task.kind.rawValue
        self.dueDate = SyncISO8601.string(from: task.dueDate)
        self.reminderOffsetsMinutes = task.reminderOffsetsMinutes
        self.notes = task.notes
    }

    var courseTaskValue: CourseTask? {
        guard
            let dueDateValue = SyncISO8601.date(from: dueDate),
            let kindValue = CourseTaskKind(rawValue: kind)
        else {
            return nil
        }

        return CourseTask(
            id: UUID(uuidString: id) ?? UUID(),
            enrollmentID: enrollmentID,
            title: title,
            kind: kindValue,
            dueDate: dueDateValue,
            reminderOffsetsMinutes: reminderOffsetsMinutes,
            notes: notes
        )
    }
}

struct PhoneWebMealPlanState: Codable {
    var swipesPerWeek: Int
    var usedThisWeek: Int
    var resetWeekday: Int
    var lastReset: String

    init(_ state: MealPlanState) {
        self.swipesPerWeek = state.swipesPerWeek
        self.usedThisWeek = state.usedThisWeek
        self.resetWeekday = state.resetWeekday
        self.lastReset = SyncISO8601.string(from: state.lastReset)
    }

    var mealPlanValue: MealPlanState {
        MealPlanState(
            swipesPerWeek: swipesPerWeek,
            usedThisWeek: usedThisWeek,
            resetWeekday: resetWeekday,
            lastReset: SyncISO8601.date(from: lastReset) ?? Date()
        )
    }
}

struct PhoneWebPomodoroPreset: Codable {
    var focusMinutes: Int
    var breakMinutes: Int

    init(_ preset: PomodoroPreset) {
        self.focusMinutes = preset.focusMinutes
        self.breakMinutes = preset.breakMinutes
    }

    var pomodoroPresetValue: PomodoroPreset {
        PomodoroPreset(
            focusMinutes: focusMinutes,
            breakMinutes: breakMinutes
        )
    }
}

struct PhoneWebFlexDollarState: Codable {
    var selectedPlan: String?
    var currentBalance: Double?

    init(_ state: FlexDollarState) {
        self.selectedPlan = state.selectedPlan?.rawValue
        self.currentBalance = state.currentBalance
    }

    var flexDollarStateValue: FlexDollarState {
        FlexDollarState(
            selectedPlan: selectedPlan.flatMap(FlexDollarMealPlan.init(rawValue:)),
            currentBalance: currentBalance
        )
    }
}

struct PhoneWebGradeSubItem: Codable {
    var id: String
    var title: String
    var earned: Double
    var possible: Double

    init(_ item: GradeSubItem) {
        self.id = item.id.uuidString
        self.title = item.title
        self.earned = item.earned
        self.possible = item.possible
    }

    var gradeSubItemValue: GradeSubItem {
        GradeSubItem(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            earned: earned,
            possible: possible
        )
    }
}

struct PhoneWebGradeCategory: Codable {
    var id: String
    var name: String
    var weightPercent: Double
    var inputMode: String
    var scorePercent: Double
    var earnedPoints: Double
    var possiblePoints: Double
    var items: [PhoneWebGradeSubItem]

    init(_ category: GradeCategory) {
        self.id = category.id.uuidString
        self.name = category.name
        self.weightPercent = category.weightPercent
        self.inputMode = category.inputMode.rawValue
        self.scorePercent = category.scorePercent
        self.earnedPoints = category.earnedPoints
        self.possiblePoints = category.possiblePoints
        self.items = category.items.map(PhoneWebGradeSubItem.init)
    }

    var gradeCategoryValue: GradeCategory {
        var category = GradeCategory(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            weightPercent: weightPercent,
            scoreMode: inputMode == "points" ? .points : .percent,
            scorePercent: scorePercent,
            earnedPoints: earnedPoints,
            possiblePoints: possiblePoints,
            usesSubItems: inputMode == "subItems",
            items: items.map(\.gradeSubItemValue)
        )
        category.setInputMode(CategoryInputMode(rawValue: inputMode) ?? .percent)
        return category
    }
}

struct PhoneWebGradeBreakdownLite: Codable {
    var letter: String?
    var percent: Double?
    var notes: String?
    var categories: [PhoneWebGradeCategory]?
    var gradeCutoffs: GradeCutoffs?
    var isAdvancedMode: Bool?
    var simpleScorePercent: Double?
    var simpleInputMode: String?
    var simpleLetterGrade: String?
    var creditsOverride: Double?

    init(_ breakdown: GradeBreakdown) {
        self.letter = breakdown.overrideLetterGrade?.rawValue
        self.percent = breakdown.currentGradePercent
        self.notes = nil
        self.categories = breakdown.categories.map(PhoneWebGradeCategory.init)
        self.gradeCutoffs = breakdown.gradeCutoffs
        self.isAdvancedMode = breakdown.isAdvancedMode
        self.simpleScorePercent = breakdown.simpleScorePercent
        self.simpleInputMode = breakdown.simpleInputMode.rawValue
        self.simpleLetterGrade = breakdown.simpleLetterGrade?.rawValue
        self.creditsOverride = breakdown.creditsOverride
    }

    var gradeBreakdownValue: GradeBreakdown {
        GradeBreakdown(
            categories: (categories ?? []).map(\.gradeCategoryValue),
            overrideLetterGrade: letter.flatMap(LetterGrade.init(rawValue:)),
            creditsOverride: creditsOverride,
            gradeCutoffs: gradeCutoffs ?? .standard,
            isAdvancedMode: isAdvancedMode ?? true,
            simpleScorePercent: simpleScorePercent,
            simpleInputMode: SimpleGradeInputMode(rawValue: simpleInputMode ?? "percent") ?? .percent,
            simpleLetterGrade: simpleLetterGrade.flatMap(LetterGrade.init(rawValue:))
        )
    }
}

struct PhoneWebPersonalEvent: Codable {
    var id: String
    var title: String
    var location: String
    var startDate: String
    var endDate: String
    var seriesId: String?
    var shareMode: String
    var sharedFriendIDs: [String]
    var sharedGroupIDs: [String]
    var externalSourceKind: String?
    var externalSourceID: String?
    var relatedEnrollmentID: String?
    var isAllDay: Bool?

    init(_ event: StoredPersonalEvent) {
        self.id = event.id.uuidString
        self.title = event.title
        self.location = event.location
        self.startDate = SyncISO8601.string(from: event.startDate)
        self.endDate = SyncISO8601.string(from: event.endDate)
        self.seriesId = event.seriesID?.uuidString
        self.shareMode = event.shareMode.rawValue
        self.sharedFriendIDs = event.sharedFriendIDs
        self.sharedGroupIDs = event.sharedGroupIDs
        self.externalSourceKind = event.externalSourceKind
        self.externalSourceID = event.externalSourceID
        self.relatedEnrollmentID = event.relatedEnrollmentID
        self.isAllDay = event.isAllDay
    }

    var storedEventValue: StoredPersonalEvent? {
        guard
            let startDateValue = SyncISO8601.date(from: startDate),
            let endDateValue = SyncISO8601.date(from: endDate),
            let shareModeValue = PersonalEventShareMode(rawValue: shareMode)
        else {
            return nil
        }

        return StoredPersonalEvent(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            location: location,
            startDate: startDateValue,
            endDate: endDateValue,
            seriesID: seriesId.flatMap(UUID.init(uuidString:)),
            shareMode: shareModeValue,
            sharedFriendIDs: sharedFriendIDs,
            sharedGroupIDs: sharedGroupIDs,
            externalSourceKind: externalSourceKind,
            externalSourceID: externalSourceID,
            relatedEnrollmentID: relatedEnrollmentID,
            isAllDay: isAllDay
        )
    }
}

struct PhoneWebCalendarSyncSnapshot: Codable {
    var settings: PhoneWebAppSettings
    var enrollments: [PhoneWebEnrolledCourse]
    var personalEvents: [PhoneWebPersonalEvent]
    var gradesByEnrollmentID: [String: String]
    var semesterGpaOverrides: [String: SemesterGPAOverride]
    var notesByEnrollmentID: [String: String]
    var meetingOverridesByKey: [String: PhoneWebMeetingOverride]
    var examDatesByMeetingKey: [String: [Double]]
    var assumedPrereqsByCourseID: [String: [String]]
    var hiddenLMSCalendarEventSourceIDs: [String]
}

struct PhoneWebAppState: Codable {
    var settings: PhoneWebAppSettings
    var enrollments: [PhoneWebEnrolledCourse]
    var tasks: [PhoneWebCourseTask]
    var mealPlan: PhoneWebMealPlanState
    var flexBySemester: [String: PhoneWebFlexDollarState]
    var pomodoroPreset: PhoneWebPomodoroPreset
    var personalEvents: [PhoneWebPersonalEvent]
    var gradesByEnrollmentID: [String: String]
    var gradeDetailsByEnrollmentID: [String: PhoneWebGradeBreakdownLite]
    var semesterGpaOverrides: [String: SemesterGPAOverride]
    var notesByEnrollmentID: [String: String]
    var meetingOverridesByKey: [String: PhoneWebMeetingOverride]
    var examDatesByMeetingKey: [String: [Double]]
    var assumedPrereqsByCourseID: [String: [String]]
    var hiddenLMSCalendarEventSourceIDs: [String]

    init(
        calendarSnapshot: PhoneWebCalendarSyncSnapshot,
        tasks: [PhoneWebCourseTask],
        mealPlan: PhoneWebMealPlanState,
        flexBySemester: [String: PhoneWebFlexDollarState],
        pomodoroPreset: PhoneWebPomodoroPreset,
        gradeDetailsByEnrollmentID: [String: PhoneWebGradeBreakdownLite]
    ) {
        self.settings = calendarSnapshot.settings
        self.enrollments = calendarSnapshot.enrollments
        self.tasks = tasks
        self.mealPlan = mealPlan
        self.flexBySemester = flexBySemester
        self.pomodoroPreset = pomodoroPreset
        self.personalEvents = calendarSnapshot.personalEvents
        self.gradesByEnrollmentID = calendarSnapshot.gradesByEnrollmentID
        self.gradeDetailsByEnrollmentID = gradeDetailsByEnrollmentID
        self.semesterGpaOverrides = calendarSnapshot.semesterGpaOverrides
        self.notesByEnrollmentID = calendarSnapshot.notesByEnrollmentID
        self.meetingOverridesByKey = calendarSnapshot.meetingOverridesByKey
        self.examDatesByMeetingKey = calendarSnapshot.examDatesByMeetingKey
        self.assumedPrereqsByCourseID = calendarSnapshot.assumedPrereqsByCourseID
        self.hiddenLMSCalendarEventSourceIDs = calendarSnapshot.hiddenLMSCalendarEventSourceIDs
    }

    var calendarSnapshot: PhoneWebCalendarSyncSnapshot {
        PhoneWebCalendarSyncSnapshot(
            settings: settings,
            enrollments: enrollments,
            personalEvents: personalEvents,
            gradesByEnrollmentID: gradesByEnrollmentID,
            semesterGpaOverrides: semesterGpaOverrides,
            notesByEnrollmentID: notesByEnrollmentID,
            meetingOverridesByKey: meetingOverridesByKey,
            examDatesByMeetingKey: examDatesByMeetingKey,
            assumedPrereqsByCourseID: assumedPrereqsByCourseID,
            hiddenLMSCalendarEventSourceIDs: hiddenLMSCalendarEventSourceIDs
        )
    }
}

struct PhoneWebCloudBackupSummary: Identifiable, Codable {
    var id: String
    var label: String
    var createdAt: String
    var source: String
    var appStateUpdatedAt: String
}

struct PhoneWebCloudBackupDocument: Codable {
    var id: String
    var label: String
    var createdAt: String
    var source: String
    var appStateUpdatedAt: String
    var schemaVersion: Int
    var appState: PhoneWebAppState
}

@MainActor
final class AppStateSyncManager: ObservableObject {
    @Published private(set) var cloudSyncReady = false
    @Published private(set) var cloudSyncBusy = false
    @Published private(set) var cloudSyncMessage: String?
    @Published private(set) var cloudSyncError: String?
    @Published private(set) var cloudSnapshotUpdatedAt: String?
    @Published private(set) var cloudBackups: [PhoneWebCloudBackupSummary] = []

    private let backupSchemaVersion = 1
    private let maxCloudBackups = 18
    private let shuttleRefreshKey = "shuttle_tracker_refresh_interval_seconds"
    private let showCampusWideGroupKey = "social_show_campus_wide_group"

    func refresh() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let userID = currentUserIDIfReady() else {
            cloudSyncReady = false
            cloudSnapshotUpdatedAt = nil
            cloudBackups = []
            return
        }

        cloudSyncReady = true
        do {
            async let snapshotTask = loadCloudSnapshot(userID: userID)
            async let backupsTask = loadCloudBackups(userID: userID)
            let (snapshot, backups) = try await (snapshotTask, backupsTask)
            cloudSnapshotUpdatedAt = snapshot?.updatedAt
            cloudBackups = backups
        } catch {
            cloudSyncError = message(for: error)
        }
#else
        cloudSyncReady = false
#endif
    }

    func createCloudBackup(
        calendarViewModel: CalendarViewModel
    ) async -> Bool {
        await runAction {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let userID = try requireUserID()
            let appState = buildCurrentAppState(calendarViewModel: calendarViewModel)
            try await createBackupRecord(
                userID: userID,
                appState: appState,
                label: "Before Recovery Backup (Current iPhone)",
                source: "ios-manual",
                appStateUpdatedAt: SyncISO8601.string(from: Date())
            )
            try await refreshAfterMutation(userID: userID)
            cloudSyncMessage = "Recovery backup saved."
            return true
#else
            throw SyncManagerError.firebaseUnavailable
#endif
        } ?? false
    }

    func pushPhoneToCloud(
        calendarViewModel: CalendarViewModel,
        socialManager: SocialManager? = nil
    ) async -> Bool {
        await runAction {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let userID = try requireUserID()
            let appState = buildCurrentAppState(calendarViewModel: calendarViewModel)

            try await createBackupRecord(
                userID: userID,
                appState: appState,
                label: "Before Save (Current iPhone)",
                source: "ios-local",
                appStateUpdatedAt: SyncISO8601.string(from: Date())
            )
            if let cloudSnapshot = try await loadCloudSnapshot(userID: userID) {
                try await createBackupRecord(
                    userID: userID,
                    appState: cloudSnapshot.appState,
                    label: "Saved Copy Replaced by Save",
                    source: "cloud:\(cloudSnapshot.source)",
                    appStateUpdatedAt: cloudSnapshot.updatedAt
                )
            }

            let updatedAt = SyncISO8601.string(from: Date())
            try await writeCloudSnapshot(
                userID: userID,
                appState: appState,
                updatedAt: updatedAt,
                source: "ios-manual-push"
            )

            if let socialManager {
                await socialManager.syncCourseCommunities(from: calendarViewModel)
                await socialManager.syncSchedule(from: calendarViewModel)
            }

            try await refreshAfterMutation(userID: userID)
            cloudSyncMessage = "This phone is now the latest saved copy."
            return true
#else
            throw SyncManagerError.firebaseUnavailable
#endif
        } ?? false
    }

    func pullCloudToPhone(
        calendarViewModel: CalendarViewModel,
        socialManager: SocialManager? = nil
    ) async -> Bool {
        await runAction {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let userID = try requireUserID()
            guard let cloudSnapshot = try await loadCloudSnapshot(userID: userID) else {
                throw SyncManagerError.noCloudSnapshot
            }

            let localAppState = buildCurrentAppState(calendarViewModel: calendarViewModel)
            try await createBackupRecord(
                userID: userID,
                appState: localAppState,
                label: "Before Update (Current iPhone)",
                source: "ios-local",
                appStateUpdatedAt: SyncISO8601.string(from: Date())
            )

            applyAppState(cloudSnapshot.appState, to: calendarViewModel)
            NotificationCenter.default.post(name: .appStateSyncDidApplyLocalState, object: nil)

            if let socialManager {
                await socialManager.syncCourseCommunities(from: calendarViewModel)
                await socialManager.syncSchedule(from: calendarViewModel)
            }

            try await refreshAfterMutation(userID: userID)
            cloudSyncMessage = "This phone now matches the latest saved copy."
            return true
#else
            throw SyncManagerError.firebaseUnavailable
#endif
        } ?? false
    }

    func restoreCloudBackup(
        _ backupID: String,
        calendarViewModel: CalendarViewModel,
        socialManager: SocialManager? = nil
    ) async -> Bool {
        await runAction {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let userID = try requireUserID()
            let localAppState = buildCurrentAppState(calendarViewModel: calendarViewModel)
            try await createBackupRecord(
                userID: userID,
                appState: localAppState,
                label: "Before Restore (Current iPhone)",
                source: "ios-local",
                appStateUpdatedAt: SyncISO8601.string(from: Date())
            )

            if let cloudSnapshot = try await loadCloudSnapshot(userID: userID) {
                try await createBackupRecord(
                    userID: userID,
                    appState: cloudSnapshot.appState,
                    label: "Saved Copy Replaced by Restore",
                    source: "cloud:\(cloudSnapshot.source)",
                    appStateUpdatedAt: cloudSnapshot.updatedAt
                )
            }

            let backupDocument = try await loadBackupDocument(userID: userID, backupID: backupID)
            let restoredAt = SyncISO8601.string(from: Date())
            try await writeCloudSnapshot(
                userID: userID,
                appState: backupDocument.appState,
                updatedAt: restoredAt,
                source: "restore:\(backupID)"
            )

            applyAppState(backupDocument.appState, to: calendarViewModel)
            NotificationCenter.default.post(name: .appStateSyncDidApplyLocalState, object: nil)

            if let socialManager {
                await socialManager.syncCourseCommunities(from: calendarViewModel)
                await socialManager.syncSchedule(from: calendarViewModel)
            }

            try await refreshAfterMutation(userID: userID)
            cloudSyncMessage = "Recovery backup restored."
            return true
#else
            throw SyncManagerError.firebaseUnavailable
#endif
        } ?? false
    }

    func deleteCloudBackup(_ backupID: String) async -> Bool {
        await runAction {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let userID = try requireUserID()
            try await deleteDocument(firestore.collection("users").document(userID).collection("appBackups").document(backupID))
            try await refreshAfterMutation(userID: userID)
            cloudSyncMessage = "Recovery backup deleted."
            return true
#else
            throw SyncManagerError.firebaseUnavailable
#endif
        } ?? false
    }

    private func buildCurrentAppState(calendarViewModel: CalendarViewModel) -> PhoneWebAppState {
        let shuttleRefreshInterval = max(1, UserDefaults.standard.object(forKey: shuttleRefreshKey) as? Int ?? 5)
        let showCampusWideGroup = UserDefaults.standard.object(forKey: showCampusWideGroupKey) as? Bool ?? true

        let calendarSnapshot = calendarViewModel.exportSyncSnapshot(
            shuttleRefreshIntervalSeconds: shuttleRefreshInterval,
            showCampusWideGroup: showCampusWideGroup
        )

        let gradeDetails = GradeBreakdownSyncStore.loadAll().mapValues(PhoneWebGradeBreakdownLite.init)

        return PhoneWebAppState(
            calendarSnapshot: calendarSnapshot,
            tasks: TasksManager.loadStoredTasks().map(PhoneWebCourseTask.init),
            mealPlan: PhoneWebMealPlanState(MealPlanManager.loadStoredState()),
            flexBySemester: FlexDollarsManager.loadStoredStates().mapValues(PhoneWebFlexDollarState.init),
            pomodoroPreset: PhoneWebPomodoroPreset(PomodoroSettingsManager.loadStoredPreset()),
            gradeDetailsByEnrollmentID: gradeDetails
        )
    }

    private func applyAppState(_ appState: PhoneWebAppState, to calendarViewModel: CalendarViewModel) {
        calendarViewModel.applySyncSnapshot(appState.calendarSnapshot)
        GradeBreakdownSyncStore.replaceAll(
            appState.gradeDetailsByEnrollmentID.mapValues(\.gradeBreakdownValue)
        )
        TasksManager.replaceStoredTasks(appState.tasks.compactMap(\.courseTaskValue))
        MealPlanManager.replaceStoredState(appState.mealPlan.mealPlanValue)
        FlexDollarsManager.replaceStoredStates(appState.flexBySemester.mapValues(\.flexDollarStateValue))
        PomodoroSettingsManager.replaceStoredPreset(appState.pomodoroPreset.pomodoroPresetValue)
    }

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var firestore: Firestore { Firestore.firestore() }

    private func currentUserIDIfReady() -> String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    private func requireUserID() throws -> String {
        guard let userID = currentUserIDIfReady() else {
            throw SyncManagerError.notSignedIn
        }
        return userID
    }

    private func refreshAfterMutation(userID: String) async throws {
        let snapshot = try await loadCloudSnapshot(userID: userID)
        let backups = try await loadCloudBackups(userID: userID)
        cloudSnapshotUpdatedAt = snapshot?.updatedAt
        cloudBackups = backups
        cloudSyncReady = true
    }

    private func loadCloudSnapshot(userID: String) async throws -> (appState: PhoneWebAppState, updatedAt: String, source: String)? {
        let snapshot = try await getDocument(firestore.collection("users").document(userID))
        let data = snapshot.data()
        guard snapshot.exists, let data else {
            return nil
        }
        guard let appStateObject = data["webAppState"] else {
            return nil
        }

        let appState = try decodeJSONObject(PhoneWebAppState.self, from: appStateObject)
        let updatedAt = data["webAppStateUpdatedAt"] as? String ?? SyncISO8601.string(from: Date())
        let source = data["webAppStateSource"] as? String ?? "cloud"
        return (appState, updatedAt, source)
    }

    private func loadCloudBackups(userID: String) async throws -> [PhoneWebCloudBackupSummary] {
        let snapshot = try await getDocuments(
            firestore.collection("users")
                .document(userID)
                .collection("appBackups")
                .order(by: "createdAt", descending: true)
                .limit(to: maxCloudBackups)
        )

        return try snapshot.documents.compactMap { document in
            let data = document.data()
            let decoded = try decodeJSONObject(PhoneWebCloudBackupSummary.self, from: data)
            return PhoneWebCloudBackupSummary(
                id: document.documentID,
                label: decoded.label,
                createdAt: decoded.createdAt,
                source: decoded.source,
                appStateUpdatedAt: decoded.appStateUpdatedAt
            )
        }
    }

    private func loadBackupDocument(userID: String, backupID: String) async throws -> PhoneWebCloudBackupDocument {
        let snapshot = try await getDocument(
            firestore.collection("users").document(userID).collection("appBackups").document(backupID)
        )
        guard snapshot.exists, let data = snapshot.data() else {
            throw SyncManagerError.missingBackup
        }
        return try decodeJSONObject(PhoneWebCloudBackupDocument.self, from: data)
    }

    private func createBackupRecord(
        userID: String,
        appState: PhoneWebAppState,
        label: String,
        source: String,
        appStateUpdatedAt: String
    ) async throws {
        let backupID = UUID().uuidString.lowercased()
        let payload = PhoneWebCloudBackupDocument(
            id: backupID,
            label: label,
            createdAt: SyncISO8601.string(from: Date()),
            source: source,
            appStateUpdatedAt: appStateUpdatedAt,
            schemaVersion: backupSchemaVersion,
            appState: appState
        )
        try await setData(
            dictionaryRepresentation(of: payload),
            at: firestore.collection("users").document(userID).collection("appBackups").document(backupID)
        )
        try await trimCloudBackups(userID: userID)
    }

    private func trimCloudBackups(userID: String) async throws {
        let snapshot = try await getDocuments(
            firestore.collection("users")
                .document(userID)
                .collection("appBackups")
                .order(by: "createdAt", descending: true)
                .limit(to: maxCloudBackups + 12)
        )

        let extras = snapshot.documents.dropFirst(maxCloudBackups)
        for document in extras {
            try await deleteDocument(document.reference)
        }
    }

    private func writeCloudSnapshot(
        userID: String,
        appState: PhoneWebAppState,
        updatedAt: String,
        source: String
    ) async throws {
        try await setData(
            [
                "webAppStateVersion": backupSchemaVersion,
                "webAppStateUpdatedAt": updatedAt,
                "webAppStateSource": source,
                "webAppState": dictionaryRepresentation(of: appState),
            ],
            at: firestore.collection("users").document(userID),
            merge: true
        )
    }

    private func getDocument(_ reference: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: SyncManagerError.missingSnapshot)
                }
            }
        }
    }

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: SyncManagerError.missingSnapshot)
                }
            }
        }
    }

    private func setData(_ data: [String: Any], at reference: DocumentReference, merge: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data, merge: merge) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func deleteDocument(_ reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
#endif

    private func runAction<T>(_ operation: () async throws -> T) async -> T? {
        cloudSyncBusy = true
        cloudSyncMessage = nil
        cloudSyncError = nil
        defer { cloudSyncBusy = false }

        do {
            return try await operation()
        } catch {
            cloudSyncError = message(for: error)
            return nil
        }
    }

    private func message(for error: Error) -> String {
        if let syncError = error as? SyncManagerError {
            return syncError.localizedDescription
        }
        return error.localizedDescription
    }

    private func dictionaryRepresentation<T: Encodable>(of value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw SyncManagerError.invalidPayload
        }
        return dictionary
    }

    private func decodeJSONObject<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try JSONDecoder().decode(type, from: data)
    }
}

enum SyncManagerError: LocalizedError {
    case notSignedIn
    case noCloudSnapshot
    case missingBackup
    case missingSnapshot
    case invalidPayload
    case firebaseUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to your account to use phone and web sync."
        case .noCloudSnapshot:
            return "No saved copy exists for this account yet."
        case .missingBackup:
            return "That recovery backup is no longer available."
        case .missingSnapshot:
            return "The saved data could not be loaded right now."
        case .invalidPayload:
            return "This data could not be prepared for sync."
        case .firebaseUnavailable:
            return "Phone and web sync is unavailable in this build."
        }
    }
}
