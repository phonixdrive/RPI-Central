// CourseDetailView.swift
// RPI Central

import SwiftUI

struct CourseDetailView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    let course: Course

    // per-section prereq bypass arming
    @State private var bypassArmed: Set<String> = []

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
                        // first tap arms bypass
                        bypassArmed.insert(section.id)
                        return
                    }

                    // add (NO bypassPrerequisites arg!)
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
