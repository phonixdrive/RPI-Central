//
//  ClassPageCards.swift
//  RPI Central
//
//  Cards shared by the class page (from the calendar or Home) and the course
//  catalog page: professors on Rate My Professors, student ratings, and the
//  meeting blocks editor for marking exams.
//

import SwiftUI

/// A rounded section with a title and an optional accessory on the right.
struct ClassCard<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
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
}

extension ClassCard where Accessory == EmptyView {
    init(title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Professors

struct ProfessorsCard: View {
    let instructors: [String]
    let accent: Color

    var body: some View {
        if !instructors.isEmpty {
            ClassCard(title: instructors.count == 1 ? "Professor" : "Professors", systemImage: "person.fill") {
                VStack(spacing: 12) {
                    ForEach(instructors, id: \.self) { name in
                        ProfessorRatingRow(instructor: name, accent: accent)
                    }
                }
            }
        }
    }
}

// MARK: - Student ratings

struct CourseRatingsCard: View {
    @EnvironmentObject private var socialManager: SocialManager
    let courseTitle: String
    let semesterCode: String
    let accent: Color

    @StateObject private var ratings: CourseRatingsModel
    @State private var showRateSheet = false

    init(subject: String, number: String, courseTitle: String, semesterCode: String, accent: Color) {
        self.courseTitle = courseTitle
        self.semesterCode = semesterCode
        self.accent = accent
        _ratings = StateObject(wrappedValue: CourseRatingsModel(subject: subject, number: number))
    }

    var body: some View {
        ClassCard(title: "Class Ratings", systemImage: "star.leadinghalf.filled") {
            if socialManager.isAuthenticated, ratings.summary != nil || ratings.myRating != nil {
                Button(ratings.myRating == nil ? "Rate" : "Edit") { showRateSheet = true }
                    .font(.subheadline.weight(.semibold))
                    .tint(accent)
            }
        } content: {
            if !socialManager.isAuthenticated {
                Text("Sign in on the Social tab to see and add ratings.")
                    .foregroundStyle(.secondary)
            } else if ratings.isLoading && ratings.summary == nil {
                ProgressView()
            } else if let summary = ratings.summary {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 0) {
                        stat(String(format: "%.1f", summary.overall), label: "Overall", systemImage: "star.fill", color: .yellow)
                        Divider().frame(height: 36)
                        stat(String(format: "%.1f", summary.difficulty), label: "Difficulty", systemImage: "flame.fill", color: .orange)
                        Divider().frame(height: 36)
                        stat(String(format: "%.0f h", summary.hoursPerWeek), label: "Per week", systemImage: "hourglass", color: accent)
                    }
                    if !summary.topTags.isEmpty {
                        FlowTags(tags: summary.topTags.prefix(5).map { "\($0.tag.title) · \($0.count)" }, accent: accent)
                    }
                    Text(summary.count == 1 ? "1 rating from RPI students" : "\(summary.count) ratings from RPI students")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("No ratings yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Be the First") { showRateSheet = true }
                        .buttonStyle(.bordered)
                        .tint(accent)
                }
            }
        }
        .task(id: socialManager.currentUser?.id) {
            if socialManager.isAuthenticated { await ratings.load() }
        }
        .sheet(isPresented: $showRateSheet) {
            RateClassSheet(
                courseTitle: courseTitle,
                existing: ratings.myRating,
                semesterCode: semesterCode,
                accent: accent,
                model: ratings
            )
        }
    }

    private func stat(_ value: String, label: String, systemImage: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).foregroundStyle(color).font(.caption)
                Text(value).font(.title3.bold()).monospacedDigit()
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Meeting blocks

/// Lecture, recitation, lab, exam, or off, for each weekly meeting. Exam
/// blocks only appear on the days picked, and each one becomes an exam task.
struct MeetingBlocksCard: View {
    @EnvironmentObject private var viewModel: CalendarViewModel
    let enrollment: EnrolledCourse
    let accent: Color

    @State private var picker: ExamPickerTarget?

    var body: some View {
        ClassCard(title: "Meeting Blocks", systemImage: "square.grid.3x1.below.line.grid.1x2") {
            InfoButton("Mark a weekly meeting as a recitation, lab, or exam, or turn it off. An exam block only shows on the days you pick, and each one is added to your exams.")
        } content: {
            if enrollment.section.meetings.isEmpty {
                Text("No scheduled meeting time")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(enrollment.section.meetings.enumerated()), id: \.offset) { index, meeting in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        row(meeting)
                    }
                }
            }
        }
        .sheet(item: $picker) { target in
            ExamDatesSheet(
                title: target.title,
                meetingDates: viewModel.meetingDates(for: enrollment, meeting: target.meeting),
                initial: Set(viewModel.examDates(for: target.key).map { Calendar.current.startOfDay(for: $0) }),
                accent: accent
            ) { picked in
                if picked.isEmpty, target.revertTo != nil {
                    viewModel.setMeetingOverrideType(target.revertTo ?? .lecture, for: target.key)
                } else {
                    viewModel.setExamDates(picked, for: target.key)
                }
            } onCancel: {
                if let revertTo = target.revertTo, viewModel.examDates(for: target.key).isEmpty {
                    viewModel.setMeetingOverrideType(revertTo, for: target.key)
                }
            }
        }
    }

    private func key(for meeting: Meeting) -> String {
        viewModel.meetingOverrideKey(enrollmentID: enrollment.id, course: enrollment.course, section: enrollment.section, meeting: meeting)
    }

    private func row(_ meeting: Meeting) -> some View {
        let key = key(for: meeting)
        let type = viewModel.meetingOverride(for: key).type
        let examDates = viewModel.examDates(for: key)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.dayTimeSummary)
                        .font(.subheadline.weight(.semibold))
                    Text(meeting.location.isEmpty ? "Location TBA" : meeting.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(MeetingBlockType.allCases) { option in
                        Button {
                            choose(option, current: type, meeting: meeting, key: key)
                        } label: {
                            if option == type {
                                Label(option.menuName, systemImage: "checkmark")
                            } else {
                                Text(option.menuName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(type.menuName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(accent)
                }
            }

            if type == .exam {
                Button {
                    picker = ExamPickerTarget(key: key, meeting: meeting, title: meeting.dayTimeSummary, revertTo: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "star.circle.fill").foregroundStyle(.orange)
                        Text(examDates.isEmpty ? "Pick exam days" : examDates.map { $0.formatted(.dateTime.month(.abbreviated).day()) }.joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text("Edit").fontWeight(.semibold).foregroundStyle(accent)
                    }
                    .font(.caption)
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else if type == .disabled {
                Text("Hidden from your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ option: MeetingBlockType, current: MeetingBlockType, meeting: Meeting, key: String) {
        guard option != current else { return }
        if option == .exam {
            // An exam block with no days hides the class every week, so ask
            // for the days right away.
            viewModel.setMeetingOverrideType(.exam, for: key)
            picker = ExamPickerTarget(key: key, meeting: meeting, title: meeting.dayTimeSummary, revertTo: current)
        } else {
            viewModel.setMeetingOverrideType(option, for: key)
        }
    }
}

