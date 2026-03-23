//
// CoursesView.swift
// RPI Central
//

import SwiftUI

struct CoursesView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @ObservedObject private var catalog = CourseCatalogService.shared

    @State private var searchText: String = ""
    @State private var selectedSubjectFilter: SubjectOption? = nil
    @State private var subjectBrowserPresentation: SubjectBrowserPresentation?

    private let filterColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableSubjectCodes: Set<String> {
        Set(catalog.courses.map(\.subject))
    }

    private var visibleSubjectCategories: [SubjectCategory] {
        SubjectCategory.allCases.compactMap { category in
            let availableSubjects = category.subjects.filter { availableSubjectCodes.contains($0.subjectCode) }
            guard !availableSubjects.isEmpty else { return nil }
            return SubjectCategory(id: category.id, title: category.title, subjects: availableSubjects)
        }
    }

    private var rowCardFill: Color {
        Color(.secondarySystemBackground).opacity(0.72)
    }

    private var rowCardStroke: Color {
        calendarViewModel.themeColor.opacity(0.08)
    }

    private var filteredCourses: [Course] {
        let allCourses = catalog.courses
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let baseCourses: [Course] = {
            guard !isSearching, let selectedSubjectFilter else { return allCourses }
            return allCourses.filter { $0.subject == selectedSubjectFilter.subjectCode }
        }()

        guard !trimmedQuery.isEmpty else {
            return baseCourses.sorted { ($0.subject, $0.number) < ($1.subject, $1.number) }
        }

        return allCourses.filter { course in
            course.subject.lowercased().contains(trimmedQuery) ||
            course.number.lowercased().contains(trimmedQuery) ||
            course.title.lowercased().contains(trimmedQuery)
        }
        .sorted { ($0.subject, $0.number) < ($1.subject, $1.number) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                List {
                    termSection

                    if !isSearching {
                        subjectBrowserShortcutSection
                        subjectBrowseSection
                    }

                    coursesSection
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .navigationTitle("Courses")
        }
        .searchable(text: $searchText, prompt: "Search by subject, number, or title")
        .sheet(item: $subjectBrowserPresentation) { presentation in
            SubjectBrowserSheet(
                presentation: presentation,
                selectedSubject: $selectedSubjectFilter,
                accent: calendarViewModel.themeColor
            )
        }
        .onAppear {
            catalog.syncFromCalendarViewModel(currentSemester: calendarViewModel.currentSemester)
            clearUnavailableSubjectFilterIfNeeded()
        }
        .onChange(of: calendarViewModel.currentSemester) { _, newSem in
            catalog.syncFromCalendarViewModel(currentSemester: newSem)
        }
        .onReceive(catalog.$courses) { _ in
            clearUnavailableSubjectFilterIfNeeded()
        }
    }

    private var termSection: some View {
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
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(rowCardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(rowCardStroke, lineWidth: 1)
            )
            .onChange(of: catalog.semester) { _, newValue in
                calendarViewModel.changeSemester(to: newValue)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var subjectBrowseSection: some View {
        Section {
            LazyVGrid(columns: filterColumns, spacing: 12) {
                ForEach(visibleSubjectCategories) { category in
                    Button {
                        subjectBrowserPresentation = SubjectBrowserPresentation(
                            title: category.title,
                            categories: [category]
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Text("\(category.subjects.count) subjects")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(rowCardFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(rowCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("Browse by Area")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var subjectBrowserShortcutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    subjectBrowserPresentation = SubjectBrowserPresentation(
                        title: "All Subjects",
                        categories: visibleSubjectCategories
                    )
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.headline)
                            .foregroundStyle(calendarViewModel.themeColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Browse all subjects")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text("Open the full subject list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(rowCardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(rowCardStroke, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                if let currentSubjectFilter = selectedSubjectFilter {
                    HStack(spacing: 10) {
                        Text("Filtered by")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(currentSubjectFilter.subjectCode) \(currentSubjectFilter.displayName)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(calendarViewModel.themeColor.opacity(0.12))
                            )

                        Spacer()

                        Button("Clear filter") {
                            self.selectedSubjectFilter = nil
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var coursesSection: some View {
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
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(rowCardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(rowCardStroke, lineWidth: 1)
                    )
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        } header: {
            if let selectedSubjectFilter, !isSearching {
                Text("\(selectedSubjectFilter.displayName) Courses")
            } else {
                Text("Courses")
            }
        }
    }

    private func clearUnavailableSubjectFilterIfNeeded() {
        guard let selectedSubjectFilter else { return }
        if !availableSubjectCodes.contains(selectedSubjectFilter.subjectCode) {
            self.selectedSubjectFilter = nil
        }
    }
}

private struct SubjectBrowserSheet: View {
    let presentation: SubjectBrowserPresentation
    @Binding var selectedSubject: SubjectOption?
    let accent: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if selectedSubject != nil {
                    Section {
                        Button("Clear subject filter") {
                            selectedSubject = nil
                            dismiss()
                        }
                    }
                }

                ForEach(presentation.categories) { category in
                    Section(category.title) {
                        ForEach(category.subjects) { subject in
                            Button {
                                selectedSubject = subject
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(subject.displayName)
                                            .foregroundStyle(.primary)
                                        Text(subject.subjectCode)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedSubject == subject {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SubjectBrowserPresentation: Identifiable {
    let title: String
    let categories: [SubjectCategory]
    let id = UUID()
}

private struct SubjectCategory: Identifiable, Equatable {
    let id: String
    let title: String
    let subjects: [SubjectOption]

    static let allCases: [SubjectCategory] = [
        SubjectCategory(
            id: "hass",
            title: "Humanities, Arts, and Social Sciences",
            subjects: [
                SubjectOption(subjectCode: "ARTS", displayName: "Arts"),
                SubjectOption(subjectCode: "COGS", displayName: "Cognitive Science"),
                SubjectOption(subjectCode: "COMM", displayName: "Communication"),
                SubjectOption(subjectCode: "ECON", displayName: "Economics"),
                SubjectOption(subjectCode: "GSAS", displayName: "Games and Simulation Arts and Sciences"),
                SubjectOption(subjectCode: "IHSS", displayName: "Interdisciplinary Humanities and Social Sciences"),
                SubjectOption(subjectCode: "INQR", displayName: "HASS Inquiry"),
                SubjectOption(subjectCode: "LANG", displayName: "Foreign Languages"),
                SubjectOption(subjectCode: "LITR", displayName: "Literature"),
                SubjectOption(subjectCode: "PHIL", displayName: "Philosophy"),
                SubjectOption(subjectCode: "PSYC", displayName: "Psychology"),
                SubjectOption(subjectCode: "STSO", displayName: "Science, Technology, and Society"),
                SubjectOption(subjectCode: "WRIT", displayName: "Writing"),
            ]
        ),
        SubjectCategory(
            id: "interdisciplinary",
            title: "Interdisciplinary and Other",
            subjects: [
                SubjectOption(subjectCode: "ADMN", displayName: "Administrative Courses"),
                SubjectOption(subjectCode: "USAF", displayName: "Aerospace Studies (Air Force ROTC)"),
                SubjectOption(subjectCode: "USAR", displayName: "Military Science (Army ROTC)"),
                SubjectOption(subjectCode: "USNA", displayName: "Naval Science (Navy ROTC)"),
            ]
        ),
        SubjectCategory(
            id: "engineering",
            title: "Engineering",
            subjects: [
                SubjectOption(subjectCode: "BMED", displayName: "Biomedical Engineering"),
                SubjectOption(subjectCode: "CHME", displayName: "Chemical Engineering"),
                SubjectOption(subjectCode: "CIVL", displayName: "Civil Engineering"),
                SubjectOption(subjectCode: "ECSE", displayName: "Electrical, Computer, and Systems Engineering"),
                SubjectOption(subjectCode: "ENGR", displayName: "General Engineering"),
                SubjectOption(subjectCode: "ENVE", displayName: "Environmental Engineering"),
                SubjectOption(subjectCode: "ESCI", displayName: "Engineering Science"),
                SubjectOption(subjectCode: "ISYE", displayName: "Industrial and Systems Engineering"),
                SubjectOption(subjectCode: "MANE", displayName: "Mechanical, Aerospace, and Nuclear Engineering"),
                SubjectOption(subjectCode: "MTLE", displayName: "Materials Science and Engineering"),
            ]
        ),
        SubjectCategory(
            id: "architecture",
            title: "Architecture",
            subjects: [
                SubjectOption(subjectCode: "ARCH", displayName: "Architecture"),
                SubjectOption(subjectCode: "LGHT", displayName: "Lighting"),
            ]
        ),
        SubjectCategory(
            id: "itws",
            title: "Information Technology and Web Science",
            subjects: [
                SubjectOption(subjectCode: "ITWS", displayName: "Information Technology and Web Science"),
            ]
        ),
        SubjectCategory(
            id: "science",
            title: "Science",
            subjects: [
                SubjectOption(subjectCode: "ASTR", displayName: "Astronomy"),
                SubjectOption(subjectCode: "BCBP", displayName: "Biochemistry and Biophysics"),
                SubjectOption(subjectCode: "BIOL", displayName: "Biology"),
                SubjectOption(subjectCode: "CHEM", displayName: "Chemistry"),
                SubjectOption(subjectCode: "CSCI", displayName: "Computer Science"),
                SubjectOption(subjectCode: "ERTH", displayName: "Earth and Environmental Science"),
                SubjectOption(subjectCode: "ISCI", displayName: "Interdisciplinary Science"),
                SubjectOption(subjectCode: "MATH", displayName: "Mathematics"),
                SubjectOption(subjectCode: "MATP", displayName: "Mathematical Programming, Probability, and Statistics"),
                SubjectOption(subjectCode: "PHYS", displayName: "Physics"),
            ]
        ),
        SubjectCategory(
            id: "management",
            title: "Management",
            subjects: [
                SubjectOption(subjectCode: "BUSN", displayName: "Business (H)"),
                SubjectOption(subjectCode: "MGMT", displayName: "Management"),
            ]
        ),
        SubjectCategory(
            id: "uncategorized",
            title: "Uncategorized",
            subjects: [
                SubjectOption(subjectCode: "ILEA", displayName: "Independent Learning Experience"),
            ]
        ),
    ]
}

private struct SubjectOption: Identifiable, Equatable, Hashable {
    let subjectCode: String
    let displayName: String

    var id: String { subjectCode }
}
