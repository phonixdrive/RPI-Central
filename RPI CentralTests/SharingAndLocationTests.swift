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

        let spread = items.compactMap { item -> CLLocationCoordinate2D? in
            if case .friend(let pin, false) = item, pin.id != "jordan" { return pin.coordinate }
            return nil
        }
        #expect(items.count == 3)
        #expect(spread.count == 2)
        #expect(FriendMapLayout.meters(from: spread[0], to: spread[1]) / 4 >= FriendMapLayout.spreadSpacing - 0.5)
        #expect(items.contains { labeledPinID($0) == "jordan" })
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
