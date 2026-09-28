// AcademicEvent.swift

import Foundation

struct AcademicEvent: Identifiable, Codable {
    let id: UUID
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?

    /// Category for color-coding / behavior (all-day academic events, etc.)
    let kind: CalendarEventKind

    /// Regular classes do not meet on these days (holidays, breaks).
    let cancelsClasses: Bool

    /// Calendar weekday (1 = Sunday … 7 = Saturday) whose class schedule runs
    /// instead, for "Follow a Monday Class Schedule today" days.
    let followsWeekday: Int?

    init(
        id: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        kind: CalendarEventKind = .academicOther,
        cancelsClasses: Bool = false,
        followsWeekday: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.kind = kind
        self.cancelsClasses = cancelsClasses
        self.followsWeekday = followsWeekday
    }

    // We only encode/decode semantic fields; `id` is regenerated on decode.
    enum CodingKeys: String, CodingKey {
        case title
        case startDate
        case endDate
        case location
        case kind
        case cancelsClasses
        case followsWeekday
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let startDate = try container.decode(Date.self, forKey: .startDate)
        let endDate = try container.decode(Date.self, forKey: .endDate)
        let location = try container.decodeIfPresent(String.self, forKey: .location)
        let kind = (try? container.decode(CalendarEventKind.self, forKey: .kind)) ?? .academicOther

        self.init(
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            kind: kind,
            cancelsClasses: (try? container.decode(Bool.self, forKey: .cancelsClasses)) ?? false,
            followsWeekday: try? container.decode(Int.self, forKey: .followsWeekday)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(location, forKey: .location)
        try container.encode(kind, forKey: .kind)
        try container.encode(cancelsClasses, forKey: .cancelsClasses)
        try container.encodeIfPresent(followsWeekday, forKey: .followsWeekday)
    }

    /// Weekday named in "Follow a Monday Class Schedule today".
    static func followedWeekday(inTitle title: String) -> Int? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let lowered = title.lowercased()
        guard let range = lowered.range(of: "follow a ") else { return nil }
        let remainder = lowered[range.upperBound...]
        guard let index = names.firstIndex(where: { remainder.hasPrefix($0) }) else { return nil }
        return index + 1
    }
}
