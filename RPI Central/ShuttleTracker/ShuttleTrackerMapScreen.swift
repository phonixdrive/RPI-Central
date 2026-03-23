import SwiftUI
import MapKit

struct ShuttleTrackerMapScreen: View {
    @AppStorage("shuttle_tracker_show_stop_labels") private var showStopLabels = true
    @StateObject private var viewModel: ShuttleTrackerViewModel
    @State private var position = MapCameraPosition.region(Self.defaultRegion)
    @State private var showingRouteTimes = false

    private static let defaultCenter = CLLocationCoordinate2D(latitude: 42.730216, longitude: -73.675690)
    private static let defaultRegion = MKCoordinateRegion(
        center: defaultCenter,
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.025)
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
        .sheet(isPresented: $showingRouteTimes) {
            ShuttleRouteTimesSheet(routes: viewModel.routes.filter { !$0.isHidden })
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

    private func recenterMap() {
        let visibleRoutes = viewModel.routes.filter { !$0.isHidden }
        let coordinates = visibleRoutes.flatMap(\.polylineCoordinates) + viewModel.vehicles.map(\.coordinate)

        guard !coordinates.isEmpty else {
            withAnimation {
                position = .region(Self.defaultRegion)
            }
            return
        }

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

        let latitudePadding = max(0.004, (maxLatitude - minLatitude) * 0.35)
        let longitudePadding = max(0.004, (maxLongitude - minLongitude) * 0.35)

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.01, (maxLatitude - minLatitude) + latitudePadding),
                longitudeDelta: max(0.01, (maxLongitude - minLongitude) + longitudePadding)
            )
        )

        withAnimation {
            position = .region(region)
        }
    }
}

