//
//  WidgetGallery.swift
//  RPI Central
//
//  Debug builds only: shows every widget with real data, for checking the
//  designs and for App Store screenshots. Launch with RPI_WIDGET_GALLERY=1.
//

#if DEBUG
import SwiftUI
import WidgetKit

struct WidgetGalleryView: View {
    private var entry: ScheduleEntry {
        let now = Date()
        return ScheduleEntry(date: now, snapshot: WidgetSnapshotStore.load() ?? .sample(now: now))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    tile(UpNextWidgetView(entry: entry), family: .systemSmall)
                    tile(DeadlinesWidgetView(entry: entry), family: .systemSmall)
                }
                tile(TodayAgendaWidgetView(entry: entry), family: .systemMedium)
                tile(MonthWidgetView(entry: entry), family: .systemMedium)
                tile(UpNextWidgetView(entry: entry), family: .systemMedium)
                tile(DeadlinesWidgetView(entry: entry), family: .systemLarge)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.45), Color(red: 0.35, green: 0.2, blue: 0.5)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func tile<V: View>(_ view: V, family: WidgetFamily) -> some View {
        let size: CGSize = switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        default: CGSize(width: 364, height: 382)
        }
        return view
            .environment(\.widgetFamilyOverride, family)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}
#endif
