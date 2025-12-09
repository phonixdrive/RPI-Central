// AcademicEvent.swift

import Foundation

struct AcademicEvent: Identifiable, Codable {
    let id: UUID
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?

    init(
        id: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
    }

    // We only encode/decode semantic fields; `id` is regenerated on decode.
    enum CodingKeys: String, CodingKey {
        case title
        case startDate
        case endDate
        case location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let startDate = try container.decode(Date.self, forKey: .startDate)
        let endDate = try container.decode(Date.self, forKey: .endDate)
        let location = try container.decodeIfPresent(String.self, forKey: .location)

        self.init(
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(location, forKey: .location)
    }
}
