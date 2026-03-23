import Foundation
import CoreLocation

struct ShuttleVehicle: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let headingDegrees: Double?
    let speedMPH: Double?
    let timestamp: Date?
    let routeName: String?
    let polylineIndex: Int?
    let driverName: String?
    let currentStop: String?
}

struct ShuttleRouteOverlay: Identifiable {
    let id: String
    let colorHex: String
    let stops: [ShuttleStop]
    let polylineCoordinates: [CLLocationCoordinate2D]
}

struct ShuttleStop: Identifiable {
    let id: String
    let name: String
    let offsetMinutes: Int
    let coordinate: CLLocationCoordinate2D
}

struct ShuttleLocationPayload: Decodable {
    struct DriverPayload: Decodable {
        let id: String
        let name: String
    }

    let name: String
    let latitude: Double
    let longitude: Double
    let timestamp: String
    let headingDegrees: Double?
    let speedMPH: Double?
    let driver: DriverPayload?

    enum CodingKeys: String, CodingKey {
        case name
        case latitude
        case longitude
        case timestamp
        case headingDegrees = "heading_degrees"
        case speedMPH = "speed_mph"
        case driver
    }
}

struct ShuttleVelocityPayload: Decodable {
    let speedKMH: Double?
    let timestamp: String?
    let routeName: String?
    let polylineIndex: Int?
    let isAtStop: Bool?
    let currentStop: String?

    enum CodingKeys: String, CodingKey {
        case speedKMH = "speed_kmh"
        case timestamp
        case routeName = "route_name"
        case polylineIndex = "polyline_index"
        case isAtStop = "is_at_stop"
        case currentStop = "current_stop"
    }
}

struct ShuttleStopPayload: Decodable {
    let coordinates: [Double]
    let offset: Int
    let name: String

    enum CodingKeys: String, CodingKey {
        case coordinates = "COORDINATES"
        case offset = "OFFSET"
        case name = "NAME"
    }
}

struct ShuttleRoutePayload: Decodable {
    let colorHex: String
    let stopOrder: [String]
    let polylineStopOrder: [String]
    let routeSegments: [[[Double]]]
    let stopDetails: [String: ShuttleStopPayload]

    enum ReservedKeys: String, CaseIterable {
        case color = "COLOR"
        case stops = "STOPS"
        case polylineStops = "POLYLINE_STOPS"
        case routes = "ROUTES"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        colorHex = try container.decode(String.self, forKey: .required("COLOR"))
        stopOrder = try container.decode([String].self, forKey: .required("STOPS"))
        polylineStopOrder = try container.decode([String].self, forKey: .required("POLYLINE_STOPS"))
        routeSegments = try container.decode([[[Double]]].self, forKey: .required("ROUTES"))

        let reserved = Set(ReservedKeys.allCases.map(\.rawValue))
        var details: [String: ShuttleStopPayload] = [:]

        for key in container.allKeys where !reserved.contains(key.stringValue) {
            if let stop = try? container.decode(ShuttleStopPayload.self, forKey: key) {
                details[key.stringValue] = stop
            }
        }

        stopDetails = details
    }

    func makeOverlay(routeName: String) -> ShuttleRouteOverlay {
        let stops = stopOrder.compactMap { stopKey -> ShuttleStop? in
            guard let stop = stopDetails[stopKey], stop.coordinates.count == 2 else {
                return nil
            }

            return ShuttleStop(
                id: stopKey,
                name: stop.name,
                offsetMinutes: stop.offset,
                coordinate: CLLocationCoordinate2D(
                    latitude: stop.coordinates[0],
                    longitude: stop.coordinates[1]
                )
            )
        }

        let coordinates = routeSegments.flatMap { segment in
            segment.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else {
                    return nil
                }

                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
        }

        return ShuttleRouteOverlay(
            id: routeName,
            colorHex: colorHex,
            stops: stops,
            polylineCoordinates: coordinates
        )
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    static func required(_ string: String) -> DynamicCodingKey {
        guard let key = DynamicCodingKey(stringValue: string) else {
            preconditionFailure("Invalid coding key: \(string)")
        }
        return key
    }
}

enum ShuttleTimestampParser {
    private static let internetDateTime = ISO8601DateFormatter()
    private static let internetDateTimeFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        if let date = internetDateTimeFractional.date(from: value) {
            return date
        }

        return internetDateTime.date(from: value)
    }
}
