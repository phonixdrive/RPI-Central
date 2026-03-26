//
// CourseDetailView.swift
// RPI Central
//

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager

    let course: Course
    var displaySemester: Semester? = nil

    // per-section prereq bypass arming
    @State private var bypassArmed: Set<String> = []

    // exam-date picker sheet state
    @State private var showExamPicker: Bool = false
    @State private var examPickerTitle: String = ""
    @State private var examPickerKey: String = ""
    @State private var examPickerDates: Set<Date> = []   // ✅ replaces Set<DateComponents>
    @State private var courseCommentDraft: String = ""
    @State private var selectedPrerequisiteID: String?
    @State private var isPrerequisitesExpanded: Bool = false
    @FocusState private var commentFieldFocused: Bool

    private var discussionTaskID: String {
        [
            socialManager.currentUser?.id ?? "none",
            enrollmentsForThisCourse.map(\.id).sorted().joined(separator: "|")
        ].joined(separator: "::")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.title.bold())

                    Text("\(course.subject) \(course.number)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                if socialManager.isFirebaseAvailable,
                   socialManager.isAuthenticated,
                   !friendsInCourse.isEmpty {
                    friendsInCourseCard
                }

                // Meeting Blocks (only if enrolled)
                if !enrollmentsForThisCourse.isEmpty {
                    meetingBlocksEditor
                }

                // Prereqs (metadata)
                if let prereqText = calendarViewModel.prerequisitesDisplayString(for: course) {
                    DisclosureGroup(isExpanded: $isPrerequisitesExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            let prerequisiteExpression = calendarViewModel.prerequisiteExpression(for: course)
                            let prerequisiteIDs = calendarViewModel.prerequisiteCourseIDs(for: course)
                            if let prerequisiteExpression {
                                prerequisiteExpressionView(prerequisiteExpression)
                            } else if prerequisiteIDs.isEmpty {
                                Text(prereqText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                prerequisitePills(prerequisiteIDs)
                            }

                            let missing = calendarViewModel.missingPrerequisites(for: course)
                            if calendarViewModel.enforcePrerequisites, !missing.isEmpty {
                                if prerequisiteExpression == nil {
                                    Text("Missing: " + missing.map(calendarViewModel.formattedCourseID).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    Text("You’re still missing one valid prerequisite path. The satisfied option is highlighted in green.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                Text("Tap a missing prerequisite to mark it as already taken if you’ve already completed it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Text("Prerequisites")
                                .font(.headline)

                            Spacer()

                            let missing = calendarViewModel.missingPrerequisites(for: course)
                            if calendarViewModel.enforcePrerequisites, !missing.isEmpty {
                                Text("Missing")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                // Description
                if !course.description.isEmpty {
                    Text(course.description)
                        .font(.body)
                }

                // Sections
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sections")
                        .font(.headline)

                    ForEach(course.sections) { section in
                        sectionCard(section)
                    }
                }

                if socialManager.isFirebaseAvailable {
                    courseDiscussionSection
                }
            }
            .padding()
        }
        .navigationTitle("\(course.subject) \(course.number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commentFieldFocused = false
                }
            }
        }
        .task(id: discussionTaskID) {
            guard socialManager.isFirebaseAvailable, socialManager.isAuthenticated else { return }
            if socialManager.overview == nil {
                await socialManager.refreshOverview()
            }
            guard !enrollmentsForThisCourse.isEmpty else { return }
            await socialManager.syncCourseCommunities(for: enrollmentsForThisCourse)
            await socialManager.refreshCourseComments(for: course)
        }
        .sheet(isPresented: $showExamPicker) {
            ExamDatesEditorSheet(
                title: examPickerTitle,
                dates: $examPickerDates,
                onSave: { pickedDates in
                    // ✅ Normalize to NY start-of-day before saving
                    var cal = Calendar.current
                    cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current

                    let normalized = Set(pickedDates.map { cal.startOfDay(for: $0) })
                    calendarViewModel.setExamDates(normalized, for: examPickerKey)
                }
            )
        }
        .alert(item: selectedPrerequisiteDetails) { prereq in
            prerequisiteAlert(for: prereq)
        }
    }

    // MARK: - Enrollments for this course (may exist across semesters)

    private var enrollmentsForThisCourse: [EnrolledCourse] {
        calendarViewModel.enrolledCourses.filter {
            $0.course.subject == course.subject && $0.course.number == course.number
        }
    }

    private var sharingSemesterCode: String {
        activeSemester.rawValue
    }

    private var activeSemester: Semester {
        displaySemester ?? calendarViewModel.currentSemester
    }

    private var friendsInCourse: [SocialFriend] {
        socialManager.friendsSharingCourse(
            subject: course.subject,
            number: course.number,
            semesterCode: sharingSemesterCode
        )
    }

    private func friendsInSection(_ section: CourseSection) -> [SocialFriend] {
        socialManager.friendsSharingSection(
            course: course,
            section: section,
            semesterCode: sharingSemesterCode
        )
    }

    // MARK: - Meeting Blocks UI

    private var meetingBlocksEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting Blocks")
                .font(.headline)

            Text("Mark meeting blocks as exam/recitation or disable them. Exam blocks only appear on the dates you select.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(enrollmentsForThisCourse) { enrollment in
                VStack(alignment: .leading, spacing: 8) {
                    Text("CRN \(enrollment.section.crn.map(String.init) ?? "N/A") • \(Semester(rawValue: enrollment.semesterCode)?.displayName ?? enrollment.semesterCode)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    if enrollment.section.meetings.isEmpty {
                        Text("No scheduled meeting time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(enrollment.section.meetings.indices, id: \.self) { idx in
                            let m = enrollment.section.meetings[idx]
                            meetingRow(enrollment: enrollment, meeting: m)
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private var friendsInCourseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Friends in this course")
                .font(.headline)

            Text("Shown from friends who are sharing their schedule for \(Semester(rawValue: sharingSemesterCode)?.displayName ?? sharingSemesterCode).")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: friendChipColumns, alignment: .leading, spacing: 8) {
                ForEach(friendsInCourse) { friend in
                    Text(friend.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(calendarViewModel.themeColor.opacity(0.12))
                        )
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func meetingRow(enrollment: EnrolledCourse, meeting: Meeting) -> some View {
        let key = calendarViewModel.meetingOverrideKey(
            enrollmentID: enrollment.id,
            course: enrollment.course,
            section: enrollment.section,
            meeting: meeting
        )

        let ov = calendarViewModel.meetingOverride(for: key)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(meeting.days.map { $0.shortName }.joined()) \(meeting.start) – \(meeting.end)")
                        .font(.subheadline.bold())

                    Text(meeting.location.isEmpty ? "Location TBA" : meeting.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { ov.type },
                    set: { newType in
                        calendarViewModel.setMeetingOverrideType(newType, for: key)
                    }
                )) {
                    ForEach(MeetingBlockType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
            }

            if ov.type == .exam {
                HStack(spacing: 10) {
                    let count = calendarViewModel.examDates(for: key).count
                    Text(count == 0 ? "No exam dates selected" : "\(count) exam date\(count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(role: .destructive) {
                        calendarViewModel.setExamDates([], for: key)
                    } label: {
                        Text("Remove exam")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        // ✅ seed editor with existing dates (normalized)
                        var cal = Calendar.current
                        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current

                        let existingDates = calendarViewModel.examDates(for: key)
                        examPickerDates = Set(existingDates.map { cal.startOfDay(for: $0) })

                        examPickerTitle = "\(course.subject) \(course.number) • \(meeting.days.map { $0.shortName }.joined()) \(meeting.start)–\(meeting.end)"
                        examPickerKey = key
                        showExamPicker = true
                    } label: {
                        Text("Edit dates")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }

            if ov.type == .disabled {
                Text("This block will not appear on your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section card

    private func sectionCard(_ section: CourseSection) -> some View {
        let isEnrolled = calendarViewModel.isEnrolled(for: course, section: section, semester: activeSemester)
        let hasConflict = (!isEnrolled) && calendarViewModel.hasConflict(for: course, section: section, semester: activeSemester)

        let missing = calendarViewModel.missingPrerequisites(for: course)
        let prereqGateOn = calendarViewModel.enforcePrerequisites && !missing.isEmpty && !isEnrolled
        let armed = bypassArmed.contains(section.id)

        let crnText = section.crn.map(String.init) ?? "N/A"

        // button label + disabled logic
        let buttonTitle: String = {
            if isEnrolled { return "Remove" }
            if hasConflict { return "Time conflict" }
            if prereqGateOn { return armed ? "Bypass prereq" : "Add" }
            return "Add"
        }()

        let buttonTint: Color = {
            if isEnrolled { return .red }
            if hasConflict { return .gray }
            if prereqGateOn && armed { return .orange }
            return .accentColor
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CRN \(crnText) • Sec \(section.section)")
                    .font(.subheadline.bold())
                Spacer()

                Button(buttonTitle) {
                    if isEnrolled {
                        if let enrollment = calendarViewModel.enrollment(for: course, section: section, semester: activeSemester) {
                            calendarViewModel.removeEnrollment(enrollment)
                            if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
                                Task {
                                    await socialManager.syncCourseCommunities(from: calendarViewModel)
                                    await socialManager.refreshCourseComments(for: course)
                                    if socialManager.currentUser?.shareSchedule == true {
                                        await socialManager.syncSchedule(from: calendarViewModel)
                                    }
                                }
                            }
                        }
                        return
                    }

                    if hasConflict {
                        return
                    }

                    if prereqGateOn && !armed {
                        bypassArmed.insert(section.id)
                        return
                    }

                    calendarViewModel.addCourseSection(section, course: course, semester: activeSemester)
                    bypassArmed.remove(section.id)
                    if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
                        Task {
                            await socialManager.syncCourseCommunities(from: calendarViewModel)
                            await socialManager.refreshCourseComments(for: course)
                            if socialManager.currentUser?.shareSchedule == true {
                                await socialManager.syncSchedule(from: calendarViewModel)
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
                .font(.caption)
                .disabled(hasConflict)
            }

            if !section.instructor.isEmpty {
                Text(section.instructor)
                    .font(.subheadline)
            }

            if prereqGateOn && !armed {
                if calendarViewModel.prerequisiteExpression(for: course) == nil {
                    Text("Missing prereqs: \(missing.map(calendarViewModel.formattedCourseID).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Tap Add again to bypass, or mark the prerequisite as already taken above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !section.meetings.isEmpty {
                ForEach(section.meetings.indices, id: \.self) { idx in
                    let m = section.meetings[idx]
                    Text("\(m.days.map { $0.shortName }.joined()) \(m.start) – \(m.end) • \(m.location)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No scheduled meeting time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let friendsInMatchingSection = friendsInSection(section)
            if !friendsInMatchingSection.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(friendsInMatchingSection.count == 1 ? "Friend in this section" : "Friends in this section")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(calendarViewModel.themeColor)

                    LazyVGrid(columns: friendChipColumns, alignment: .leading, spacing: 8) {
                        ForEach(friendsInMatchingSection) { friend in
                            Text(friend.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(calendarViewModel.themeColor.opacity(0.12))
                                )
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

}

// MARK: - Exam dates editor sheet (no MultiDatePicker)

private struct ExamDatesEditorSheet: View {
    let title: String
    @Binding var dates: Set<Date>
    let onSave: (Set<Date>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var candidateDate: Date = Date()

    private var sortedDates: [Date] {
        dates.sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select exam dates")
                    .font(.headline)

                // ✅ Graphical date picker (single-day selection)
                DatePicker(
                    "Exam date",
                    selection: $candidateDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)

                HStack {
                    Button("Add date") {
                        var cal = Calendar.current
                        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
                        dates.insert(cal.startOfDay(for: candidateDate))
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    if !dates.isEmpty {
                        Button(role: .destructive) {
                            dates.removeAll()
                        } label: {
                            Text("Clear all")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if dates.isEmpty {
                    Text("No exam dates selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected dates")
                            .font(.subheadline.bold())

                        // ✅ Individually deletable list
                        List {
                            ForEach(sortedDates, id: \.self) { d in
                                HStack {
                                    Text(d.formatted(date: .abbreviated, time: .omitted))
                                    Spacer()
                                    Button(role: .destructive) {
                                        dates.remove(d)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 160)
                    }
                }

                Text("Only dates selected here will show the exam block on your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Exam Dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(dates)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
