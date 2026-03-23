import SwiftUI

struct ShuttleTrackerFeatureView: View {
    @AppStorage("shuttle_tracker_refresh_interval_seconds") private var shuttleTrackerRefreshIntervalSeconds = 5
    private static let shuttleAPIBaseURL = URL(string: "https://api-shuttles.rpi.edu/")!

    var body: some View {
        ShuttleTrackerMapScreen(
            baseURL: Self.shuttleAPIBaseURL,
            refreshIntervalSeconds: shuttleTrackerRefreshIntervalSeconds
        )
        .id(shuttleTrackerRefreshIntervalSeconds)
    }
}
