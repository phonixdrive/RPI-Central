import Foundation

struct ShuttleScheduledStopTime: Identifiable {
    let id: String
    let stopName: String
    let scheduledTime: Date?
}

struct ShuttleScheduledDeparture: Identifiable {
    let id: String
    let routeID: String
    let startTime: Date
    let stopTimes: [ShuttleScheduledStopTime]
    let isCurrent: Bool
}

final class ShuttleStaticScheduleProvider {
    static let shared = ShuttleStaticScheduleProvider()

    private struct ScheduledSeed {
        let timeString: String
        let routeID: String
    }

    private let groupedSchedule: [String: [ScheduledSeed]]
    private let calendar = Calendar.current

    private init() {
        self.groupedSchedule = Self.loadSchedule()
    }

    func upcomingDepartures(
        for route: ShuttleRouteOverlay,
        now: Date = Date(),
        limit: Int = 3
    ) -> [ShuttleScheduledDeparture] {
        let alias = scheduleAlias(for: now)
        let seeds = groupedSchedule[alias, default: []]
            .filter { $0.routeID == route.id.uppercased() }

        let departures = seeds.compactMap { seed -> ShuttleScheduledDeparture? in
            guard let startTime = scheduledDate(from: seed.timeString, relativeTo: now) else {
                return nil
            }

            let stopTimes = route.stops.map { stop in
                let stopDate = calendar.date(byAdding: .minute, value: stop.offsetMinutes, to: startTime)
                return ShuttleScheduledStopTime(
                    id: "\(seed.timeString)-\(stop.id)",
                    stopName: stop.name,
                    scheduledTime: stopDate
                )
            }

            guard
                let lastStopDate = stopTimes.compactMap(\.scheduledTime).last
            else {
                return nil
            }

            let isCurrent = startTime <= now && lastStopDate >= now
            let filteredStops = isCurrent
                ? stopTimes.filter { ($0.scheduledTime ?? .distantPast) >= now.addingTimeInterval(-90) }
                : stopTimes

            guard !filteredStops.isEmpty else {
                return nil
            }

            return ShuttleScheduledDeparture(
                id: "\(route.id)-\(seed.timeString)",
                routeID: route.id,
                startTime: startTime,
                stopTimes: filteredStops,
                isCurrent: isCurrent
            )
        }
        .filter { departure in
            guard let lastStop = departure.stopTimes.compactMap(\.scheduledTime).last else {
                return false
            }
            return lastStop >= now.addingTimeInterval(-90)
        }
        .sorted { $0.startTime < $1.startTime }

        return Array(departures.prefix(limit))
    }

    private func scheduleAlias(for date: Date) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1:
            return "sunday"
        case 7:
            return "saturday"
        default:
            return "weekday"
        }
    }

    private func scheduledDate(from timeString: String, relativeTo date: Date) -> Date? {
        let trimmed = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard parts.count == 2 else { return nil }

        let timeParts = parts[0].split(separator: ":")
        guard timeParts.count == 2,
              var hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]) else {
            return nil
        }

        let modifier = parts[1].uppercased()
        if modifier == "PM" && hour != 12 {
            hour += 12
        } else if modifier == "AM" && hour == 12 {
            hour = 0
        }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var scheduled = calendar.date(from: components) else { return nil }

        // Treat midnight schedule entries as the end of the service day.
        if hour == 0 {
            scheduled = calendar.date(byAdding: .day, value: 1, to: scheduled) ?? scheduled
        }

        return scheduled
    }

    private static func loadSchedule() -> [String: [ScheduledSeed]] {
        guard
            let url = Bundle.main.url(forResource: "ShuttleSchedule", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        let aliases = ["weekday", "saturday", "sunday"]
        var result: [String: [ScheduledSeed]] = [:]

        for alias in aliases {
            guard let routeGroups = json[alias] as? [String: Any] else { continue }

            let seeds: [ScheduledSeed] = routeGroups.values.flatMap { rawEntries in
                guard let entries = rawEntries as? [[Any]] else { return [ScheduledSeed]() }
                return entries.compactMap { entry in
                    guard
                        entry.count >= 2,
                        let time = entry[0] as? String,
                        let routeID = entry[1] as? String
                    else {
                        return nil
                    }
                    return ScheduledSeed(timeString: time, routeID: routeID.uppercased())
                }
            }

            result[alias] = seeds
        }

        return result
    }
}
