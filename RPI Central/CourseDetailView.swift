//
// CourseDetailView.swift
// RPI Central
//

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    let course: Course

    // per-section prereq bypass arming
    @State private var bypassArmed: Set<String> = []

    // exam-date picker sheet state
    @State private var showExamPicker: Bool = false
    @State private var examPickerTitle: String = ""
    @State private var examPickerKey: String = ""
    @State private var examPickerDates: Set<Date> = []   // ✅ replaces Set<DateComponents>

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

                // Meeting Blocks (only if enrolled)
                if !enrollmentsForThisCourse.isEmpty {
                    meetingBlocksEditor
                }

                // Prereqs (metadata)
                if let prereqText = calendarViewModel.prerequisitesDisplayString(for: course) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prerequisites")
                            .font(.headline)
                        Text(prereqText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        let missing = calendarViewModel.missingPrerequisites(for: course)
                        if calendarViewModel.enforcePrerequisites, !missing.isEmpty {
                            Text("Missing: " + missing.map { $0.replacingOccurrences(of: "-", with: " ") }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.red)
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
            }
            .padding()
        }
        .navigationTitle("\(course.subject) \(course.number)")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: - Enrollments for this course (may exist across semesters)

    private var enrollmentsForThisCourse: [EnrolledCourse] {
        calendarViewModel.enrolledCourses.filter {
            $0.course.subject == course.subject && $0.course.number == course.number
        }
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
        let isEnrolled = calendarViewModel.isEnrolled(for: course, section: section)
        let hasConflict = (!isEnrolled) && calendarViewModel.hasConflict(for: course, section: section)

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
                        if let enrollment = calendarViewModel.enrollment(for: course, section: section) {
                            calendarViewModel.removeEnrollment(enrollment)
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

                    calendarViewModel.addCourseSection(section, course: course)
                    bypassArmed.remove(section.id)
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
                Text("Missing prereqs — tap Add again to bypass")
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
