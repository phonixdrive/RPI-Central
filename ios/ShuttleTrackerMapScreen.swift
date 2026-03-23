import SwiftUI
import MapKit

struct ShuttleTrackerMapScreen: View {
    @StateObject private var viewModel: ShuttleTrackerViewModel
    @State private var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 42.730216, longitude: -73.675690),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.025)
        )
    )

    init(baseURL: URL) {
        let config = ShuttleTrackerConfig(
            baseURL: baseURL,
            routesFallbackFileName: "ShuttleRoutes"
        )
        let service = ShuttleTrackerService(config: config)
        _viewModel = StateObject(
            wrappedValue: ShuttleTrackerViewModel(service: service)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(viewModel.routes) { route in
                    if route.polylineCoordinates.count > 1 {
                        MapPolyline(coordinates: route.polylineCoordinates)
                            .stroke(color(for: route.colorHex), lineWidth: 5)
                    }

                    ForEach(route.stops) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        Circle()
                                            .stroke(color(for: route.colorHex), lineWidth: 3)
                                    }

                                Text(stop.name)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                    }
                }

                ForEach(viewModel.vehicles) { vehicle in
                    Annotation(vehicle.name, coordinate: vehicle.coordinate) {
                        ShuttleVehicleMarker(
                            title: vehicle.name,
                            routeColor: color(forRouteNamed: vehicle.routeName)
                        )
                        .rotationEffect(.degrees(vehicle.headingDegrees ?? 0))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Text("Shuttles")
                    .font(.headline)

                if let lastUpdated = viewModel.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()

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
}

private struct ShuttleVehicleMarker: View {
    let title: String
    let routeColor: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "bus.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(10)
                .background(routeColor, in: Circle())
                .shadow(radius: 4)

            Text(title)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}
