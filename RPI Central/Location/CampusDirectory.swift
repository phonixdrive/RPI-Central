//
//  CampusDirectory.swift
//  RPI Central
//
//  Campus building footprints (from OpenStreetMap, see
//  Tools/campus_buildings/build_campus_buildings.py) used to turn a location
//  into "In DCC" and a schedule room into a map position.
//

import CoreLocation
import Foundation
import MapKit

struct CampusBuilding: Identifiable, Hashable {
    enum Category: String, Decodable {
        case academic
        case library
        case arts
        case studentLife
        case dining
        case admin
        case athletics
        case residence

        var systemImage: String {
            switch self {
            case .academic: return "building.columns.fill"
            case .library: return "books.vertical.fill"
            case .arts: return "theatermasks.fill"
            case .studentLife: return "person.3.fill"
            case .dining: return "fork.knife"
            case .admin: return "building.2.fill"
            case .athletics: return "figure.run"
            case .residence: return "bed.double.fill"
            }
        }
    }

    let id: String
    let name: String
    let shortName: String
    let category: Category
    let aliases: [String]
    let center: CLLocationCoordinate2D
    let polygons: [[CLLocationCoordinate2D]]

    static func == (lhs: CampusBuilding, rhs: CampusBuilding) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension CampusBuilding: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, shortName, category, aliases, center, polygons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shortName = try container.decode(String.self, forKey: .shortName)
        category = (try? container.decode(Category.self, forKey: .category)) ?? .academic
        aliases = (try? container.decode([String].self, forKey: .aliases)) ?? []

        let rawCenter = try container.decode([Double].self, forKey: .center)
        guard rawCenter.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .center, in: container, debugDescription: "Expected [lat, lon]")
        }
        center = CLLocationCoordinate2D(latitude: rawCenter[0], longitude: rawCenter[1])

        let rawPolygons = try container.decode([[[Double]]].self, forKey: .polygons)
        polygons = rawPolygons.map { ring in
            ring.compactMap { pair in
                pair.count == 2 ? CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]) : nil
            }
        }
    }
}

/// Where a coordinate is, in campus terms.
struct CampusPlace: Equatable {
    enum Kind: String {
        case inside
        case near
        case onCampus
        case offCampus
    }

    let kind: Kind
    let building: CampusBuilding?

    var isOnCampus: Bool { kind != .offCampus }

    /// "In DCC", "Near Folsom Library", "On campus", "Off campus".
    var label: String {
        switch kind {
        case .inside:
            return "In \(building?.shortName ?? "a campus building")"
        case .near:
            return "Near \(building?.shortName ?? "campus")"
        case .onCampus:
            return "On campus"
        case .offCampus:
            return "Off campus"
        }
    }
}

struct CampusDirectory {
    static let shared = CampusDirectory.loadBundled()

    /// Region framing the core of campus for the friends map.
    static let campusRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.7297, longitude: -73.6780),
        span: MKCoordinateSpan(latitudeDelta: 0.0125, longitudeDelta: 0.0165)
    )

    let buildings: [CampusBuilding]
    let attribution: String
    private let boundsSouth: Double
    private let boundsWest: Double
    private let boundsNorth: Double
    private let boundsEast: Double
    private let buildingsByID: [String: CampusBuilding]
    /// Aliases sorted longest first so "Russell Sage Laboratory" wins over "Sage".
    private let aliasIndex: [(alias: String, building: CampusBuilding)]

    init(
        buildings: [CampusBuilding],
        attribution: String = "",
        bounds: (south: Double, west: Double, north: Double, east: Double) = (42.7200, -73.6950, 42.7400, -73.6580)
    ) {
        self.buildings = buildings
        self.attribution = attribution
        boundsSouth = bounds.south
        boundsWest = bounds.west
        boundsNorth = bounds.north
        boundsEast = bounds.east
        buildingsByID = Dictionary(buildings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var index: [(String, CampusBuilding)] = []
        for building in buildings {
            for alias in Set(building.aliases + [building.name, building.shortName]) {
                let normalized = Self.normalized(alias)
                // Very short aliases ("AE", "WL") are only matched as a whole word.
                if !normalized.isEmpty {
                    index.append((normalized, building))
                }
            }
        }
        aliasIndex = index.sorted { $0.0.count > $1.0.count }
    }

    static func loadBundled(bundle: Bundle = .main) -> CampusDirectory {
        struct Payload: Decodable {
            struct Bounds: Decodable {
                let south: Double
                let west: Double
                let north: Double
                let east: Double
            }

            let attribution: String?
            let campusBounds: Bounds?
            let buildings: [CampusBuilding]
        }

        guard let url = bundle.url(forResource: "CampusBuildings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            #if DEBUG
            print("⚠️ CampusBuildings.json is missing from the bundle")
            #endif
            return CampusDirectory(buildings: [])
        }

        let bounds = payload.campusBounds.map { ($0.south, $0.west, $0.north, $0.east) }
            ?? (42.7200, -73.6950, 42.7400, -73.6580)
        return CampusDirectory(
            buildings: payload.buildings,
            attribution: payload.attribution ?? "© OpenStreetMap contributors",
            bounds: bounds
        )
    }

    func building(id: String?) -> CampusBuilding? {
        guard let id, !id.isEmpty else { return nil }
        return buildingsByID[id]
    }

    func isOnCampus(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= boundsSouth && coordinate.latitude <= boundsNorth &&
            coordinate.longitude >= boundsWest && coordinate.longitude <= boundsEast
    }

    func building(containing coordinate: CLLocationCoordinate2D) -> CampusBuilding? {
        buildings.first { building in
            building.polygons.contains { Self.polygon($0, contains: coordinate) }
        }
    }

    /// Closest building outline to a point, in meters (0 when inside).
    func nearestBuilding(
        to coordinate: CLLocationCoordinate2D,
        within maximumMeters: Double
    ) -> (building: CampusBuilding, meters: Double)? {
        var best: (CampusBuilding, Double)?
        for building in buildings {
            // Cheap reject using the center before measuring edges.
            let centerMeters = Self.meters(from: coordinate, to: building.center)
            guard centerMeters < maximumMeters + 250 else { continue }

            let meters = building.polygons
                .map { Self.distance(from: coordinate, toOutline: $0) }
                .min() ?? centerMeters
            if meters <= maximumMeters, meters < (best?.1 ?? .infinity) {
                best = (building, meters)
            }
        }
        return best
    }

    /// Resolves a fix into campus terms. A fix is only called "in" a building
    /// when it is accurate enough to trust; otherwise it is "near" it.
    func place(for coordinate: CLLocationCoordinate2D, horizontalAccuracy: Double) -> CampusPlace {
        let accuracy = max(0, horizontalAccuracy)
        if let inside = building(containing: coordinate) {
            return CampusPlace(kind: accuracy <= 45 ? .inside : .near, building: inside)
        }
        if let nearby = nearestBuilding(to: coordinate, within: max(30, min(accuracy, 90))) {
            return CampusPlace(kind: .near, building: nearby.building)
        }
        return CampusPlace(kind: isOnCampus(coordinate) ? .onCampus : .offCampus, building: nil)
    }

    /// Matches a SIS room such as "Darrin Communications Center 308" to its
    /// building and room ("308"). Returns nil for TBA, online, or unknown rooms.
    func match(scheduleLocation: String) -> (building: CampusBuilding, room: String?)? {
        let normalizedLocation = Self.normalized(scheduleLocation)
        guard !normalizedLocation.isEmpty else { return nil }

        for (alias, building) in aliasIndex {
            if normalizedLocation == alias {
                return (building, nil)
            }
            guard normalizedLocation.hasPrefix(alias + " ") else { continue }
            let room = normalizedLocation.dropFirst(alias.count).trimmingCharacters(in: .whitespaces)
            return (building, room.isEmpty ? nil : room.uppercased())
        }
        return nil
    }

    /// "DCC 308" for "Darrin Communications Center 308".
    func shortRoomLabel(for scheduleLocation: String) -> String? {
        guard let match = match(scheduleLocation: scheduleLocation) else { return nil }
        guard let room = match.room else { return match.building.shortName }
        return "\(match.building.shortName) \(room)"
    }

    // MARK: - Geometry (planar approximation; campus is ~2 km across)

    static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let (x, y) = localMeters(b, origin: a)
        return (x * x + y * y).squareRoot()
    }

    private static func localMeters(
        _ point: CLLocationCoordinate2D,
        origin: CLLocationCoordinate2D
    ) -> (Double, Double) {
        let x = (point.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180)
        let y = (point.latitude - origin.latitude) * 110_574
        return (x, y)
    }

    private static func polygon(_ ring: [CLLocationCoordinate2D], contains point: CLLocationCoordinate2D) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            let crosses = (pi.latitude > point.latitude) != (pj.latitude > point.latitude)
            if crosses {
                let longitudeAtLatitude = (pj.longitude - pi.longitude) * (point.latitude - pi.latitude)
                    / (pj.latitude - pi.latitude) + pi.longitude
                if point.longitude < longitudeAtLatitude {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    private static func distance(
        from point: CLLocationCoordinate2D,
        toOutline ring: [CLLocationCoordinate2D]
    ) -> Double {
        if polygon(ring, contains: point) { return 0 }
        guard ring.count >= 2 else { return .infinity }

        var best = Double.infinity
        for index in 0..<ring.count {
            let (ax, ay) = localMeters(ring[index], origin: point)
            let (bx, by) = localMeters(ring[(index + 1) % ring.count], origin: point)
            let dx = bx - ax
            let dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
            let px = ax + t * dx
            let py = ay + t * dy
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
