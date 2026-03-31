import Foundation

struct LMSImportedCalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

enum LMSCalendarFeedService {
    private struct ICSProperty {
        let name: String
        let value: String
        let parameters: [String: String]
    }

    private struct RawEvent {
        var properties: [ICSProperty] = []

        func property(named name: String) -> ICSProperty? {
            properties.first { $0.name == name }
        }
    }

    static func fetchEvents(from url: URL) async throws -> [LMSImportedCalendarEvent] {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeRawData)
        }

        let rawEvents = parseRawEvents(from: text)
        var imported: [LMSImportedCalendarEvent] = []

        for rawEvent in rawEvents {
            guard let importedEvent = makeImportedEvent(from: rawEvent) else { continue }
            imported.append(importedEvent)
        }

        return imported.sorted { $0.startDate < $1.startDate }
    }

    private static func parseRawEvents(from text: String) -> [RawEvent] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let unfoldedLines = unfoldICSLines(normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))

        var events: [RawEvent] = []
        var currentEvent: RawEvent? = nil

        for line in unfoldedLines {
            if line == "BEGIN:VEVENT" {
                currentEvent = RawEvent()
                continue
            }

            if line == "END:VEVENT" {
                if let currentEvent {
                    events.append(currentEvent)
                }
                currentEvent = nil
                continue
            }

            guard currentEvent != nil,
                  let property = parseProperty(from: line) else {
                continue
            }

            currentEvent?.properties.append(property)
        }

        return events
    }

    private static func unfoldICSLines(_ lines: [String]) -> [String] {
        var unfolded: [String] = []

        for line in lines {
            if let firstCharacter = line.first, (firstCharacter == " " || firstCharacter == "\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += String(line.dropFirst())
            } else {
                unfolded.append(line)
            }
        }

        return unfolded
    }

    private static func parseProperty(from line: String) -> ICSProperty? {
        guard let delimiterIndex = line.firstIndex(of: ":") else { return nil }

        let header = String(line[..<delimiterIndex])
        let value = String(line[line.index(after: delimiterIndex)...])
        let headerParts = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)

        guard let rawName = headerParts.first, !rawName.isEmpty else { return nil }

        var parameters: [String: String] = [:]
        for part in headerParts.dropFirst() {
            let components = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            parameters[components[0].uppercased()] = components[1]
        }

        return ICSProperty(
            name: rawName.uppercased(),
            value: unescapedICSValue(value),
            parameters: parameters
        )
    }

    private static func makeImportedEvent(from rawEvent: RawEvent) -> LMSImportedCalendarEvent? {
        guard let startProperty = rawEvent.property(named: "DTSTART"),
              let endProperty = rawEvent.property(named: "DTEND") ?? rawEvent.property(named: "DUE"),
              let summary = rawEvent.property(named: "SUMMARY")?.value.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              let startDate = parseDate(from: startProperty),
              let endDate = parseDate(from: endProperty) else {
            return nil
        }

        let uid = rawEvent.property(named: "UID")?.value.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "\(summary)|\(startDate.timeIntervalSince1970)"
        let location = rawEvent.property(named: "LOCATION")?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAllDay = isAllDayProperty(startProperty)

        let adjustedEndDate: Date
        if endDate < startDate {
            adjustedEndDate = startDate.addingTimeInterval(isAllDay ? 86400 : 3600)
        } else {
            adjustedEndDate = endDate
        }

        return LMSImportedCalendarEvent(
            id: uid,
            title: summary,
            location: location,
            startDate: startDate,
            endDate: adjustedEndDate,
            isAllDay: isAllDay
        )
    }

    private static func isAllDayProperty(_ property: ICSProperty) -> Bool {
        if property.parameters["VALUE"]?.uppercased() == "DATE" {
            return true
        }
        return property.value.count == 8
    }

    private static func parseDate(from property: ICSProperty) -> Date? {
        let value = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAllDayProperty(property) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
            return formatter.date(from: value)
        }

        if value.hasSuffix("Z") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let tzid = property.parameters["TZID"], let timezone = TimeZone(identifier: tzid) {
            formatter.timeZone = timezone
        } else {
            formatter.timeZone = .current
        }
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: value)
    }

    private static func unescapedICSValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
