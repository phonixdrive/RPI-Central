//  CourseDetailView.swift
//  RPI Central

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    let course: Course

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(course.subject) \(course.number)")
                        .font(.title.bold())

                    Text(course.title)
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

    // MARK: - Section card

    private func sectionCard(_ section: CourseSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let crnText = section.crn.map(String.init) ?? "N/A"
                Text("CRN \(crnText) • Sec \(section.section)")
                    .font(.subheadline.bold())
                Spacer()
                Button("Add") {
                    calendarViewModel.addCourseSection(section, course: course)
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
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
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
