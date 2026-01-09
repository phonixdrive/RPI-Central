//
//  HomeView.swift
//  RPI Central
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    private var groupedBySemester: [String: [EnrolledCourse]] {
        Dictionary(grouping: calendarViewModel.enrolledCourses, by: { $0.semesterCode })
    }

    private var sortedSemesterCodes: [String] {
        groupedBySemester.keys.sorted()
    }

    var body: some View {
        NavigationStack {
            List {
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
                                NavigationLink {
                                    CourseDetailView(course: enrollment.course)
                                        .environmentObject(calendarViewModel)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(enrollment.course.subject) \(enrollment.course.number)")
                                            .font(.headline)
                                        Text(enrollment.course.title)
                                            .font(.subheadline)

                                        if let firstMeeting = enrollment.section.meetings.first {
                                            Text(firstMeeting.humanReadableSummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        if !enrollment.section.instructor.isEmpty {
                                            Text(enrollment.section.instructor)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer(minLength: 8)

                                GradeMenu(enrollmentID: enrollment.id)
                                    .environmentObject(calendarViewModel)
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

private struct GradeMenu: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    let enrollmentID: String

    var body: some View {
        let current = calendarViewModel.grade(for: enrollmentID)

        Menu {
            ForEach(LetterGrade.ordered, id: \.rawValue) { g in
                Button {
                    calendarViewModel.setGrade(g, for: enrollmentID)
                } label: {
                    if current == g {
                        Label(g.rawValue, systemImage: "checkmark")
                    } else {
                        Text(g.rawValue)
                    }
                }
            }

            if current != nil {
                Divider()

                Button(role: .destructive) {
                    calendarViewModel.clearGrade(for: enrollmentID)
                } label: {
                    Label("Clear grade", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current?.rawValue ?? "Grade")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set grade")
    }
}

// MARK: - Meeting helper

extension Meeting {
    /// Human-readable summary of the first meeting, e.g.
    /// "M, W, F 10:00–10:50 · DARRIN 330"
    var humanReadableSummary: String {
        // ✅ Key fix: show actual weekday codes ("M", "R") instead of enum case names ("mon", "thu")
        let daysString = days.map { $0.shortName }.joined(separator: ", ")

        if location.isEmpty {
            return "\(daysString) \(start)–\(end)"
        } else {
            return "\(daysString) \(start)–\(end) · \(location)"
        }
    }
}
