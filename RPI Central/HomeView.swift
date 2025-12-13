// HomeView.swift
// RPI Central

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    var body: some View {
        NavigationStack {
            List {
                let grouped = Dictionary(grouping: calendarViewModel.enrolledCourses) { $0.semesterCode }
                let sortedSemesterCodes = grouped.keys.sorted()

                ForEach(sortedSemesterCodes, id: \.self) { semCode in
                    let enrollments = grouped[semCode] ?? []
                    let semester = Semester(rawValue: semCode)

                    Section(semester?.displayName ?? semCode) {
                        ForEach(enrollments) { enrollment in
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
                        }
                        .onDelete { offsets in
                            let toDelete = offsets.map { enrollments[$0] }
                            for e in toDelete {
                                calendarViewModel.removeEnrollment(e)
                            }
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
    /// Human-readable summary of the first meeting, e.g.
    /// "M, W, F 10:00–10:50 · DARRIN 330"
    var humanReadableSummary: String {
        // Works whether `days` is [String] or [Weekday] enum:
        let daysString = days.map { "\($0)" }.joined(separator: ", ")

        if location.isEmpty {
            return "\(daysString) \(start)–\(end)"
        } else {
            return "\(daysString) \(start)–\(end) · \(location)"
        }
    }
}
