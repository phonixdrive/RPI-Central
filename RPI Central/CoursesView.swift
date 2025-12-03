//  CoursesView.swift
//  RPI Central

import SwiftUI

struct CoursesView: View {
    @EnvironmentObject var catalogService: CourseCatalogService
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    @State private var searchText: String = ""

    private var filteredCourses: [Course] {
        let all = catalogService.courses
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return all }
        return all.filter { course in
            let code1 = "\(course.subject) \(course.number)".lowercased()
            let code2 = "\(course.subject)-\(course.number)".lowercased()
            return course.title.lowercased().contains(term)
                || code1.contains(term)
                || code2.contains(term)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if catalogService.isLoading {
                    ProgressView("Loading courses…")
                } else if let error = catalogService.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    List(filteredCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course)
                                .environmentObject(calendarViewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                // Course NAME first (bold)
                                Text(course.title)
                                    .font(.headline)

                                // Code underneath (COMM 2570)
                                Text("\(course.subject) \(course.number)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Courses")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer,
                prompt: "Search by code or name"
            )
        }
    }
}
