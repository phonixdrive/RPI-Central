import Foundation

struct ShuttleTrackerConfig {
    let baseURL: URL
    let routesFallbackFileName: String?
}

final class ShuttleTrackerService {
    private let config: ShuttleTrackerConfig
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(config: ShuttleTrackerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchVehicles() async throws -> [ShuttleVehicle] {
        async let locationsTask = fetch([String: ShuttleLocationPayload].self, path: "api/locations")
        async let velocitiesTask = try? fetch([String: ShuttleVelocityPayload].self, path: "api/velocities")

        let locationMap = try await locationsTask
        let velocityMap = await velocitiesTask ?? [:]

        return locationMap
            .map { vehicleID, location in
                let velocity = velocityMap[vehicleID]

                return ShuttleVehicle(
                    id: vehicleID,
                    name: location.name,
                    coordinate: .init(latitude: location.latitude, longitude: location.longitude),
                    headingDegrees: location.headingDegrees,
                    speedMPH: location.speedMPH,
                    timestamp: ShuttleTimestampParser.parse(location.timestamp),
                    routeName: velocity?.routeName,
                    polylineIndex: velocity?.polylineIndex,
                    driverName: location.driver?.name,
                    currentStop: velocity?.currentStop
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func fetchRoutes() async throws -> [ShuttleRouteOverlay] {
        do {
            let routeMap = try await fetch([String: ShuttleRoutePayload].self, path: "api/routes")
            return routeMap
                .map { routeName, route in
                    route.makeOverlay(routeName: routeName)
                }
                .sorted { $0.id < $1.id }
        } catch {
            guard
                let fileName = config.routesFallbackFileName,
                let url = Bundle.main.url(forResource: fileName, withExtension: "json")
            else {
                throw error
            }

            let data = try Data(contentsOf: url)
            let routeMap = try decoder.decode([String: ShuttleRoutePayload].self, from: data)
            return routeMap
                .map { routeName, route in
                    route.makeOverlay(routeName: routeName)
                }
                .sorted { $0.id < $1.id }
        }
    }

    func fetchETAs() async throws -> [String: ShuttleVehicleETA] {
        let etaMap = try await fetch([String: ShuttleETAPayload].self, path: "api/etas")

        return Dictionary(uniqueKeysWithValues: etaMap.map { vehicleID, payload in
            let stopTimes = payload.stopTimes.compactMapValues { ShuttleTimestampParser.parse($0) }
            return (
                vehicleID,
                ShuttleVehicleETA(
                    id: vehicleID,
                    timestamp: ShuttleTimestampParser.parse(payload.timestamp),
                    stopTimes: stopTimes
                )
            )
        })
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let request = URLRequest(url: makeURL(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ShuttleTrackerServiceError.badResponse
        }

        return try decoder.decode(type, from: data)
    }

    private func makeURL(path: String) -> URL {
        path
            .split(separator: "/")
            .reduce(config.baseURL) { partial, piece in
                partial.appendingPathComponent(String(piece))
            }
    }
}

enum ShuttleTrackerServiceError: Error, LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The shuttle server returned an invalid response."
        }
    }
}
