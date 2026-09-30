//
//  SharingAndLocationTests.swift
//  RPI CentralTests
//

import CoreLocation
import Foundation
import Testing
@testable import RPI_Central

struct SharingAndLocationTests {
    private let directory = CampusDirectory.loadBundled(bundle: Bundle(for: CourseCatalogService.self))

    // MARK: - Campus buildings

    @Test func bundledCampusBuildingsLoad() throws {
        #expect(directory.buildings.count >= 50)
        #expect(directory.attribution.contains("OpenStreetMap"))
        #expect(try #require(directory.building(id: "dcc")).shortName == "DCC")
    }

    @Test func coordinatesResolveToCampusBuildings() throws {
        let dcc = try #require(directory.building(id: "dcc"))

        #expect(directory.building(containing: dcc.center)?.id == "dcc")
        let inside = directory.place(for: dcc.center, horizontalAccuracy: 10)
        #expect(inside.kind == .inside)
        #expect(inside.label == "In DCC")

        // An imprecise fix is only "near" the building.
        #expect(directory.place(for: dcc.center, horizontalAccuracy: 80).kind == .near)

        let albany = CLLocationCoordinate2D(latitude: 42.6526, longitude: -73.7562)
        #expect(directory.place(for: albany, horizontalAccuracy: 10).kind == .offCampus)
    }

    @Test func scheduleRoomsMatchTheirBuildings() {
        let dcc = directory.match(scheduleLocation: "Darrin Communications Center 308")
        #expect(dcc?.building.id == "dcc")
        #expect(dcc?.room == "308")

        #expect(directory.match(scheduleLocation: "Low Center for Industrial Inn. 4050")?.building.id == "low")
        #expect(directory.match(scheduleLocation: "Russell Sage Laboratory 3303")?.building.id == "sage")
        #expect(directory.match(scheduleLocation: "Greene Building STU")?.room == "STU")
        #expect(directory.shortRoomLabel(for: "Jonsson Engineering Center 3117") == "JEC 3117")

        #expect(directory.match(scheduleLocation: "TBA") == nil)
        #expect(directory.match(scheduleLocation: "Online") == nil)
        #expect(directory.match(scheduleLocation: "") == nil)
    }

    // MARK: - Friend presence

    @Test func liveLocationAndScheduleAgreeOnClass() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let dcc = try #require(directory.building(id: "dcc"))
        let location = SharedFriendLocation(
            id: "friend",
            latitude: dcc.center.latitude,
            longitude: dcc.center.longitude,
            accuracy: 12,
            precision: .precise,
            placeID: "dcc",
            placeName: dcc.name,
            placeKind: .inside,
            isOnCampus: true,
            updatedAt: now.addingTimeInterval(-120),
            expiresAt: nil
        )

        let presence = try #require(FriendPresenceResolver.resolve(
            friend: friend(),
            location: location,
            schedule: schedule(classAt: "Darrin Communications Center 308", around: now),
            now: now,
            directory: directory
        ))

        #expect(presence.freshness == .live)
        #expect(presence.headline == "In class · Data Structures")
        #expect(presence.detail?.hasPrefix("DCC 308") == true)
        #expect(presence.building?.id == "dcc")
    }

    @Test func scheduleOnlyFriendsAppearAtTheirClassroom() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let presence = try #require(FriendPresenceResolver.resolve(
            friend: friend(),
            location: nil,
            schedule: schedule(classAt: "Jonsson Engineering Center 3117", around: now),
            now: now,
            directory: directory
        ))

        #expect(presence.freshness == .scheduled)
        #expect(presence.building?.id == "jec")
        #expect(presence.coordinate?.latitude == directory.building(id: "jec")?.center.latitude)
    }

    @Test func expiredLocationsAreHidden() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let expired = SharedFriendLocation(
            id: "friend",
            latitude: 42.73,
            longitude: -73.68,
            accuracy: 10,
            precision: .precise,
            placeID: nil,
            placeName: nil,
            placeKind: .onCampus,
            isOnCampus: true,
            updatedAt: now.addingTimeInterval(-300),
            expiresAt: now.addingTimeInterval(-60)
        )
        #expect(!expired.isVisible(at: now))
        #expect(FriendPresenceResolver.resolve(friend: friend(), location: expired, schedule: nil, now: now, directory: directory) == nil)
    }

    @Test func locationViewersFollowTheChosenAudience() {
        var settings = LocationSharingSettings()
        settings.audience = .allFriends
        #expect(settings.viewerIDs(friendIDs: ["b", "a"]) == ["a", "b"])

        settings.audience = .selectedFriends
        settings.selectedFriendIDs = ["a", "former-friend"]
        #expect(settings.viewerIDs(friendIDs: ["a", "b"]) == ["a"])
    }

    @Test func sharingDurationsExpireAtTheRightTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 14)))

        #expect(LocationShareDuration.oneHour.expiration(from: now, calendar: calendar) == now.addingTimeInterval(3600))
        #expect(LocationShareDuration.indefinitely.expiration(from: now, calendar: calendar) == nil)
        let endOfDay = try #require(LocationShareDuration.untilEndOfDay.expiration(from: now, calendar: calendar))
        #expect(calendar.component(.hour, from: endOfDay) == 23)
        #expect(calendar.isDate(endOfDay, inSameDayAs: now))
    }

    // MARK: - Shared schedules

    @Test func sharedSchedulesReportWhatTheyCover() throws {
        let covered = SharedScheduleSnapshot(
            semesterCode: "202609",
            generatedAt: "2026-09-28T12:00:00Z",
            items: [],
            coverageStart: "2026-09-21T04:00:00Z",
            coverageEnd: "2026-12-22T04:59:59Z"
        )
        #expect(covered.coverageEndDate == SharedScheduleDates.parse("2026-12-22T04:59:59Z"))

        // Snapshots from older builds end at their last item.
        let legacy = SharedScheduleSnapshot(
            semesterCode: "202609",
            generatedAt: nil,
            items: [
                item(start: "2026-09-29T14:00:00Z", end: "2026-09-29T15:50:00Z"),
                item(start: "2026-10-01T14:00:00Z", end: "2026-10-01T15:50:00Z"),
            ]
        )
        #expect(legacy.coverageEndDate == SharedScheduleDates.parse("2026-10-01T15:50:00Z"))
    }

    @Test func fingerprintsAreStable() {
        #expect(SocialHashing.fnv1a64Hex(Data()) == "cbf29ce484222325")
        #expect(SocialHashing.fnv1a64Hex(Data("a".utf8)) == "af63dc4c8601ec8c")
    }

    // MARK: - Academic calendar

    @Test func followDaysNameTheWeekdayToFollow() {
        #expect(AcademicEvent.followedWeekday(inTitle: "Follow a Monday Class Schedule today") == 2)
        #expect(AcademicEvent.followedWeekday(inTitle: "Fall 2025 Classes Begin-Follow a Monday Class Schedule today") == 2)
        #expect(AcademicEvent.followedWeekday(inTitle: "Follow a Friday Class Schedule today") == 6)
        #expect(AcademicEvent.followedWeekday(inTitle: "Labor Day-no classes") == nil)
    }

    @Test func fall2026CalendarCancelsHolidayClassesAndFollowsMondays() async throws {
        let events: [AcademicEvent] = try await withCheckedThrowingContinuation { continuation in
            AcademicCalendarService.shared.fetchEvents(for: .fall2026) { result in
                continuation.resume(with: result)
            }
        }

        let laborDay = try #require(events.first { $0.title.hasPrefix("Labor Day") })
        #expect(laborDay.cancelsClasses)

        let thanksgiving = try #require(events.first { $0.title.hasPrefix("Thanksgiving Break") })
        #expect(thanksgiving.cancelsClasses)

        let followDays = events.filter { $0.followsWeekday != nil }
        #expect(followDays.count == 2)
        #expect(followDays.allSatisfy { $0.followsWeekday == 2 })
    }

    // MARK: - GPA

    @Test func passNoPassGradesStayOutOfGPA() {
        #expect(GPACalculator.weightedGPA([(.a, 4), (.pass, 4), (.noPass, 4)]) == 4.0)
        #expect(GPACalculator.weightedGPA([(.b, 4), (.pass, 1)]) == 3.0)
        #expect(GPACalculator.weightedGPA([(.pass, 4)]) == nil)
    }

    @Test func onlyExplicitCreditOverridesChangeGPAWeight() {
        let enrollmentID = "TEST-\(UUID().uuidString)"
        defer { GradeBreakdownStore.clear(enrollmentID: enrollmentID) }

        // Older builds saved 4.0 just by opening the breakdown sheet.
        GradeBreakdownStore.save(GradeBreakdown(creditsOverride: 4), enrollmentID: enrollmentID)
        #expect(GPACalculator.effectiveCredits(enrollmentID: enrollmentID, catalogCredits: 1) == 1)

        GradeBreakdownStore.save(
            GradeBreakdown(creditsOverride: 3, creditsOverrideIsExplicit: true),
            enrollmentID: enrollmentID
        )
        #expect(GPACalculator.effectiveCredits(enrollmentID: enrollmentID, catalogCredits: 1) == 3)
    }

    @Test func runningGradeIgnoresUngradedCategories() {
        var homework = GradeCategory(name: "Homework", weightPercent: 30)
        homework.scorePercent = 90
        let breakdown = GradeBreakdown(categories: [
            homework,
            GradeCategory(name: "Midterm", weightPercent: 25),
            GradeCategory(name: "Final", weightPercent: 45),
        ])

        #expect(breakdown.currentGradePercent == 90)
        #expect(breakdown.resolvedLetterGrade() == .aMinus)
        #expect(GradeBreakdown(categories: [GradeCategory(name: "Final", weightPercent: 100)]).resolvedLetterGrade() == nil)
    }

    // MARK: - Repeating events

    @Test func monthlyEventsUseTheLastDayOfShortMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9)))
        let end = try #require(calendar.date(from: DateComponents(year: 2027, month: 5, day: 31)))

        let days = EventRecurrence.monthlyDates(from: start, through: end, calendar: calendar)
            .map { calendar.dateComponents([.month, .day], from: $0) }
            .map { "\($0.month ?? 0)/\($0.day ?? 0)" }
        #expect(days == ["1/31", "2/28", "3/31", "4/30", "5/31"])
    }

    @Test func weeklyEventsRepeatOnChosenDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // Monday, September 28, 2026 through Sunday, October 11.
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11)))

        let dates = EventRecurrence.weeklyDates(from: start, through: end, on: [2, 5], calendar: calendar)
        #expect(dates.count == 4)
        #expect(dates.allSatisfy { [2, 5].contains(calendar.component(.weekday, from: $0)) })

        let weekdays = EventRecurrence.dailyDates(from: start, through: end, weekdaysOnly: true, calendar: calendar)
        #expect(weekdays.count == 10)
    }

    // MARK: - Friends map layout

    @Test func overlappingFriendsSpreadOutAtCampusZoom() throws {
        let dcc = try #require(directory.building(id: "dcc")).center
        let folsom = try #require(directory.building(id: "folsom")).center
        let pins = [pin("maya", at: dcc), pin("ava", at: dcc), pin("jordan", at: folsom)]

        // Whole-campus zoom is about 4 m per point.
        #expect(abs(FriendMapLayout.metersPerPoint(in: CampusDirectory.campusRegion, width: 346) - 3.9) < 0.1)
        let items = FriendMapLayout.items(for: pins, metersPerPoint: 4, selectedFriendID: nil)

        // DCC and Folsom are neighbors, so at this zoom all three pins would
        // touch; they spread into one ring instead.
        let spread = items.compactMap { item -> CLLocationCoordinate2D? in
            if case .friend(let pin, false) = item { return pin.coordinate }
            return nil
        }
        #expect(items.count == 3)
        #expect(spread.count == 3)
        for i in spread.indices {
            for j in spread.indices where j > i {
                #expect(FriendMapLayout.meters(from: spread[i], to: spread[j]) / 4 >= FriendMapLayout.spreadSpacing - 0.5)
            }
        }

        // Zoomed in, the buildings are far enough apart to keep their labels.
        let zoomed = FriendMapLayout.items(for: pins, metersPerPoint: 0.5, selectedFriendID: nil)
        #expect(zoomed.contains { labeledPinID($0) == "jordan" })
    }

    @Test func crowdsCollapseIntoOneBubbleExceptTheSelectedFriend() throws {
        let dcc = try #require(directory.building(id: "dcc")).center
        let pins = (0..<8).map { pin("crowd\($0)", at: dcc) }

        let items = FriendMapLayout.items(for: pins, metersPerPoint: 1, selectedFriendID: "crowd3")

        #expect(items.count == 2)
        guard case .group(let group) = items.first else {
            Issue.record("Expected the crowd to be grouped")
            return
        }
        #expect(group.members.count == 7)
        #expect(!group.members.contains { $0.id == "crowd3" })
        #expect(group.title == "Crowd0, Crowd1 +5")
        #expect(group.radius < 1)
        #expect(items.contains { labeledPinID($0) == "crowd3" })
    }

    @Test func compactTimesStayShort() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RelativeTimeText.compact(now.addingTimeInterval(-30), now: now) == "now")
        #expect(RelativeTimeText.compact(now.addingTimeInterval(-4 * 60), now: now) == "4m")
        #expect(RelativeTimeText.compact(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(RelativeTimeText.compact(now.addingTimeInterval(-50 * 3600), now: now) == "2d")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12)))
        #expect(ChatTimeText.short(noon.addingTimeInterval(-24 * 3600), now: noon, calendar: calendar) == "Yesterday")
    }

    @Test func walkingDistancesReadLikeMaps() {
        let us = Locale(identifier: "en_US")
        #expect(DistanceText.format(meters: 60, locale: us) == "200 ft")
        #expect(DistanceText.format(meters: 402, locale: us) == "0.2 mi")
        #expect(DistanceText.format(meters: 148, locale: Locale(identifier: "en_CA")) == "150 m")
        #expect(DistanceText.format(meters: 1_500, locale: Locale(identifier: "de_DE")) == "1,5 km")

        let dcc = CLLocation(latitude: 42.729311, longitude: -73.679292)
        #expect(DistanceText.between(dcc, CLLocationCoordinate2D(latitude: 42.72932, longitude: -73.67930)) == "Nearby")
        // Someone across the country isn't a walking distance.
        #expect(DistanceText.between(dcc, CLLocationCoordinate2D(latitude: 37.33, longitude: -122.01)) == nil)
    }

    // MARK: - Syllabus import

    @Test func syllabusDatesAreFoundAndClassified() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let term = DateInterval(
            start: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))),
            end: try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 23)))
        )
        let text = """
        CSCI 1200 — Data Structures — Fall 2026
        Course Schedule (revised Aug 15, 2025)
        Week 2   Fri Sep 11   HW 1 due at 11:59pm
        Week 4   Fri Sep 25   Lab quiz 1
        Week 6   Tue Oct 6    Test 1, 6:00pm in DCC 308
        Week 9   Oct 27       Project proposal due
                 Dec 16       Final exam, 3:00pm
        Week 1   Tue Sep 1    Introduction, C++ review
        """
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let found = SyllabusDateExtractor.candidates(in: text, term: term, calendar: calendar, now: now)

        // The revision date is outside the term, so it's skipped.
        #expect(!found.contains { calendar.component(.year, from: $0.date) == 2025 })
        #expect(found.first { $0.title == "HW 1" }?.kind == .assignment)
        #expect(found.first { $0.title == "Quiz 1" }?.kind == .quiz)
        #expect(found.first { $0.title == "Test 1" }?.kind == .exam)
        #expect(found.first { $0.title == "Project proposal" }?.kind == .project)
        #expect(found.first { $0.title == "Final exam" }?.kind == .exam)
        // A lecture topic has a date but isn't pre-selected.
        let intro = try #require(found.first { $0.title.contains("Introduction") })
        #expect(!intro.isImportant && !intro.isSelected)
        let test = try #require(found.first { $0.title == "Test 1" })
        #expect(calendar.component(.month, from: test.date) == 10 && calendar.component(.day, from: test.date) == 6)
        #expect(calendar.component(.hour, from: test.date) == 18)
        // "Week 9  Oct 27": the week number isn't the day.
        let proposal = try #require(found.first { $0.title == "Project proposal" })
        #expect(calendar.component(.day, from: proposal.date) == 27)
    }

    /// A weekly schedule table: the date column is the Monday of each week,
    /// and the column says the day (Principles of Software, Fall 2026).
    @Test func weeklyScheduleTablesUseTheDayColumn() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let term = DateInterval(
            start: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))),
            end: try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 13)))
        )
        func line(_ text: String, _ x: CGFloat, _ top: CGFloat, page: Int = 0) -> SyllabusLine {
            SyllabusLine(text: text, page: page, minX: x, maxX: x + CGFloat(text.count) * 5, top: top, height: 10)
        }
        let lines: [SyllabusLine] = [
            line("Weekly Lecture Schedule:", 27, 370),
            line("WEEK", 33, 395), line("Week of", 81, 395), line("Tue", 196, 395), line("Wed", 303, 395),
            line("Fri", 392, 395), line("Homework", 458, 395),
            line("(Mon)", 86, 408),
            line("5", 40, 567), line("09/21/26", 73, 567), line("Lec 8: Specifications", 136, 567),
            line("Q4", 284, 567), line("Lec 9:", 357, 567), line("HW2", 460, 567),
            line("6", 40, 622), line("09/28/26", 73, 622), line("Lec 10: Abstract Data", 136, 622),
            line("EXAM", 284, 622), line("REVIEW", 284, 635), line("Lec 11:", 357, 622),
            line("7", 40, 677), line("10/05/26", 73, 677), line("TEST1 (during test block)", 136, 677),
            line("Lec 12: Abstraction", 357, 677), line("HW3", 460, 677),
            line("No Lecture", 136, 690),
            line("Please Note: This schedule is tentative! If you regularly attend class, you'll know where we are!", 34, 744),
            line("Tests will be given during the testing period on Tuesday's from 6PM – 7:50PM.", 27, 300, page: 3),
        ]
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let found = SyllabusDateExtractor.candidates(in: lines, term: term, classTimes: [4: DateComponents(hour: 10, minute: 0)], calendar: calendar, now: now)
        func day(_ title: String) -> (weekday: Int, month: Int, day: Int, hour: Int)? {
            found.first { $0.title == title }.map {
                (calendar.component(.weekday, from: $0.date), calendar.component(.month, from: $0.date),
                 calendar.component(.day, from: $0.date), calendar.component(.hour, from: $0.date))
            }
        }

        // The test is on Tuesday of the week of Oct 5, in the 6 PM test block.
        let test = try #require(day("Test 1"))
        #expect(test.weekday == 3 && test.month == 10 && test.day == 6 && test.hour == 18)
        // Quizzes sit in the Wednesday column, at the Wednesday class time.
        let quiz = try #require(day("Quiz 4"))
        #expect(quiz.weekday == 4 && quiz.month == 9 && quiz.day == 23 && quiz.hour == 10)
        // "EXAM" and "REVIEW" on two lines is a review lecture, not an exam.
        #expect(!found.contains { $0.kind == .exam && $0.title != "Test 1" })
        // Homework has no day, so it lands on Friday with a note to check.
        let hw = try #require(found.first { $0.title == "HW 3" })
        #expect(calendar.component(.weekday, from: hw.date) == 6 && hw.note != nil)
        // Table cells aren't read again as plain dated lines.
        #expect(!found.contains { $0.title.contains("Lec") })
    }

    @Test func syllabusLinesHandleWeeksRangesAndAbbreviations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let term = DateInterval(
            start: try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))),
            end: try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 13)))
        )
        let text = """
        Assignment 1 Mon. Sept. 7 Due at 11:59pm
        Week 5 (Sep 28 - Oct 2): Exam 1 on Thursday
        Tue 9/29   Lecture 9: Midterm review
        Mon 9/14   Recursion   Lab 3 due Wednesday
        Mon 9/28 Lec 10    Wed 9/30 Quiz 4
        """
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let found = SyllabusDateExtractor.candidates(in: text, term: term, calendar: calendar, now: now)
        func dayOf(_ title: String) -> Int? {
            found.first { $0.title == title }.map { calendar.component(.day, from: $0.date) }
        }

        #expect(dayOf("Assignment 1") == 7)
        #expect(found.first { $0.title == "Assignment 1" }.map { calendar.component(.hour, from: $0.date) } == 23)
        // "Week of Sep 28 … on Thursday" is Oct 1.
        #expect(dayOf("Exam 1") == 1)
        #expect(!found.contains { $0.kind == .exam && $0.sourceLine.contains("review") })
        #expect(dayOf("Lab 3") == 16)
        // Each date on a row owns the text after it.
        #expect(dayOf("Quiz 4") == 30)
        #expect(found.filter { $0.title == "Quiz 4" }.count == 1)
    }

    @Test func scheduleCellsNameTheRightWork() {
        #expect(SyllabusDateExtractor.events(in: "TEST1 (during test block) No Lecture").map(\.title) == ["Test 1"])
        #expect(SyllabusDateExtractor.events(in: "TEST1 (during test block)").first?.mentionsTestBlock == true)
        #expect(SyllabusDateExtractor.events(in: "EXAM REVIEW").isEmpty)
        #expect(SyllabusDateExtractor.events(in: "Midterm exam").map(\.title) == ["Midterm"])
        #expect(SyllabusDateExtractor.events(in: "Q4 Lec 9").map(\.title) == ["Quiz 4"])
        #expect(SyllabusDateExtractor.events(in: "Final Exam Week").first?.isFinalsWeek == true)
        #expect(SyllabusDateExtractor.weekday(named: "(Mon)") == 2)
        #expect(SyllabusDateExtractor.weekday(named: "Monitor") == nil)
        let block = SyllabusDateExtractor.testBlock(in: "Exam Locations: TBD\nOffice Hours: Tuesday 12:15PM – 1:45PM\nTests will be given during the testing period on Tuesday’s from 6PM – 7:50PM.")
        #expect(block == SyllabusDateExtractor.TestBlock(weekday: 3, hour: 18, minute: 0))
    }

    @Test func meetingTimesReadNaturally() {
        let evening = Meeting(days: [.tue], start: "18:00", end: "19:50", location: "")
        #expect(evening.dayTimeSummary.hasSuffix("6:00 – 7:50 PM"))
        let spansNoon = Meeting(days: [.mon, .thu], start: "11:00", end: "12:50", location: "")
        #expect(spansNoon.dayTimeSummary.hasSuffix("11:00 AM – 12:50 PM"))
    }

    @Test func examBlockTasksHaveStableIDs() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let a = CalendarViewModel.examBlockTaskID(key: "k|3|18:00-19:50", day: day)
        #expect(a == CalendarViewModel.examBlockTaskID(key: "k|3|18:00-19:50", day: day))
        #expect(a != CalendarViewModel.examBlockTaskID(key: "k|3|18:00-19:50", day: day.addingTimeInterval(86_400)))
    }

    @Test func instructorListsSplitIntoRateMyProfessorsNames() {
        #expect(RateMyProfessors.instructors(from: "Barbara Cutler, Shianne M. Hulbert") == ["Barbara Cutler", "Shianne M. Hulbert"])
        #expect(RateMyProfessors.searchName(for: "Shianne M. Hulbert") == "Shianne Hulbert")
        #expect(RateMyProfessors.instructors(from: "TBA").isEmpty)
        #expect(RateMyProfessors.isProfessorPage(URL(string: "https://www.ratemyprofessors.com/professor/123456")))
        #expect(!RateMyProfessors.isProfessorPage(URL(string: "https://www.ratemyprofessors.com/search/professors/795?q=x")))
    }

    @Test func overlappingEventsGetSeparateLanes() {
        func event(_ title: String, _ startHour: Double, _ endHour: Double) -> ClassEvent {
            let base = Date(timeIntervalSince1970: 1_790_000_000)
            return ClassEvent(
                title: title, location: "",
                startDate: base.addingTimeInterval(startHour * 3600), endDate: base.addingTimeInterval(endHour * 3600),
                backgroundColor: .blue, accentColor: .blue, enrollmentID: nil, semesterCode: nil,
                seriesID: nil, isAllDay: false, kind: .personal, badge: nil, meetingKey: nil
            )
        }
        let a = event("A", 0, 2), b = event("B", 1, 3), c = event("C", 2, 4)
        let lanes = OverlapLayout.lanes(for: [a, b, c])
        #expect(lanes[a.interactionKey] == 0)
        #expect(lanes[b.interactionKey] == 1)
        // C starts when A ends, so it reuses A's lane.
        #expect(lanes[c.interactionKey] == 0)
    }

    @Test func courseRatingsAverageValidRatingsOnly() throws {
        let summary = try #require(CourseRatingSummary.summarize([
            CourseRating(overall: 5, difficulty: 4, hoursPerWeek: 8, tags: [.toughExams, .curve], semesterCode: "202609"),
            CourseRating(overall: 3, difficulty: 2, hoursPerWeek: 4, tags: [.toughExams], semesterCode: "202609"),
            CourseRating(overall: 9, difficulty: 2, hoursPerWeek: 4, tags: [], semesterCode: "202609"),
        ]))
        #expect(summary.count == 2)
        #expect(summary.overall == 4)
        #expect(summary.hoursPerWeek == 6)
        #expect(summary.topTags.first?.tag == .toughExams)
    }

    @Test func notificationTextReadsNaturally() {
        #expect(NotificationManager.durationText(minutes: 10) == "10 minutes")
        #expect(NotificationManager.durationText(minutes: 60) == "1 hour")
        #expect(NotificationManager.durationText(minutes: 1440) == "1 day")
        #expect(NotificationManager.durationText(minutes: 10_080) == "1 week")
        #expect(NotificationManager.courseCode(fromEnrollmentID: "CSCI-1200-77023") == "CSCI 1200")
    }

    // MARK: - Helpers

    private func pin(_ id: String, at coordinate: CLLocationCoordinate2D) -> FriendMapPinModel {
        let presence = FriendPresence(
            friend: friend(id: id, displayName: id.capitalized + " Tester"),
            coordinate: coordinate,
            building: nil,
            headline: "On campus",
            detail: nil,
            updatedAt: nil,
            freshness: .live,
            currentActivity: nil
        )
        return FriendMapPinModel(presence: presence, coordinate: coordinate)
    }

    /// The friend ID for a pin that shows its name label.
    private func labeledPinID(_ item: FriendMapLayout.Item) -> String? {
        if case .friend(let pin, true) = item { return pin.id }
        return nil
    }

    private func friend(id: String = "friend", displayName: String = "Alex Kim") -> SocialFriend {
        SocialFriend(
            id: id,
            username: "alex",
            displayName: displayName,
            email: "",
            isGuest: false,
            shareSchedule: true,
            shareLocation: true,
            createdAt: "",
            lastScheduleAt: nil,
            canViewSchedule: true,
            schedulePreviewCount: 1,
            sharedCourseKeys: [],
            sharedSectionKeys: []
        )
    }

    private func schedule(classAt location: String, around now: Date) -> SharedScheduleSnapshot {
        SharedScheduleSnapshot(
            semesterCode: "202609",
            generatedAt: nil,
            items: [
                SharedScheduleItem(
                    id: "class",
                    title: "Data Structures",
                    location: location,
                    startDate: SharedScheduleDates.string(from: now.addingTimeInterval(-20 * 60)),
                    endDate: SharedScheduleDates.string(from: now.addingTimeInterval(30 * 60)),
                    isAllDay: false,
                    kind: CalendarEventKind.classMeeting.rawValue,
                    badge: nil
                ),
            ]
        )
    }

    private func item(start: String, end: String) -> SharedScheduleItem {
        SharedScheduleItem(
            id: start,
            title: "Class",
            location: "",
            startDate: start,
            endDate: end,
            isAllDay: false,
            kind: CalendarEventKind.classMeeting.rawValue,
            badge: nil
        )
    }
}
