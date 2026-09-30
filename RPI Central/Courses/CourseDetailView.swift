//
// CourseDetailView.swift
// RPI Central
//

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @AppStorage("courses_auto_collapse_prerequisites_v1") private var autoCollapsePrerequisites = true

    let course: Course
    var displaySemester: Semester? = nil
    /// Off when this page is opened from the class page itself.
    var showsClassPageLink = true

    // Per-section prerequisite/full-section bypass arming.
    @State private var bypassArmed: Set<String> = []

    @State private var classPageEvent: ClassEvent?
    @State private var courseCommentDraft: String = ""
    @State private var selectedPrerequisiteID: String?
    @State private var isPrerequisitesExpanded: Bool = false
    @State private var didSeedPrerequisiteExpansion = false
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

                if showsClassPageLink, let enrollment = activeEnrollment,
                   let event = calendarViewModel.nextClassEvent(forEnrollmentID: enrollment.id) {
                    Button {
                        classPageEvent = event
                    } label: {
                        Label("Open Class Page", systemImage: "rectangle.stack.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(calendarViewModel.themeColor)
                }

                ProfessorsCard(instructors: instructors, accent: calendarViewModel.themeColor)

                CourseRatingsCard(
                    subject: course.subject,
                    number: course.number,
                    courseTitle: course.title,
                    semesterCode: activeSemester.rawValue,
                    accent: calendarViewModel.themeColor
                )

                if socialManager.isFirebaseAvailable,
                   socialManager.isAuthenticated,
                   !friendsInCourse.isEmpty {
                    friendsInCourseCard
                }

                ForEach(enrollmentsForThisCourse) { enrollment in
                    MeetingBlocksCard(enrollment: enrollment, accent: calendarViewModel.themeColor)
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
                                    Text("No prerequisite path is complete yet.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                HStack(spacing: 4) {
                                    Text("Already took one? Tap it to mark it done.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    InfoButton("A course can have several prerequisite paths; completing any one is enough. Completed options are highlighted in green.")
                                }
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
        .sheet(item: $classPageEvent) { event in
            ClassEventDetailView(event: event)
                .environmentObject(calendarViewModel)
                .environmentObject(socialManager)
        }
        .alert(item: selectedPrerequisiteDetails) { prereq in
            prerequisiteAlert(for: prereq)
        }
        .onAppear {
            seedPrerequisiteExpansionIfNeeded()
        }
        .onChange(of: autoCollapsePrerequisites) { _, newValue in
            isPrerequisitesExpanded = !newValue
        }
    }

    private func seedPrerequisiteExpansionIfNeeded() {
        guard !didSeedPrerequisiteExpansion else { return }
        didSeedPrerequisiteExpansion = true
        isPrerequisitesExpanded = !autoCollapsePrerequisites
    }

    // MARK: - Enrollments for this course (may exist across semesters)

    private var enrollmentsForThisCourse: [EnrolledCourse] {
        calendarViewModel.enrolledCourses.filter {
            $0.course.subject == course.subject && $0.course.number == course.number
        }
    }

    private var activeEnrollment: EnrolledCourse? {
        enrollmentsForThisCourse.first { $0.semesterCode == activeSemester.rawValue }
    }

    /// Everyone teaching a section, without repeats.
    private var instructors: [String] {
        var seen: Set<String> = []
        return course.sections
            .flatMap { RateMyProfessors.instructors(from: $0.instructor) }
            .filter { seen.insert($0).inserted }
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

    private var friendsInCourseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Friends in this course")
                    .font(.headline)
                InfoButton("Friends who share their \(Semester(rawValue: sharingSemesterCode)?.displayName ?? sharingSemesterCode) schedule with you.")
            }

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

    // MARK: - Section card

    private func sectionCard(_ section: CourseSection) -> some View {
        let isEnrolled = calendarViewModel.isEnrolled(for: course, section: section, semester: activeSemester)
        let isRegistrationClosed = (!isEnrolled) && section.isRegistrationClosed
        let isFullForRegistration = (!isEnrolled) && section.isFullForRegistration
        let hasConflict = (!isEnrolled) && calendarViewModel.hasConflict(for: course, section: section, semester: activeSemester)

        let missing = calendarViewModel.missingPrerequisites(for: course)
        let prereqGateOn = calendarViewModel.enforcePrerequisites && !missing.isEmpty && !isEnrolled
        let bypassRequired = prereqGateOn || isFullForRegistration
        let armed = bypassArmed.contains(section.id)

        let crnText = section.crn.map(String.init) ?? "N/A"

        // button label + disabled logic
        let buttonTitle: String = {
            if isEnrolled { return "Remove" }
            if isRegistrationClosed { return "Closed" }
            if hasConflict { return "Time conflict" }
            if bypassRequired && armed { return "Add anyway" }
            if isFullForRegistration { return "Full" }
            return "Add"
        }()

        let buttonTint: Color = {
            if isEnrolled { return .red }
            if isRegistrationClosed { return .gray }
            if hasConflict { return .gray }
            if bypassRequired { return .orange }
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
                                    socialManager.requestScheduleSync()
                                }
                            }
                        }
                        return
                    }

                    if hasConflict {
                        return
                    }

                    if isRegistrationClosed {
                        return
                    }

                    if bypassRequired && !armed {
                        bypassArmed.insert(section.id)
                        return
                    }

                    calendarViewModel.addCourseSection(
                        section,
                        course: course,
                        semester: activeSemester,
                        allowFullSection: isFullForRegistration
                    )
                    bypassArmed.remove(section.id)
                    if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
                        Task {
                            await socialManager.syncCourseCommunities(from: calendarViewModel)
                            await socialManager.refreshCourseComments(for: course)
                            socialManager.requestScheduleSync()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
                .font(.caption)
                .disabled(hasConflict || isRegistrationClosed)
            }

            if !section.instructor.isEmpty {
                Text(section.instructor)
                    .font(.subheadline)
            }

            if let seatStatusLabel = section.seatStatusLabel {
                Text(seatStatusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(section.isClosedForRegistration ? .red : .secondary)
            }

            if prereqGateOn && !armed {
                if calendarViewModel.prerequisiteExpression(for: course) == nil {
                    Text("Missing prereqs: \(missing.map(calendarViewModel.formattedCourseID).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Tap Add again to add it anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isFullForRegistration {
                Text(armed
                     ? "Tap Add anyway if SIS already has you in this section."
                     : "Full. Tap Full if SIS already has you in this section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isRegistrationClosed {
                Text("Closed for registration.")
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

    private var friendChipColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)]
    }

    private func prerequisiteExpressionView(_ expression: PrerequisiteExpression, depth: Int = 0) -> AnyView {
        switch expression {
        case .course(let courseID, let minGrade):
            return AnyView(prerequisiteCourseRow(courseID: courseID, minGrade: minGrade, depth: depth))
        case .and(let children):
            return AnyView(
                prerequisiteGroupView(
                    title: depth == 0 ? "All of these" : "And",
                    expression: expression,
                    children: children,
                    depth: depth
                )
            )
        case .or(let children):
            return AnyView(
                prerequisiteGroupView(
                    title: "One of these options",
                    expression: expression,
                    children: children,
                    depth: depth
                )
            )
        }
    }

    private func prerequisiteGroupView(
        title: String,
        expression: PrerequisiteExpression,
        children: [PrerequisiteExpression],
        depth: Int
    ) -> some View {
        let satisfied = calendarViewModel.isSatisfied(expression)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(satisfied ? "Satisfied" : "Needed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(satisfied ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(children.enumerated()), id: \.offset) { pair in
                    prerequisiteExpressionView(pair.element, depth: depth + 1)
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : 12)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func prerequisiteCourseRow(courseID: String, minGrade: String?, depth: Int) -> some View {
        let status = calendarViewModel.prerequisiteStatus(for: courseID, course: course)
        let tint: Color = {
            switch status {
            case .missing:
                return .red
            case .assumedTaken:
                return .orange
            case .completed:
                return .green
            }
        }()

        let statusText: String = {
            switch status {
            case .missing:
                return "Missing"
            case .assumedTaken:
                return "Marked taken"
            case .completed:
                return "Satisfied"
            }
        }()

        let title = calendarViewModel.courseTitle(for: courseID)

        return Button {
            selectedPrerequisiteID = courseID
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(calendarViewModel.formattedCourseID(courseID))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let minGrade, !minGrade.isEmpty {
                        Text("Minimum grade: \(minGrade)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.leading, depth == 0 ? 0 : 12)
        }
        .buttonStyle(.plain)
    }

    private func prerequisitePills(_ prerequisiteIDs: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(prerequisiteIDs, id: \.self) { prereqID in
                Button {
                    selectedPrerequisiteID = prereqID
                } label: {
                    prerequisitePillLabel(for: prereqID)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func prerequisitePillLabel(for prereqID: String) -> some View {
        let status = calendarViewModel.prerequisiteStatus(for: prereqID, course: course)
        let tint: Color = {
            switch status {
            case .missing:
                return .red
            case .assumedTaken:
                return .orange
            case .completed:
                return .green
            }
        }()

        let statusText: String = {
            switch status {
            case .missing:
                return "Missing"
            case .assumedTaken:
                return "Marked taken"
            case .completed:
                return "Satisfied"
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            Text(calendarViewModel.formattedCourseID(prereqID))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        )
    }

    private var selectedPrerequisiteDetails: Binding<PrerequisiteAlertItem?> {
        Binding(
            get: {
                guard let selectedPrerequisiteID else { return nil }
                return PrerequisiteAlertItem(courseID: selectedPrerequisiteID)
            },
            set: { newValue in
                selectedPrerequisiteID = newValue?.courseID
            }
        )
    }

    private func prerequisiteAlert(for prereq: PrerequisiteAlertItem) -> Alert {
        let status = calendarViewModel.prerequisiteStatus(for: prereq.courseID, course: course)
        let title = Text(calendarViewModel.formattedCourseID(prereq.courseID))
        let courseTitle = calendarViewModel.courseTitle(for: prereq.courseID) ?? "Course title unavailable"
        let message = Text(courseTitle)

        switch status {
        case .missing:
            return Alert(
                title: title,
                message: message,
                primaryButton: .default(Text("Mark as already taken")) {
                    calendarViewModel.setAssumedPrerequisite(prereq.courseID, for: course, assumed: true)
                },
                secondaryButton: .cancel()
            )

        case .assumedTaken:
            return Alert(
                title: title,
                message: message,
                primaryButton: .default(Text("Undo already taken")) {
                    calendarViewModel.setAssumedPrerequisite(prereq.courseID, for: course, assumed: false)
                },
                secondaryButton: .cancel()
            )

        case .completed:
            return Alert(
                title: title,
                message: message,
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var courseDiscussionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Class Discussion")
                    .font(.headline)
                InfoButton("Everyone taking this course sees these comments, across sections and terms.")
            }

            if !socialManager.isAuthenticated {
                discussionPlaceholder("Sign in on the Social tab to join.")
            } else if enrollmentsForThisCourse.isEmpty {
                discussionPlaceholder("Add a section of this course to join.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    commentComposerCard

                    if socialManager.courseComments(for: course).isEmpty {
                        discussionPlaceholder("No comments yet. Start the conversation.")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(socialManager.courseComments(for: course)) { comment in
                                courseCommentRow(comment)
                            }
                        }
                    }
                }
            }
        }
    }

    private var commentComposerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Post to the class")
                .font(.subheadline.weight(.semibold))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))

                TextEditor(text: $courseCommentDraft)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 100)
                    .focused($commentFieldFocused)
                    .textInputAutocapitalization(.sentences)

                if courseCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Share something with the class")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(calendarViewModel.themeColor.opacity(0.16), lineWidth: 1)
            )

            HStack {
                Text("Visible to the overall class group")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Post") {
                    let trimmedComment = courseCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedComment.isEmpty else { return }

                    Task {
                        let posted = await socialManager.postCourseComment(for: course, body: trimmedComment)
                        if posted {
                            await MainActor.run {
                                courseCommentDraft = ""
                                commentFieldFocused = false
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(courseCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func discussionPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            )
    }

    private func courseCommentRow(_ comment: SocialCourseComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comment.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formattedCourseCommentDate(comment.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if socialManager.canDeleteCourseComment(comment) {
                    Button(role: .destructive) {
                        Task {
                            _ = await socialManager.deleteCourseComment(for: course, comment: comment)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text(comment.body)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func formattedCourseCommentDate(_ isoString: String) -> String {
        if let date = ISO8601DateFormatter().date(from: isoString) {
            return courseCommentDateFormatter.string(from: date)
        }
        return "Recently"
    }

}

private let courseCommentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

private struct PrerequisiteAlertItem: Identifiable {
    let courseID: String
    var id: String { courseID }
}

