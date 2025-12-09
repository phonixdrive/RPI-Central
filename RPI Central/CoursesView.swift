// CoursesView.swift
// RPI Central

import SwiftUI

struct CoursesView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @StateObject private var catalog = CourseCatalogService.shared
    @State private var searchText: String = ""

    private var filteredCourses: [Course] {
        let all = catalog.courses
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return all.sorted { ($0.subject, $0.number) < ($1.subject, $1.number) }
        }

        let query = searchText.lowercased()
        return all.filter { course in
            course.subject.lowercased().contains(query) ||
            course.number.lowercased().contains(query) ||
            course.title.lowercased().contains(query)
        }
        .sorted { ($0.subject, $0.number) < ($1.subject, $1.number) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Semester picker
                Picker("Semester", selection: $catalog.semester) {
                    ForEach(Semester.allCases) { sem in
                        Text(sem.displayName).tag(sem)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: catalog.semester) { _, newValue in
                    calendarViewModel.changeSemester(to: newValue)
                }

                List {
                    ForEach(filteredCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course)
                                .environmentObject(calendarViewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(course.subject) \(course.number)")
                                    .font(.headline)
                                Text(course.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Courses")
        }
        .searchable(text: $searchText, prompt: "Search by subject, number, or title")
    }
}
