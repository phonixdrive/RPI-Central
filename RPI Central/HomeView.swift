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
        groupedBySemester.keys.sorted(by: >) // newest termCode first
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
                                // LEFT: course info (takes remaining width)
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

                                // RIGHT: grade capsule (guaranteed visible)
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
        }
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
