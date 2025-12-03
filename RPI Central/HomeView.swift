//  HomeView.swift
//  RPI Central

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    @State private var selectedEnrollment: EnrolledCourse?
    @State private var showRemoveDialog = false

    var body: some View {
        List {
            Section("Current Courses") {
                if calendarViewModel.enrolledCourses.isEmpty {
                    Text("No courses yet. Use \"Browse Courses\" to add.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarViewModel.enrolledCourses) { enrollment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(enrollment.course.title)
                                .font(.headline)
                            Text("\(enrollment.course.subject) \(enrollment.course.number)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEnrollment = enrollment
                            showRemoveDialog = true
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                calendarViewModel.removeEnrollment(enrollment)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink("Browse Courses") {
                    CoursesView()
                }
            }
        }
        .navigationTitle("Home")
        .confirmationDialog(
            "Course options",
            isPresented: $showRemoveDialog,
            presenting: selectedEnrollment
        ) { enrollment in
            Button("Remove \(enrollment.course.subject) \(enrollment.course.number)",
                   role: .destructive) {
                calendarViewModel.removeEnrollment(enrollment)
            }
            Button("Cancel", role: .cancel) { }
        } message: { enrollment in
            Text(enrollment.course.title)
        }
    }
}
