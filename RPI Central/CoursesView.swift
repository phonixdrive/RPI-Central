//
// CoursesView.swift
// RPI Central
//

import SwiftUI

struct CoursesView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    // ✅ Singleton should be ObservedObject, not StateObject
    @ObservedObject private var catalog = CourseCatalogService.shared

    @State private var searchText: String = ""
    @State private var selectedSubjectFilter: SubjectFilter? = nil

    private let filterColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleSubjectFilters: [SubjectFilter] {
        let availableSubjects = Set(catalog.courses.map(\.subject))
        return SubjectFilter.featured.filter { availableSubjects.contains($0.subjectCode) }
    }

    private var filteredCourses: [Course] {
        let all = catalog.courses
        let baseCourses: [Course] = {
            guard !isSearching, let selectedSubjectFilter else { return all }
            return all.filter { $0.subject == selectedSubjectFilter.subjectCode }
        }()

        guard isSearching else {
            return baseCourses.sorted { ($0.subject, $0.number) < ($1.subject, $1.number) }
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
            List {
                Section {
                    HStack {
                        Text("Term")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Picker("", selection: $catalog.semester) {
                            ForEach(Semester.allCases.sorted(by: { $0.rawValue > $1.rawValue })) { sem in
                                Text(sem.displayName).tag(sem)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .onChange(of: catalog.semester) { _, newValue in
                        calendarViewModel.changeSemester(to: newValue)
                    }
                }

                if !isSearching {
                    Section {
                        LazyVGrid(columns: filterColumns, spacing: 12) {
                            ForEach(visibleSubjectFilters) { filter in
                                Button {
                                    if selectedSubjectFilter == filter {
                                        selectedSubjectFilter = nil
                                    } else {
                                        selectedSubjectFilter = filter
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(filter.displayName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(selectedSubjectFilter == filter ? .white : .primary)

                                        Text(filter.subjectCode)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(selectedSubjectFilter == filter ? .white.opacity(0.8) : .secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(selectedSubjectFilter == filter ? calendarViewModel.themeColor : Color(.secondarySystemBackground))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if selectedSubjectFilter != nil {
                            Button("Clear subject filter") {
                                selectedSubjectFilter = nil
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    } header: {
                        Text("Browse by Subject(and scroll down)")
                    }
                }

                Section {
                    ForEach(filteredCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course)
                                .environmentObject(calendarViewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.title)
                                    .font(.headline)
                                Text("\(course.subject) \(course.number)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    if let selectedSubjectFilter, !isSearching {
                        Text("\(selectedSubjectFilter.displayName) Courses")
                    } else {
                        Text("Courses")
                    }
                }
            }
            .navigationTitle("Courses")
            .listStyle(.plain)
        }
        .searchable(text: $searchText, prompt: "Search by subject, number, or title")
        .onAppear {
            // ✅ Force picker + loaded catalog term to match the app's current semester
            catalog.syncFromCalendarViewModel(currentSemester: calendarViewModel.currentSemester)
        }
        .onChange(of: calendarViewModel.currentSemester) { _, newSem in
            // ✅ Keep courses tab in sync if something else changes the semester
            catalog.syncFromCalendarViewModel(currentSemester: newSem)
        }
    }
}

private struct SubjectFilter: Identifiable, Equatable {
    let subjectCode: String
    let displayName: String

    var id: String { subjectCode }

    static let featured: [SubjectFilter] = [
        SubjectFilter(subjectCode: "CSCI", displayName: "Computer Science"),
        SubjectFilter(subjectCode: "ECON", displayName: "Economics"),
        SubjectFilter(subjectCode: "ENGR", displayName: "Engineering"),
        SubjectFilter(subjectCode: "MATH", displayName: "Mathematics"),
        SubjectFilter(subjectCode: "PHYS", displayName: "Physics"),
        SubjectFilter(subjectCode: "ECSE", displayName: "Electrical & Computer"),
        SubjectFilter(subjectCode: "MANE", displayName: "Mechanical & Aero"),
        SubjectFilter(subjectCode: "BIOL", displayName: "Biology"),
        SubjectFilter(subjectCode: "BMED", displayName: "Biomedical"),
        SubjectFilter(subjectCode: "MGMT", displayName: "Management"),
        SubjectFilter(subjectCode: "IHSS", displayName: "Humanities"),
        SubjectFilter(subjectCode: "STSH", displayName: "Science & Tech")
    ]
}
