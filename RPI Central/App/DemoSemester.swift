//
//  DemoSemester.swift
//  RPI Central
//
//  Debug builds only: launch with RPI_DEMO_SEMESTER=1 to fill the app with a
//  realistic Fall 2026 schedule (real sections, a few tasks, a grade, notes,
//  and one event that overlaps a class). Used for testing and screenshots.
//

#if DEBUG
import SwiftUI

enum DemoSemester {
    private static let loadedKey = "debug_demo_semester_loaded_v1"

    @MainActor
    static func loadIfRequested(into viewModel: CalendarViewModel) {
        guard ProcessInfo.processInfo.environment["RPI_DEMO_SEMESTER"] == "1",
              !UserDefaults.standard.bool(forKey: loadedKey),
              let courses = try? QuACSLoader.buildCourses(termCode: Semester.fall2026.rawValue) else { return }

        viewModel.changeSemester(to: .fall2026)
        // RPI_DEMO_PSOFT=1 swaps Data Structures for Principles of Software
        // (same time slot), for trying the syllabus import on its syllabus.
        let psoft = ProcessInfo.processInfo.environment["RPI_DEMO_PSOFT"] == "1"
        let picks: [(subject: String, number: String, section: String)] = [
            psoft ? ("CSCI", "2600", "01") : ("CSCI", "1200", "01"),
            ("CSCI", "2200", "03"),
            ("PSYC", "1200", "01"),
            ("BIOL", "1010", "01"),
        ]
        for pick in picks {
            guard let course = courses.first(where: { $0.subject == pick.subject && $0.number == pick.number }),
                  let section = course.sections.first(where: { $0.section == pick.section }) else { continue }
            viewModel.addCourseSection(section, course: course, semester: .fall2026, allowFullSection: true)
        }

        let enrollments = viewModel.enrolledCourses.filter { $0.semesterCode == Semester.fall2026.rawValue }
        func id(_ subject: String, _ number: String) -> String? {
            enrollments.first { $0.course.subject == subject && $0.course.number == number }?.id
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }

        let tasks = TasksManager.shared
        let demoTasks: [CourseTask] = [
            CourseTask(enrollmentID: id("CSCI", "1200"), title: "HW 4: Recursion", kind: .assignment, dueDate: day(1, 23, 59)),
            CourseTask(enrollmentID: id("PSYC", "1200"), title: "Quiz 3", kind: .quiz, dueDate: day(2, 12, 0)),
            CourseTask(enrollmentID: id("CSCI", "2200"), title: "Midterm 1", kind: .exam, dueDate: day(4, 18, 0)),
            CourseTask(enrollmentID: id("BIOL", "1010"), title: "Lab Report 2", kind: .assignment, dueDate: day(5, 23, 59)),
            CourseTask(enrollmentID: id("CSCI", "1200"), title: "Test 1", kind: .exam, dueDate: day(8, 18, 0)),
            CourseTask(enrollmentID: id("PSYC", "1200"), title: "Research Paper Proposal", kind: .project, dueDate: day(11, 23, 59)),
        ]
        for task in demoTasks { tasks.add(task) }

        if let dataStructures = id("CSCI", "1200") {
            viewModel.setNotes("Office hours: Wed 4–6 PM, Lally 102\nTA: Priya (priya@rpi.edu)\nSubmitty for homework", for: dataStructures)
            GradeBreakdownStore.save(GradeBreakdown(categories: [
                GradeCategory(name: "Homework", weightPercent: 35, scorePercent: 94),
                GradeCategory(name: "Labs", weightPercent: 15, scorePercent: 100),
                GradeCategory(name: "Test 1", weightPercent: 20, scorePercent: 86),
                GradeCategory(name: "Test 2", weightPercent: 30),
            ]), enrollmentID: dataStructures)
        }

        // An event that overlaps Data Structures lecture, to show how
        // overlapping events stack and swipe.
        let fridayOffset = (0..<7).first { calendar.component(.weekday, from: day($0, 12)) == 6 } ?? 3
        _ = viewModel.addEvent(
            title: "Career Fair",
            location: "Armory",
            date: day(fridayOffset, 15),
            startTime: day(fridayOffset, 15),
            endTime: day(fridayOffset, 17),
            color: .orange
        )

        UserDefaults.standard.set(true, forKey: loadedKey)
    }
}
#endif
