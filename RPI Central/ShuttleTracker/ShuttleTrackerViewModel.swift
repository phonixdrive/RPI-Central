import Foundation

@MainActor
final class ShuttleTrackerViewModel: ObservableObject {
    @Published private(set) var vehicles: [ShuttleVehicle] = []
    @Published private(set) var routes: [ShuttleRouteOverlay] = []
    @Published private(set) var etasByVehicleID: [String: ShuttleVehicleETA] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private let service: ShuttleTrackerService
    private let pollIntervalNanoseconds: UInt64
    private var pollingTask: Task<Void, Never>?
    private var hasLoadedRoutes = false

    init(
        service: ShuttleTrackerService,
        pollIntervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.service = service
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }

            await loadRoutesIfNeeded()

            while !Task.isCancelled {
                await refreshVehicles()
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refreshVehicles()
        }
    }

    private func loadRoutesIfNeeded() async {
        guard !hasLoadedRoutes else { return }

        do {
            let routes = try await service.fetchRoutes()
            self.routes = routes
            hasLoadedRoutes = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshVehicles() async {
        isLoading = vehicles.isEmpty

        do {
            async let vehiclesTask = service.fetchVehicles()
            async let etasTask = try? service.fetchETAs()

            let vehicles = try await vehiclesTask
            self.vehicles = vehicles
            if let etas = await etasTask {
                self.etasByVehicleID = etas
            }
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
