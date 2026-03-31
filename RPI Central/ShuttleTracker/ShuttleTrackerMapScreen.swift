import SwiftUI
import MapKit

struct ShuttleTrackerMapScreen: View {
    @AppStorage("shuttle_tracker_show_stop_labels") private var showStopLabels = true
    @AppStorage(ShuttlePreferencesStore.selectedRouteStorageKey) private var selectedRouteIDStorage = ""
    @AppStorage(ShuttlePreferencesStore.favoriteStopStorageKey) private var favoriteStopIDStorage = ""

    @StateObject private var viewModel: ShuttleTrackerViewModel
    @State private var position = MapCameraPosition.region(Self.defaultRegion)
    @State private var showingRouteTimes = false
    @State private var didApplyInitialFocus = false

    private static let defaultCenter = CLLocationCoordinate2D(latitude: 42.730216, longitude: -73.675690)
    private static let defaultRegion = MKCoordinateRegion(
        center: defaultCenter,
        span: MKCoordinateSpan(latitudeDelta: 0.0235, longitudeDelta: 0.029)
    )

    init(baseURL: URL, refreshIntervalSeconds: Int = 5) {
        let config = ShuttleTrackerConfig(
            baseURL: baseURL,
            routesFallbackFileName: "ShuttleRoutes"
        )
        let service = ShuttleTrackerService(config: config)
        let clampedSeconds = max(1, refreshIntervalSeconds)
        let intervalNanoseconds = UInt64(clampedSeconds) * 1_000_000_000
        _viewModel = StateObject(
            wrappedValue: ShuttleTrackerViewModel(
                service: service,
                pollIntervalNanoseconds: intervalNanoseconds
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(viewModel.routes.filter { !$0.isHidden }) { route in
                    if route.polylineCoordinates.count > 1 {
                        MapPolyline(coordinates: route.polylineCoordinates)
                            .stroke(color(for: route.colorHex), lineWidth: 5)
                    }

                    ForEach(route.stops) { stop in
                        Annotation("", coordinate: stop.coordinate) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        Circle()
                                            .stroke(color(for: route.colorHex), lineWidth: 3)
                                    }

                                if showStopLabels {
                                    Text(stop.name)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                }

                ForEach(viewModel.vehicles) { vehicle in
                    Annotation("", coordinate: vehicle.coordinate) {
                        ShuttleVehicleMarker(
                            title: showStopLabels ? vehicle.name : nil,
                            routeColor: color(forRouteNamed: vehicle.routeName)
                        )
                        .rotationEffect(.degrees(vehicle.headingDegrees ?? 0))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea()

            if let errorMessage = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showStopLabels.toggle()
                    } label: {
                        Label(showStopLabels ? "Hide Stops" : "Show Stops",
                              systemImage: showStopLabels ? "mappin.slash" : "mappin")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }

                Spacer()

                HStack {
                    Button {
                        showingRouteTimes = true
                    } label: {
                        MapControlButtonLabel(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, 26)

                    Spacer()

                    Button {
                        recenterMap()
                    } label: {
                        MapControlButtonLabel(systemName: "scope")
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 26)
                }
            }

            if viewModel.isLoading {
                ProgressView("Loading shuttle data...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .navigationTitle("Shuttle Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") {
                    viewModel.refreshNow()
                }
            }
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .task(id: viewModel.routes.map(\.id).joined(separator: "|")) {
            applyInitialFocusIfNeeded()
        }
        .sheet(isPresented: $showingRouteTimes) {
            ShuttleRouteTimesSheet(
                routes: viewModel.routes.filter { !$0.isHidden },
                initiallySelectedRouteID: resolvedSelectedRouteID,
                favoriteStopFavoriteID: favoriteStopIDStorage,
                onSelectedRouteChange: { selectedRouteIDStorage = $0 },
                onFavoriteStopChange: { favoriteStopIDStorage = $0 },
                onSelectStop: { stop in
                    focus(on: stop)
                }
            )
            .presentationDetents([.fraction(0.45)])
            .presentationDragIndicator(.visible)
        }
    }

    private func color(forRouteNamed routeName: String?) -> Color {
        guard
            let routeName,
            let route = viewModel.routes.first(where: { $0.id == routeName })
        else {
            return .gray
        }

        return color(for: route.colorHex)
    }

    private func color(for hex: String) -> Color {
        Color(hex: hex) ?? .red
    }

    private var favoriteStop: ShuttleStop? {
        guard let favorite = ShuttlePreferencesStore.splitFavoriteStopID(favoriteStopIDStorage) else {
            return nil
        }
        return viewModel.routes
            .first(where: { $0.id == favorite.routeID })?
            .stops.first(where: { $0.id == favorite.stopID })
    }

    private var resolvedSelectedRouteID: String {
        let visibleRoutes = viewModel.routes.filter { !$0.isHidden }
        if visibleRoutes.contains(where: { $0.id == selectedRouteIDStorage }) {
            return selectedRouteIDStorage
        }
        return visibleRoutes.first?.id ?? ""
    }

    private func applyInitialFocusIfNeeded() {
        guard !didApplyInitialFocus, !viewModel.routes.filter({ !$0.isHidden }).isEmpty else { return }
        didApplyInitialFocus = true

        if let stop = favoriteStop {
            focus(on: stop)
            return
        }

        recenterMap()
    }

    private func focus(on stop: ShuttleStop) {
        let region = MKCoordinateRegion(
            center: stop.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0085, longitudeDelta: 0.011)
        )
        withAnimation {
            position = .region(region)
        }
    }

    private func recenterMap() {
        let visibleRoutes = viewModel.routes.filter { !$0.isHidden }
        let coordinates = visibleRoutes.flatMap(\.polylineCoordinates) + viewModel.vehicles.map(\.coordinate)

        guard !coordinates.isEmpty else {
            withAnimation {
                position = .region(Self.defaultRegion)
            }
            return
        }

        setCameraRegion(
            from: coordinates,
            minimumLatitudeSpan: 0.012,
            minimumLongitudeSpan: 0.014,
            paddingMultiplier: 0.40
        )
    }

    private func setCameraRegion(
        from coordinates: [CLLocationCoordinate2D],
        minimumLatitudeSpan: Double,
        minimumLongitudeSpan: Double,
        paddingMultiplier: Double
    ) {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)

        guard
            let minLatitude = latitudes.min(),
            let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(),
            let maxLongitude = longitudes.max()
        else {
            return
        }

        let latitudePadding = max(0.004, (maxLatitude - minLatitude) * paddingMultiplier)
        let longitudePadding = max(0.004, (maxLongitude - minLongitude) * paddingMultiplier)

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(minimumLatitudeSpan, (maxLatitude - minLatitude) + latitudePadding),
                longitudeDelta: max(minimumLongitudeSpan, (maxLongitude - minLongitude) + longitudePadding)
            )
        )

        withAnimation {
            position = .region(region)
        }
    }
}

private struct ShuttleVehicleMarker: View {
    let title: String?
    let routeColor: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "bus.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(routeColor, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.85), lineWidth: 1.5)
                }
                .shadow(radius: 4)

            if let title {
                Text(title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }
}

private struct MapControlButtonLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .padding(14)
            .background(.regularMaterial, in: Circle())
    }
}

private struct ShuttleRouteTimesSheet: View {
    let routes: [ShuttleRouteOverlay]
    let initiallySelectedRouteID: String
    let favoriteStopFavoriteID: String
    let onSelectedRouteChange: (String) -> Void
    let onFavoriteStopChange: (String) -> Void
    let onSelectStop: (ShuttleStop) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRouteID: String = ""

    private var routeOptions: [ShuttleRouteOverlay] {
        routes.filter { !$0.isHidden }
    }

    private var selectedRoute: ShuttleRouteOverlay? {
        routeOptions.first(where: { $0.id == selectedRouteID }) ?? routeOptions.first
    }

    private var upcomingDepartures: [ShuttleScheduledDeparture] {
        guard let selectedRoute else { return [] }
        return ShuttleStaticScheduleProvider.shared.upcomingDepartures(for: selectedRoute, now: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                if routeOptions.isEmpty {
                    ContentUnavailableView(
                        "No Route Data",
                        systemImage: "bus",
                        description: Text("Live shuttle route timing is not available right now.")
                    )
                } else {
                    Section {
                        Picker("Route", selection: $selectedRouteID) {
                            ForEach(routeOptions) { route in
                                Text(route.id.capitalized).tag(route.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if selectedRoute != nil {
                        if upcomingDepartures.isEmpty {
                            Section {
                                Text("No recent or upcoming departures were found for this route.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(upcomingDepartures) { departure in
                            Section {
                                ForEach(departure.stopTimes) { stop in
                                    stopRow(stop)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(departure.startTime.formatted(date: .omitted, time: .shortened))
                                    Text(departure.isCurrent ? "Current loop" : "Upcoming departure")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Route Times")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedRouteID) { _, newValue in
                onSelectedRouteChange(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if selectedRouteID.isEmpty {
                    if routeOptions.contains(where: { $0.id == initiallySelectedRouteID }) {
                        selectedRouteID = initiallySelectedRouteID
                    } else {
                        selectedRouteID = routeOptions.first?.id ?? ""
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: ShuttleScheduledStopTime) -> some View {
        if let selectedRoute,
           let actualStop = selectedRoute.stops.first(where: { $0.name == stop.stopName }) {
            let favoriteID = ShuttlePreferencesStore.stopFavoriteID(routeID: selectedRoute.id, stopID: actualStop.id)
            HStack {
                Text(stop.stopName)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    if favoriteStopFavoriteID == favoriteID {
                        onFavoriteStopChange("")
                    } else {
                        onFavoriteStopChange(favoriteID)
                    }
                } label: {
                    Image(systemName: favoriteStopFavoriteID == favoriteID ? "star.fill" : "star")
                        .foregroundStyle(favoriteStopFavoriteID == favoriteID ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                Text(formattedTime(stop.scheduledTime))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectStop(actualStop)
                dismiss()
            }
        } else {
            HStack {
                Text(stop.stopName)
                Spacer()
                Text(formattedTime(stop.scheduledTime))
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private enum ShuttlePreferencesStore {
    static let selectedRouteStorageKey = "shuttle.selectedRouteID.v1"
    static let favoriteStopStorageKey = "shuttle.favoriteStopID.v1"

    static func stopFavoriteID(routeID: String, stopID: String) -> String {
        "\(routeID)|\(stopID)"
    }

    static func splitFavoriteStopID(_ value: String) -> (routeID: String, stopID: String)? {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if cleaned.count == 8, let value = UInt32(cleaned, radix: 16) {
            let alpha = Double((value >> 24) & 0xFF) / 255.0
            guard alpha > 0 else { return nil }

            let red = Double((value >> 16) & 0xFF) / 255.0
            let green = Double((value >> 8) & 0xFF) / 255.0
            let blue = Double(value & 0xFF) / 255.0

            self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
            return
        }

        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}
