//  HomeView.swift
//  RPI Central

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    var body: some View {
        NavigationStack {
            List {
                if calendarViewModel.enrolledCourses.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No courses added yet")
                            .font(.headline)
                        Text("Go to the Courses tab and tap Add on the sections you’re taking.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Section("My Courses") {
                        ForEach(calendarViewModel.enrolledCourses) { enrollment in
                            let course = enrollment.course
                            let section = enrollment.section
                            let crnText = section.crn.map(String.init) ?? "N/A"

                            VStack(alignment: .leading, spacing: 4) {
                                Text(course.title)
                                    .font(.headline)

                                Text("\(course.subject) \(course.number) • CRN \(crnText)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                if let m = section.meetings.first {
                                    Text("\(m.days.map { $0.shortName }.joined()) \(m.start) – \(m.end)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: calendarViewModel.removeEnrollment)
                    }
                }
            }
            .navigationTitle("Home")
        }
    }
}
