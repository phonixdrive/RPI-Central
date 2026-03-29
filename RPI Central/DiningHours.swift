import SwiftUI

struct DiningHoursPeriod: Identifiable, Hashable {
    let id: String
    let label: String?
    let startMinutes: Int
    let endMinutes: Int

    init(label: String? = nil, startMinutes: Int, endMinutes: Int) {
        self.label = label
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.id = "\(label ?? "hours")-\(startMinutes)-\(endMinutes)"
    }

    func contains(_ minutes: Int) -> Bool {
        startMinutes <= minutes && minutes < endMinutes
    }

    var timeRangeText: String {
        "\(DiningHoursFormat.timeString(from: startMinutes)) - \(DiningHoursFormat.timeString(from: endMinutes))"
    }

    var fullText: String {
        if let label, !label.isEmpty {
            return "\(label): \(timeRangeText)"
        }
        return timeRangeText
    }
}

struct DiningScheduleGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let weekdays: [Int]
    let periods: [DiningHoursPeriod]

    init(title: String, weekdays: [Int], periods: [DiningHoursPeriod]) {
        self.title = title
        self.weekdays = weekdays
        self.periods = periods
        self.id = title
    }
}

struct DiningVenue: Identifiable, Hashable {
    let id: String
    let name: String
    let scheduleGroups: [DiningScheduleGroup]

    init(name: String, scheduleGroups: [DiningScheduleGroup]) {
        self.name = name
        self.scheduleGroups = scheduleGroups
        self.id = name
    }

    func periods(for weekday: Int) -> [DiningHoursPeriod] {
        scheduleGroups
            .filter { $0.weekdays.contains(weekday) }
            .flatMap(\.periods)
            .sorted { $0.startMinutes < $1.startMinutes }
    }

    func status(at date: Date, calendar: Calendar = .current) -> DiningVenueStatus {
        let weekday = calendar.component(.weekday, from: date)
        let currentMinutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let todaysPeriods = periods(for: weekday)

        if let currentPeriod = todaysPeriods.first(where: { $0.contains(currentMinutes) }) {
            let detail = currentPeriod.label.map { "\($0) until \(DiningHoursFormat.timeString(from: currentPeriod.endMinutes))" }
                ?? "Open until \(DiningHoursFormat.timeString(from: currentPeriod.endMinutes))"
            return DiningVenueStatus(isOpen: true, badgeText: "Open", detailText: detail, todayPeriods: todaysPeriods)
        }

        if let nextTodayPeriod = todaysPeriods.first(where: { $0.startMinutes > currentMinutes }) {
            let detail = nextTodayPeriod.label.map { "\($0) starts at \(DiningHoursFormat.timeString(from: nextTodayPeriod.startMinutes))" }
                ?? "Opens at \(DiningHoursFormat.timeString(from: nextTodayPeriod.startMinutes))"
            return DiningVenueStatus(isOpen: false, badgeText: "Closed", detailText: detail, todayPeriods: todaysPeriods)
        }

        if let nextPeriod = nextUpcomingPeriod(after: date, calendar: calendar) {
            let isTomorrow = calendar.isDate(
                nextPeriod.date,
                inSameDayAs: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? nextPeriod.date
            )
            let weekdayText = isTomorrow ? "tomorrow" : DiningHoursFormat.shortWeekdayName(for: nextPeriod.date)
            let detail = nextPeriod.period.label.map {
                "Opens \(weekdayText) for \($0) at \(DiningHoursFormat.timeString(from: nextPeriod.period.startMinutes))"
            } ?? "Opens \(weekdayText) at \(DiningHoursFormat.timeString(from: nextPeriod.period.startMinutes))"
            return DiningVenueStatus(isOpen: false, badgeText: "Closed", detailText: detail, todayPeriods: todaysPeriods)
        }

        return DiningVenueStatus(
            isOpen: false,
            badgeText: "Closed",
            detailText: todaysPeriods.isEmpty ? "Closed today" : "No more hours today",
            todayPeriods: todaysPeriods
        )
    }

    private func nextUpcomingPeriod(after date: Date, calendar: Calendar) -> (date: Date, period: DiningHoursPeriod)? {
        let startOfToday = calendar.startOfDay(for: date)

        for dayOffset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: day)

            for period in periods(for: weekday) {
                guard let startDate = calendar.date(byAdding: .minute, value: period.startMinutes, to: day) else { continue }
                if startDate > date {
                    return (startDate, period)
                }
            }
        }

        return nil
    }
}

struct DiningVenueStatus {
    let isOpen: Bool
    let badgeText: String
    let detailText: String
    let todayPeriods: [DiningHoursPeriod]
}

enum DiningHoursData {
    static let venues: [DiningVenue] = [
        DiningVenue(
            name: "Jimmy John's",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [period(startHour: 11, endHour: 23)]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [period(startHour: 11, endHour: 17)]),
            ]
        ),
        DiningVenue(
            name: "BARH Dining Hall",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(label: "Breakfast", startHour: 7, endHour: 9, endMinute: 30),
                    period(label: "Dinner", startHour: 17, endHour: 21),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(label: "Brunch", startHour: 11, endHour: 13),
                ]),
            ]
        ),
        DiningVenue(
            name: "The Beanery Cafe",
            scheduleGroups: [
                group("Monday - Tuesday, Thursday - Friday", weekdays: [2, 3, 5, 6], periods: [
                    period(startHour: 7, startMinute: 30, endHour: 15),
                ]),
            ]
        ),
        DiningVenue(
            name: "Library Cafe",
            scheduleGroups: [
                group("Monday - Thursday", weekdays: [2, 3, 4, 5], periods: [
                    period(startHour: 9, endHour: 18),
                ]),
                group("Friday", weekdays: [6], periods: [
                    period(startHour: 9, endHour: 16),
                ]),
            ]
        ),
        DiningVenue(
            name: "Panera Bread",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(startHour: 8, endHour: 20),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(startHour: 10, endHour: 20),
                ]),
            ]
        ),
        DiningVenue(
            name: "Bird 'n' Brine",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(startHour: 11, endHour: 23),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(startHour: 16, endHour: 23),
                ]),
            ]
        ),
        DiningVenue(
            name: "Father's powered by Foodhive",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(startHour: 8, endHour: 23),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(startHour: 9, startMinute: 30, endHour: 23),
                ]),
            ]
        ),
        DiningVenue(
            name: "Blitman Dining Hall",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(label: "Breakfast", startHour: 7, endHour: 9, endMinute: 30),
                    period(label: "Dinner", startHour: 17, endHour: 20),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(label: "Brunch", startHour: 10, startMinute: 30, endHour: 13),
                    period(label: "Dinner", startHour: 17, endHour: 20),
                ]),
            ]
        ),
        DiningVenue(
            name: "Evelyn's Cafe",
            scheduleGroups: [
                group("Wednesday", weekdays: [4], periods: [
                    period(startHour: 11, endHour: 14),
                ]),
            ]
        ),
        DiningVenue(
            name: "Russell Sage Dining Hall",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(label: "Breakfast", startHour: 7, endHour: 10),
                    period(label: "Continental Breakfast", startHour: 10, endHour: 11),
                    period(label: "Lunch", startHour: 11, endHour: 14, endMinute: 30),
                    period(label: "Late Lunch", startHour: 14, startMinute: 30, endHour: 16),
                ]),
                group("Monday - Sunday", weekdays: [1, 2, 3, 4, 5, 6, 7], periods: [
                    period(label: "Dinner", startHour: 16, endHour: 20),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(label: "Late Lunch", startHour: 13, startMinute: 30, endHour: 16),
                ]),
            ]
        ),
        DiningVenue(
            name: "Wild Blue Sushi",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(startHour: 11, endHour: 23),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(startHour: 13, endHour: 22),
                ]),
            ]
        ),
        DiningVenue(
            name: "Simply to Go",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(label: "Breakfast", startHour: 7, startMinute: 15, endHour: 11),
                    period(label: "Lunch", startHour: 11, endHour: 16),
                ]),
            ]
        ),
        DiningVenue(
            name: "DCC Cafe",
            scheduleGroups: [
                group("Monday - Thursday", weekdays: [2, 3, 4, 5], periods: [
                    period(startHour: 7, startMinute: 30, endHour: 18),
                ]),
                group("Friday", weekdays: [6], periods: [
                    period(startHour: 7, startMinute: 30, endHour: 16),
                ]),
            ]
        ),
        DiningVenue(
            name: "Halal Shack",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(startHour: 11, endHour: 23),
                ]),
                group("Saturday - Sunday", weekdays: [7, 1], periods: [
                    period(startHour: 13, endHour: 22),
                ]),
            ]
        ),
        DiningVenue(
            name: "The Commons Dining Hall",
            scheduleGroups: [
                group("Monday - Friday", weekdays: [2, 3, 4, 5, 6], periods: [
                    period(label: "Breakfast", startHour: 7, endHour: 10),
                    period(label: "Continental Breakfast", startHour: 10, endHour: 11),
                    period(label: "Lunch", startHour: 11, endHour: 15, endMinute: 30),
                    period(label: "Late Lunch", startHour: 15, startMinute: 30, endHour: 16, endMinute: 30),
                    period(label: "Dinner", startHour: 16, startMinute: 30, endHour: 21),
                ]),
                group("Monday - Thursday", weekdays: [2, 3, 4, 5], periods: [
                    period(label: "Late Night", startHour: 21, endHour: 22),
                ]),
                group("Saturday", weekdays: [7], periods: [
                    period(label: "Brunch", startHour: 8, startMinute: 30, endHour: 14),
                    period(label: "Late Lunch", startHour: 14, endHour: 16, endMinute: 30),
                    period(label: "Dinner", startHour: 16, startMinute: 30, endHour: 21),
                ]),
                group("Sunday", weekdays: [1], periods: [
                    period(label: "Brunch", startHour: 9, endHour: 14),
                    period(label: "Late Lunch", startHour: 14, endHour: 16, endMinute: 30),
                    period(label: "Dinner", startHour: 16, startMinute: 30, endHour: 21),
                    period(label: "Late Night", startHour: 21, endHour: 22),
                ]),
            ]
        ),
    ]

    private static func group(_ title: String, weekdays: [Int], periods: [DiningHoursPeriod]) -> DiningScheduleGroup {
        DiningScheduleGroup(title: title, weekdays: weekdays, periods: periods)
    }

    private static func period(
        label: String? = nil,
        startHour: Int,
        startMinute: Int = 0,
        endHour: Int,
        endMinute: Int = 0
    ) -> DiningHoursPeriod {
        DiningHoursPeriod(
            label: label,
            startMinutes: startHour * 60 + startMinute,
            endMinutes: endHour * 60 + endMinute
        )
    }
}

