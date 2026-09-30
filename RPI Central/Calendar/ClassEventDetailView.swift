//
//  ClassEventDetailView.swift
//  RPI Central
//
//  What you see after tapping an event. Class meetings become a small hub for
//  the course: where and when, what's due, grade, professor, ratings,
//  classmates, notes, and syllabus import.
//

import MapKit
import SwiftUI

struct ClassEventDetailView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    let event: ClassEvent
    /// "1 of 2" when swiping between overlapping events.
    var pageLabel: String? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tasks = TasksManager.shared
    @FocusState private var notesFocused: Bool
    @State private var notesText = ""
    @State private var confirmRemoveOne = false
    @State private var confirmRemoveSeries = false
    @State private var confirmRemoveCourse = false
    @State private var confirmHideOccurrence = false
    @State private var confirmHideAllDay = false
    @State private var showTaskEditor = false
    @State private var editingTask: CourseTask?
    @State private var showSyllabusImport = false
    @State private var showGrades = false
    @State private var showCourseInfo = false
    @State private var classChat: SocialGroupChatReference?
    @State private var copiedCRN = false

    init(event: ClassEvent, pageLabel: String? = nil) {
        self.event = event
        self.pageLabel = pageLabel
    }

    private var enrollment: EnrolledCourse? {
        guard let id = event.enrollmentID else { return nil }
        return viewModel.enrolledCourses.first { $0.id == id }
    }

    private var accent: Color { event.accentColor }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let enrollment, event.kind == .classMeeting {
                        classContent(enrollment)
                    } else {
                        if event.kind == .classMeeting, let enrollmentID = event.enrollmentID {
                            notesCard(enrollmentID: enrollmentID)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(pageLabel ?? "")
            .navigationBarTitleDisplayMode(.inline)
            // Inside the overlap pager the bar doesn't pick up the scroll
            // edge effect, so give it a solid background.
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .onAppear {
                if let enrollmentID = event.enrollmentID, event.kind == .classMeeting {
                    notesText = viewModel.notes(for: enrollmentID)
                }
            }
            .modifier(RemovalDialogs(
                event: event,
                confirmHideAllDay: $confirmHideAllDay,
                confirmRemoveOne: $confirmRemoveOne,
                confirmRemoveSeries: $confirmRemoveSeries,
                confirmRemoveCourse: $confirmRemoveCourse,
                confirmHideOccurrence: $confirmHideOccurrence,
                onDone: {
                    socialManager.requestScheduleSync()
                    dismiss()
                }
            ))
            .sheet(isPresented: $showTaskEditor, onDismiss: { editingTask = nil }) {
                NavigationStack {
                    TaskEditorView(
                        themeColor: viewModel.themeColor,
                        enrollments: viewModel.enrolledCourses.filter { $0.semesterCode == enrollment?.semesterCode },
                        existing: editingTask,
                        presetEnrollmentID: event.enrollmentID,
                        onSave: { saved in
                            if tasks.tasks.contains(where: { $0.id == saved.id }) {
                                tasks.update(saved)
                            } else {
                                tasks.add(saved)
                            }
                            showTaskEditor = false
                        },
                        onCancel: { showTaskEditor = false }
                    )
                }
            }
            .sheet(isPresented: $showSyllabusImport) {
                if let enrollment {
                    SyllabusImportView(
                        enrollmentID: enrollment.id,
                        courseTitle: "\(enrollment.course.subject) \(enrollment.course.number)",
                        term: viewModel.termBoundsBySemesterCode[enrollment.semesterCode].map(SyllabusDateExtractor.importWindow),
                        classTimes: SyllabusImportView.classTimes(for: enrollment.section),
                        accent: viewModel.themeColor
                    )
                }
            }
            .sheet(isPresented: $showGrades) {
                if let enrollmentID = event.enrollmentID {
                    NavigationStack {
                        GradeBreakdownView(enrollmentID: enrollmentID)
                            .environmentObject(viewModel)
                    }
                }
            }
            .sheet(isPresented: $showCourseInfo) {
                if let enrollment {
                    NavigationStack {
                        CourseDetailView(course: enrollment.course, displaySemester: Semester(rawValue: enrollment.semesterCode), showsClassPageLink: false)
                            .environmentObject(viewModel)
                            .environmentObject(socialManager)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showCourseInfo = false }
                                }
                            }
                    }
                }
            }
            .sheet(item: $classChat) { GroupChatSheet(reference: $0) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let enrollment {
                        Text("\(enrollment.course.subject) \(enrollment.course.number) · Section \(enrollment.section.section)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                            .textCase(.uppercase)
                    }
                    Text(enrollment?.course.title ?? event.title.replacingOccurrences(of: "★ ", with: ""))
                        .font(.title2.bold())
                    if event.badge == .exam {
                        Label("Exam", systemImage: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                statusPill
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(dateText, systemImage: "calendar")
                if !event.location.isEmpty {
                    Label(locationText, systemImage: "mappin.and.ellipse")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if enrollment != nil {
                actionButtons
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20)
                        .fill(accent)
                        .frame(width: 5)
                }
        )
    }

    @ViewBuilder
    private var statusPill: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            if !event.isAllDay, now >= event.startDate, now < event.endDate {
                pill("Now", color: .green)
            } else if !event.isAllDay, event.startDate > now, event.startDate.timeIntervalSince(now) < 3 * 3600 {
                pill("in \(Self.shortDuration(event.startDate.timeIntervalSince(now)))", color: accent)
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var dateText: String {
        if event.isAllDay {
            let start = event.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
                return "\(start) · All day"
            }
            return "\(start) – \(event.endDate.formatted(.dateTime.month(.abbreviated).day()))"
        }
        let day = event.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) – \(end)"
    }

    private var locationText: String {
        if let match = CampusDirectory.shared.match(scheduleLocation: event.location) {
            return [match.building.name, match.room.map { "Room \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        return event.location
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if let building = CampusDirectory.shared.match(scheduleLocation: event.location)?.building {
                actionButton("Directions", systemImage: "figure.walk") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: building.center))
                    item.name = building.name
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                }
            }
            if let chat = classChatReference {
                actionButton("Class Chat", systemImage: "bubble.left.and.bubble.right") { classChat = chat }
            }
            actionButton("Add Task", systemImage: "plus.circle") {
                editingTask = nil
                showTaskEditor = true
            }
            actionButton("Grades", systemImage: "chart.bar") { showGrades = true }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
    }

    private var classChatReference: SocialGroupChatReference? {
        guard socialManager.isAuthenticated, let enrollment else { return nil }
        let communityID = socialManager.overallCourseCommunityID(for: enrollment.course)
        return socialManager.courseCommunities.first { $0.id == communityID }.map(socialManager.chatReference(for:))
    }

    // MARK: Class content

    @ViewBuilder
    private func classContent(_ enrollment: EnrolledCourse) -> some View {
        dueCard(enrollment)
        nextMeetingsCard(enrollment)
        gradeCard(enrollment)
        ProfessorsCard(instructors: RateMyProfessors.instructors(from: enrollment.section.instructor), accent: accent)
        CourseRatingsCard(
            subject: enrollment.course.subject,
            number: enrollment.course.number,
            courseTitle: enrollment.course.title,
            semesterCode: enrollment.semesterCode,
            accent: accent
        )
        friendsCard(enrollment)
        notesCard(enrollmentID: enrollment.id)
        MeetingBlocksCard(enrollment: enrollment, accent: accent)
        infoCard(enrollment)
    }

    private func dueCard(_ enrollment: EnrolledCourse) -> some View {
        let now = Date()
        let classTasks = tasks.tasks
            .filter { $0.enrollmentID == enrollment.id && $0.dueDate >= Calendar.current.startOfDay(for: now) }
            .sorted { $0.dueDate < $1.dueDate }

        return card(title: "Coming Up", systemImage: "checklist") {
            Menu {
                Button("New Task", systemImage: "plus") {
                    editingTask = nil
                    showTaskEditor = true
                }
                Button("Import Syllabus Dates", systemImage: "doc.text.magnifyingglass") { showSyllabusImport = true }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .accessibilityLabel("Add")
        } content: {
            if classTasks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing due for this class.")
                        .foregroundStyle(.secondary)
                    Button {
                        showSyllabusImport = true
                    } label: {
                        Label("Import dates from your syllabus", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(accent)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(classTasks.prefix(5).enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider() }
                        Button {
                            editingTask = task
                            showTaskEditor = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: task.kind.systemImage)
                                    .foregroundStyle(task.kind == .exam ? .orange : accent)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.title).foregroundStyle(Color.primary).lineLimit(1)
                                    Text(task.dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(Self.dueText(task.dueDate, now: now))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(task.dueDate.timeIntervalSince(now) < 86_400 ? Color.red : Color.secondary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { tasks.delete(task) }
                        }
                    }
                    if classTasks.count > 5 {
                        Text("+\(classTasks.count - 5) more on Home")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func nextMeetingsCard(_ enrollment: EnrolledCourse) -> some View {
        let meetings = upcomingMeetings(for: enrollment, limit: 4)
        return card(title: "Next Classes", systemImage: "clock") {
            EmptyView()
        } content: {
            if meetings.isEmpty {
                Text("No more meetings this term.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(meetings, id: \.interactionKey) { meeting in
                        HStack {
                            Text(meeting.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 96, alignment: .leading)
                            Text("\(meeting.startDate.formatted(date: .omitted, time: .shortened)) – \(meeting.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if meeting.badge == .exam {
                                Image(systemName: "star.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func upcomingMeetings(for enrollment: EnrolledCourse, limit: Int) -> [ClassEvent] {
        var result: [ClassEvent] = []
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        let now = Date()
        for _ in 0..<28 where result.count < limit {
            let meetings = viewModel.events(on: day)
                .filter { $0.enrollmentID == enrollment.id && !$0.isAllDay && $0.endDate > now }
                .filter { !calendar.isDate($0.startDate, equalTo: event.startDate, toGranularity: .minute) }
            result.append(contentsOf: meetings)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return Array(result.sorted { $0.startDate < $1.startDate }.prefix(limit))
    }

    private func gradeCard(_ enrollment: EnrolledCourse) -> some View {
        let grade = GPACalculator.displayPercentAndLetter(enrollmentID: enrollment.id, fallbackLetter: nil)
        return Button {
            showGrades = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "chart.bar.fill")
                    .font(.title3)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Grade")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(grade.percentText == "—%" ? "Add scores to track your grade" : grade.percentText)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Text(grade.letterText)
                    .font(.title2.bold())
                    .foregroundStyle(accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func friendsCard(_ enrollment: EnrolledCourse) -> some View {
        let sectionFriends = socialManager.friendsSharingSection(
            course: enrollment.course,
            section: enrollment.section,
            semesterCode: enrollment.semesterCode
        )
        let courseFriends = socialManager.friendsSharingCourse(
            subject: enrollment.course.subject,
            number: enrollment.course.number,
            semesterCode: enrollment.semesterCode
        ).filter { friend in !sectionFriends.contains { $0.id == friend.id } }

        if !sectionFriends.isEmpty || !courseFriends.isEmpty {
            card(title: "Friends Taking This", systemImage: "person.2.fill") {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    if !sectionFriends.isEmpty {
                        friendRow(sectionFriends, caption: "Your section")
                    }
                    if !courseFriends.isEmpty {
                        friendRow(courseFriends, caption: "Other sections")
                    }
                }
            }
        }
    }

    private func friendRow(_ friends: [SocialFriend], caption: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(friends.prefix(4)) { friend in
                    SocialAvatar(id: friend.id, name: friend.displayName, size: 30)
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(friends.map { FriendAvatarStyle.firstName(for: $0.displayName) }.prefix(3).joined(separator: ", ") + (friends.count > 3 ? " +\(friends.count - 3)" : ""))
                    .font(.subheadline.weight(.semibold))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func notesCard(enrollmentID: String) -> some View {
        card(title: "Notes", systemImage: "note.text") {
            EmptyView()
        } content: {
            TextField("Office hours, TA email, anything…", text: $notesText, axis: .vertical)
                .lineLimit(4...12)
                .focused($notesFocused)
                .onChange(of: notesText) {
                    viewModel.setNotes(notesText, for: enrollmentID)
                }
        }
    }

    private func infoCard(_ enrollment: EnrolledCourse) -> some View {
        card(title: "Details", systemImage: "info.circle") {
            EmptyView()
        } content: {
            VStack(spacing: 10) {
                if let crn = enrollment.section.crn {
                    infoRow("CRN") {
                        Button {
                            UIPasteboard.general.string = String(crn)
                            copiedCRN = true
                        } label: {
                            Label(copiedCRN ? "Copied" : String(crn), systemImage: copiedCRN ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.monospacedDigit())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                infoRow("Credits") { Text(enrollment.section.credits.formatted()) }
                if let term = Semester(rawValue: enrollment.semesterCode) {
                    infoRow("Term") { Text(term.displayName) }
                }
                Button {
                    showCourseInfo = true
                } label: {
                    HStack {
                        Text("Course Description & Sections")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private func infoRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            value()
        }
        .font(.subheadline)
    }

    // MARK: Building blocks

    private func card<Accessory: View, Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if event.isAllDay {
                    Button("Hide All-Day Event", systemImage: "eye.slash", role: .destructive) { confirmHideAllDay = true }
                }
                if event.kind == .personal {
                    Button("Remove Event", systemImage: "trash", role: .destructive) { confirmRemoveOne = true }
                    if event.seriesID != nil {
                        Button("Remove All Repeats", systemImage: "trash.slash", role: .destructive) { confirmRemoveSeries = true }
                    }
                }
                if event.kind == .classMeeting {
                    Button("Hide This Meeting", systemImage: "eye.slash", role: .destructive) { confirmHideOccurrence = true }
                    if event.enrollmentID != nil {
                        Button("Remove Course", systemImage: "trash", role: .destructive) { confirmRemoveCourse = true }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { notesFocused = false }
        }
    }

    static func shortDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func dueText(_ due: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(due) { return "Today" }
        if calendar.isDateInTomorrow(due) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return days < 7 ? "\(days) days" : due.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Removal confirmations

private struct RemovalDialogs: ViewModifier {
    @EnvironmentObject var viewModel: CalendarViewModel
    let event: ClassEvent
    @Binding var confirmHideAllDay: Bool
    @Binding var confirmRemoveOne: Bool
    @Binding var confirmRemoveSeries: Bool
    @Binding var confirmRemoveCourse: Bool
    @Binding var confirmHideOccurrence: Bool
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Hide all-day event?", isPresented: $confirmHideAllDay, titleVisibility: .visible) {
                Button("Hide", role: .destructive) {
                    viewModel.hideAllDayEvent(event)
                    onDone()
                }
            }
            .confirmationDialog("Remove event?", isPresented: $confirmRemoveOne, titleVisibility: .visible) {
                Button("Remove Event", role: .destructive) {
                    viewModel.removePersonalEvent(event)
                    onDone()
                }
            }
            .confirmationDialog("Remove every repeat of this event?", isPresented: $confirmRemoveSeries, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) {
                    if let seriesID = event.seriesID { viewModel.removePersonalSeries(seriesID: seriesID) }
                    onDone()
                }
            }
            .confirmationDialog("Remove this course from your calendar?", isPresented: $confirmRemoveCourse, titleVisibility: .visible) {
                Button("Remove Course", role: .destructive) {
                    if let id = event.enrollmentID, let enrollment = viewModel.enrolledCourses.first(where: { $0.id == id }) {
                        viewModel.removeEnrollment(enrollment)
                    }
                    onDone()
                }
            }
            .confirmationDialog("Hide only this class meeting?", isPresented: $confirmHideOccurrence, titleVisibility: .visible) {
                Button("Hide This Meeting", role: .destructive) {
                    viewModel.hideClassOccurrence(event)
                    onDone()
                }
            }
    }
}

// MARK: - Rating sheet

struct RateClassSheet: View {
    let courseTitle: String
    let existing: CourseRating?
    let semesterCode: String
    let accent: Color
    @ObservedObject var model: CourseRatingsModel

    @Environment(\.dismiss) private var dismiss
    @State private var overall = 4
    @State private var difficulty = 3
    @State private var hours = 6
    @State private var tags: Set<CourseRatingTag> = []
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Overall") {
                    StarPicker(value: $overall, systemImage: "star.fill", color: .yellow)
                }
                Section {
                    StarPicker(value: $difficulty, systemImage: "flame.fill", color: .orange)
                } header: {
                    Text("Difficulty")
                } footer: {
                    Text("1 is easy, 5 is very hard.")
                }
                Section("Work Outside Class") {
                    Stepper("\(hours) hours a week", value: $hours, in: 0...40)
                }
                Section {
                    ForEach(CourseRatingTag.allCases) { tag in
                        Button {
                            if tags.contains(tag) {
                                tags.remove(tag)
                            } else if tags.count < CourseRating.maximumTags {
                                tags.insert(tag)
                            }
                        } label: {
                            HStack {
                                Text(tag.title).foregroundStyle(Color.primary)
                                Spacer()
                                if tags.contains(tag) {
                                    Image(systemName: "checkmark").foregroundStyle(accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Pick up to \(CourseRating.maximumTags). Ratings are anonymous averages.")
                }
                if existing != nil {
                    Section {
                        Button("Delete My Rating", role: .destructive) {
                            Task {
                                await model.deleteMyRating()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(courseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        isSaving = true
                        Task {
                            let saved = await model.save(CourseRating(
                                overall: overall,
                                difficulty: difficulty,
                                hoursPerWeek: hours,
                                tags: CourseRatingTag.allCases.filter(tags.contains),
                                semesterCode: semesterCode
                            ))
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                if let existing {
                    overall = existing.overall
                    difficulty = existing.difficulty
                    hours = existing.hoursPerWeek
                    tags = Set(existing.tags)
                }
            }
        }
    }
}

private struct StarPicker: View {
    @Binding var value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ForEach(1...5, id: \.self) { index in
                Button {
                    value = index
                } label: {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(index <= value ? color : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(index)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(5, value + 1)
            case .decrement: value = max(1, value - 1)
            @unknown default: break
            }
        }
    }
}

/// Tags that wrap onto multiple lines.
struct FlowTags: View {
    let tags: [String]
    let accent: Color

    var body: some View {
        WrappingHStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(accent)
            }
        }
    }
}

private struct WrappingHStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
