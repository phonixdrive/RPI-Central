//
//  RPI_CentralTests.swift
//  RPI CentralTests
//
//  Created by Neil Shrestha on 10/3/25.
//

import Foundation
import Testing
@testable import RPI_Central

struct RPI_CentralTests {

    @Test func bundledSemesterDataLoadsForEverySupportedTerm() throws {
        let appBundle = Bundle(for: CourseCatalogService.self)

        for semester in Semester.allCases {
            let courses = try QuACSLoader.buildCourses(
                termCode: semester.rawValue,
                bundle: appBundle
            )

            #expect(!courses.isEmpty, "No courses decoded for \(semester.rawValue)")
        }
    }

    @Test func fall2026IsTheCurrentTerm() throws {
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fallDate = try #require(calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 27,
            hour: 12
        )))

        #expect(CalendarViewModel.defaultCurrentSemester(for: fallDate) == .fall2026)
        #expect(Semester.fall2026.displayName == "Fall 2026 (current term)")
    }

    @Test func fullAndClosedSectionsHaveDifferentBypassStates() {
        let fullSection = CourseSection(
            crn: 12345,
            section: "01",
            instructor: "Staff",
            meetings: [],
            currentEnrollment: 30,
            enrollmentCap: 30,
            seatsRemaining: 0
        )
        let closedSection = CourseSection(
            crn: 54321,
            section: "02",
            instructor: "Staff",
            meetings: [],
            currentEnrollment: 0,
            enrollmentCap: 0,
            seatsRemaining: 0
        )

        #expect(fullSection.isFullForRegistration)
        #expect(!fullSection.isRegistrationClosed)
        #expect(closedSection.isRegistrationClosed)
        #expect(!closedSection.isFullForRegistration)
    }

    @Test func fall2026AcademicCalendarIncludesThanksgivingAndOfficialBounds() throws {
        let service = AcademicCalendarService.shared
        let academicCalendar = try service.loadBundledCalendar(named: "academic_calendar_26")

        #expect(academicCalendar.academicYear == "2026")
        #expect(academicCalendar.terms.fall.classesBegin == "2026-08-27")
        #expect(academicCalendar.terms.fall.classesEnd == "2026-12-11")
        #expect(academicCalendar.events.count == 29)

        let thanksgiving = try #require(
            academicCalendar.events.first { $0.title == "Thanksgiving Break-no classes." }
        )
        #expect(thanksgiving.startDate == "2026-11-23")
        #expect(thanksgiving.endDate == "2026-11-27")
        #expect(thanksgiving.tags.noClasses)
        #expect(thanksgiving.tags.break)

        let thanksgivingDays = service.expandToPerDayEvents(academicCalendar)
            .filter { $0.raw.title == thanksgiving.title }
        #expect(thanksgivingDays.count == 5)
    }

    @Test func calendarDisplayModeCanRoundTripThroughPersistentRawValue() throws {
        let restored = try #require(CalendarDisplayMode(rawValue: CalendarDisplayMode.month.rawValue))
        #expect(restored == .month)
    }

    @Test func homeWidgetSizesOnlyOfferLayoutsThatFitTheirContent() {
        #expect(!HomeDashboardSection.next.supportedWidgetSizes.contains(.oneByOne))
        #expect(HomeDashboardSection.next.supportedWidgetSizes.contains(.oneByTwo))
        #expect(HomeDashboardSection.next.supportedWidgetSizes.contains(.twoByTwo))
        #expect(HomeDashboardSection.diningHours.supportedWidgetSizes == HomeDashboardWidgetSize.allCases)
    }

    @Test func homeWidgetLayoutPersistsAcrossFreshLoads() throws {
        let suiteName = "RPI_CentralTests.homeDashboard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let order: [HomeDashboardSection] = [
            .next, .studyTimer, .shuttleTracker, .upcoming, .diningHours,
            .mealSwipes, .flexDollars
        ]
        let hidden: Set<HomeDashboardSection> = [.diningHours]
        let sizes: [HomeDashboardSection: HomeDashboardWidgetSize] = [
            .next: .twoByTwo,
            .studyTimer: .oneByOne,
            .shuttleTracker: .oneByTwo
        ]

        CalendarViewModel.saveHomeDashboardPreferences(
            order: order,
            hidden: hidden,
            sizes: sizes,
            to: defaults
        )

        #expect(CalendarViewModel.loadHomeSectionOrder(from: defaults) == order)
        #expect(CalendarViewModel.loadHiddenHomeSections(from: defaults) == hidden)
        #expect(CalendarViewModel.loadHomeSectionSizes(from: defaults) == sizes)
    }

    @Test func academicHistoryStartHidesEveryEarlierSemester() {
        let visible = Semester.academicTerms(startingAt: .fall2024)

        #expect(visible.contains(.fall2024))
        #expect(visible.contains(.spring2025))
        #expect(!visible.contains(.spring2024))
        #expect(!visible.contains(.fall2023))
        #expect(!visible.contains(.fall2022))
    }

    @Test func groupChatUnreadPolicyUsesOneMonotonicReadCursor() throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)

        #expect(!GroupChatUnreadPolicy.hasUnread(
            latestMessageID: nil,
            latestMessageDate: newDate,
            latestSenderID: nil,
            viewerID: "viewer",
            readMessageID: nil,
            readMessageDate: nil
        ))
        #expect(GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "new",
            latestMessageDate: newDate,
            latestSenderID: "friend",
            viewerID: "viewer",
            readMessageID: "old",
            readMessageDate: oldDate
        ))
        #expect(!GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "seen",
            latestMessageDate: newDate,
            latestSenderID: "friend",
            viewerID: "viewer",
            readMessageID: "seen",
            readMessageDate: newDate
        ))
        #expect(!GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "older-after-delete",
            latestMessageDate: oldDate,
            latestSenderID: "friend",
            viewerID: "viewer",
            readMessageID: "deleted-latest",
            readMessageDate: newDate
        ))
        #expect(!GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "stale-server-id",
            latestMessageDate: newDate,
            latestSenderID: "friend",
            viewerID: "viewer",
            readMessageID: "actually-seen-id",
            readMessageDate: newDate,
            latestThreadVersionWasAcknowledged: true
        ))
        #expect(GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "different-message-in-same-second",
            latestMessageDate: newDate,
            latestSenderID: "friend",
            viewerID: "viewer",
            readMessageID: "actually-seen-id",
            readMessageDate: newDate
        ))
        #expect(!GroupChatUnreadPolicy.hasUnread(
            latestMessageID: "mine",
            latestMessageDate: newDate,
            latestSenderID: "viewer",
            viewerID: "viewer",
            readMessageID: nil,
            readMessageDate: nil
        ))
    }

    @Test func currentSemesterEnrollmentSnapshotsRefreshWithoutTouchingHistory() throws {
        let oldSection = CourseSection(
            crn: 12345,
            section: "01",
            instructor: "Staff",
            meetings: [Meeting(days: [.mon], start: "10:00", end: "11:20", location: "DCC 308")]
        )
        let refreshedSection = CourseSection(
            crn: 12345,
            section: "01",
            instructor: "New Instructor",
            meetings: [Meeting(days: [.mon], start: "10:00", end: "11:20", location: "DCC 318")]
        )
        let oldCourse = Course(
            subject: "CSCI",
            number: "2300",
            title: "Data Structures",
            description: "Old catalog snapshot",
            sections: [oldSection]
        )
        let refreshedCourse = Course(
            subject: "CSCI",
            number: "2300",
            title: "Data Structures",
            description: "Newest catalog snapshot",
            sections: [refreshedSection]
        )
        let currentEnrollment = EnrolledCourse(
            id: "CSCI-2300-12345",
            course: oldCourse,
            section: oldSection,
            semesterCode: Semester.fall2026.rawValue
        )
        let historicalEnrollment = EnrolledCourse(
            id: "CSCI-2300-12345",
            course: oldCourse,
            section: oldSection,
            semesterCode: Semester.spring2026.rawValue
        )

        let refreshed = CalendarViewModel.refreshedEnrollmentSnapshots(
            [currentEnrollment, historicalEnrollment],
            from: [refreshedCourse],
            for: .fall2026
        )

        #expect(refreshed[0].id == currentEnrollment.id)
        #expect(refreshed[0].section.meetings.first?.location == "DCC 318")
        #expect(refreshed[0].section.instructor == "New Instructor")
        #expect(refreshed[1].section.meetings.first?.location == "DCC 308")
    }

}
