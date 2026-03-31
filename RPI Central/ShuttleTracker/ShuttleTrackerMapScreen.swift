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
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(quickRouteButtons) { route in
                            Button {
                                focus(on: route)
                            } label: {
                                MapQuickChipLabel(
                                    title: shortRouteLabel(for: route.id),
                                    isSelected: selectedRouteIDStorage == route.id,
                                    accentColor: color(for: route.colorHex)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if let favoriteStopSelection {
                            Button {
                                selectedRouteIDStorage = favoriteStopSelection.route.id
                                focus(on: favoriteStopSelection.stop)
                            } label: {
                                MapQuickChipLabel(
                                    title: favoriteChipTitle(for: favoriteStopSelection),
                                    isSelected: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 8)

                    Button {
                        showStopLabels.toggle()
                    } label: {
                        MapQuickChipLabel(
                            title: "Names",
                            systemName: showStopLabels ? "mappin.slash" : "mappin",
                            isSelected: showStopLabels
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)

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
        .task(id: viewModel.routes.map { $0.id }.joined(separator: "|")) {
            applyInitialFocusIfNeeded()
        }
        .sheet(isPresented: $showingRouteTimes) {
            ShuttleRouteTimesSheet(
                routes: viewModel.routes.filter { !$0.isHidden },
                initiallySelectedRouteID: resolvedSelectedRouteID,
                favoriteStopFavoriteID: favoriteStopIDStorage,
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

    private var quickRouteButtons: [ShuttleRouteOverlay] {
        let visibleRoutes = viewModel.routes.filter { !$0.isHidden }
        let primaryRoutes = visibleRoutes.filter { route in
            let identifier = route.id.uppercased()
            return identifier == "NORTH" || identifier == "WEST"
        }

        return primaryRoutes.sorted { lhs, rhs in
            routePriority(for: lhs.id) < routePriority(for: rhs.id)
        }
    }

    private var favoriteStopSelection: (route: ShuttleRouteOverlay, stop: ShuttleStop)? {
        guard let favorite = ShuttlePreferencesStore.splitFavoriteStopID(favoriteStopIDStorage) else {
            return nil
        }
        guard let route = viewModel.routes.first(where: { $0.id == favorite.routeID }),
              let stop = route.stops.first(where: { $0.id == favorite.stopID }) else {
            return nil
        }
        return (route, stop)
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

    private func focus(on route: ShuttleRouteOverlay) {
        selectedRouteIDStorage = route.id
        let coordinates = route.polylineCoordinates + route.stops.map { $0.coordinate }

        guard !coordinates.isEmpty else { return }

        setCameraRegion(
            from: coordinates,
            minimumLatitudeSpan: 0.0085,
            minimumLongitudeSpan: 0.0105,
            paddingMultiplier: 0.22
        )
    }

    private func recenterMap() {
        selectedRouteIDStorage = ""
        let visibleRoutes = viewModel.routes.filter { !$0.isHidden }
        let routeCoordinates = visibleRoutes.flatMap { $0.polylineCoordinates }
        let vehicleCoordinates = viewModel.vehicles.map { $0.coordinate }
        let coordinates = routeCoordinates + vehicleCoordinates

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

    private func routePriority(for routeID: String) -> Int {
        switch routeID.uppercased() {
        case "NORTH":
            return 0
        case "WEST":
            return 1
        default:
            return 2
        }
    }

    private func shortRouteLabel(for routeID: String) -> String {
        switch routeID.uppercased() {
        case "NORTH":
            return "N"
        case "WEST":
            return "W"
        default:
            return String(routeID.prefix(2)).uppercased()
        }
    }

    private func favoriteChipTitle(for selection: (route: ShuttleRouteOverlay, stop: ShuttleStop)) -> String {
        let name = shortStopLabel(selection.stop.name)
        guard let nextTime = nextExpectedTime(for: selection) else {
            return name
        }
        return "\(name) \(nextTime.formatted(date: .omitted, time: .shortened))"
    }

    private func shortStopLabel(_ stopName: String) -> String {
        let baseName = stopName.split(separator: "(").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? stopName

        if baseName.count <= 14 {
            return baseName
        }

        let words = baseName.split(separator: " ")
        if let lastWord = words.last, lastWord.count <= 14 {
            return String(lastWord)
        }

        return String(baseName.prefix(14)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextExpectedTime(for selection: (route: ShuttleRouteOverlay, stop: ShuttleStop)) -> Date? {
        let now = Date()
        let departures = ShuttleStaticScheduleProvider.shared.upcomingDepartures(
            for: selection.route,
            now: now,
            limit: 12
        )

        let normalizedFavoriteName = normalizedStopName(selection.stop.name)

        for departure in departures {
            if let nextStopTime = departure.stopTimes.first(where: { stopTime in
                guard let scheduledTime = stopTime.scheduledTime else { return false }
                return scheduledTime >= now && normalizedStopName(stopTime.stopName) == normalizedFavoriteName
            })?.scheduledTime {
                return nextStopTime
            }
        }

        return nil
    }

    private func normalizedStopName(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: "(return)", with: "")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct MapQuickChipLabel: View {
    let title: String
    var systemName: String? = nil
    var isSelected: Bool
    var accentColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isSelected
                ? AnyShapeStyle(accentColor ?? .accentColor)
                : AnyShapeStyle(.regularMaterial),
            in: Capsule()
        )
        .overlay {
            if !isSelected {
                Capsule()
                    .strokeBorder(.white.opacity(0.12))
            }
        }
    }
}

private struct ShuttleRouteTimesSheet: View {
    let routes: [ShuttleRouteOverlay]
    let initiallySelectedRouteID: String
    let favoriteStopFavoriteID: String
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
