//
//  CourseDetailView.swift
//  RPI Central
//

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    let course: Course

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
    }

    private func sectionCard(_ section: CourseSection) -> some View {
        let isEnrolled = calendarViewModel.isEnrolled(for: course, section: section)
        let hasConflict = calendarViewModel.hasConflict(for: course, section: section)
        let crnText = section.crn.map(String.init) ?? "N/A"

        let buttonTitle: String = {
            if isEnrolled { return "Remove" }
            if hasConflict { return "Time conflict" }
            return "Add"
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
                    } else {
                        calendarViewModel.addCourseSection(section, course: course)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isEnrolled ? .red : (hasConflict ? .gray : .accentColor))
                .font(.caption)
                .disabled(!isEnrolled && hasConflict)
            }

            if !section.instructor.isEmpty {
                Text(section.instructor)
                    .font(.subheadline)
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

            if !section.prerequisitesText.isEmpty {
                Text("Prereqs: \(section.prerequisitesText)")
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
