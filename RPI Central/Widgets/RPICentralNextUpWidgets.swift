//
//  RPICentralNextUpWidgets.swift
//  WidgetsExtension
//

import WidgetKit
import SwiftUI

// MARK: - Provider

struct MonthEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct MonthProvider: TimelineProvider {

    func placeholder(in context: Context) -> MonthEntry {
        MonthEntry(date: Date(), snapshot: fallbackSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (MonthEntry) -> Void) {
        completion(MonthEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonthEntry>) -> Void) {
        let snap = loadSnapshot()
        let now = Date()

        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: now)
            ?? now.addingTimeInterval(30 * 60)

        completion(Timeline(entries: [MonthEntry(date: now, snapshot: snap)], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: RPICentralWidgetShared.appGroup),
              let data = defaults.data(forKey: RPICentralWidgetShared.snapshotKey)
        else {
            return fallbackSnapshot()
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WidgetSnapshot.self, from: data)
        } catch {
            return fallbackSnapshot()
        }
    }

    private func fallbackSnapshot() -> WidgetSnapshot {
        let cal = Calendar.current
        let now = Date()

        let month = makeMonthSnapshot(for: now, calendar: cal)

        return WidgetSnapshot(
            generatedAt: now,
            theme: .blue,
            appearance: .system,
            todayEvents: [],
            month: month
        )
    }

    private func makeMonthSnapshot(for date: Date, calendar cal: Calendar) -> MonthSnapshot {
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1

        let firstOfMonth = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? date
        let firstWeekday = cal.component(.weekday, from: firstOfMonth) // 1=Sun..7=Sat
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30

        let today = Date()
        let t = cal.dateComponents([.year, .month, .day], from: today)
        let todayDay: Int? = (t.year == year && t.month == month) ? t.day : nil

        var markers: [DayMarker] = []
        markers.reserveCapacity(daysInMonth)
        for d in 1...daysInMonth {
            markers.append(DayMarker(day: d, dotColors: [], hasExam: false, isBreakDay: false))
        }

        return MonthSnapshot(
            year: year,
            month: month,
            firstWeekday: firstWeekday,
            daysInMonth: daysInMonth,
            todayDay: todayDay,
            markers: markers
        )
    }
}

// MARK: - Widget

struct RPICentralMonthWidget: Widget {
    let kind = "RPICentralMonthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonthProvider()) { entry in
            RPICentralMonthWidgetView(entry: entry)
        }
        .configurationDisplayName("RPI Central — Month")
        .description("Month view with today’s events on the left (medium). Large shows month only.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - View

struct RPICentralMonthWidgetView: View {
    let entry: MonthEntry
    @Environment(\.widgetFamily) private var family

    private var month: MonthSnapshot { entry.snapshot.month }

    // Match CalendarView.swift background
    private let backgroundColor = Color(red: 0x20/255.0, green: 0x22/255.0, blue: 0x24/255.0)
    private let barColor        = Color(red: 0x2B/255.0, green: 0x2D/255.0, blue: 0x30/255.0)

    var body: some View {
        applyAppearance(
            content
                .containerBackground(for: .widget) { backgroundColor },
            appearance: entry.snapshot.appearance
        )
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            mediumLayout
        case .systemLarge:
            largeCalendarOnlyLayout
        default:
            mediumLayout
        }
    }

    // MARK: - Medium: left list + right month grid

    private var mediumLayout: some View {
        HStack(spacing: 10) {
            leftTodayPanel(maxRows: 3, compact: true)
            rightMonthPanel(compact: true)
                .layoutPriority(1) // prevent digit-cropping / compression
        }
        .padding(10)
    }

    // MARK: - Large: month grid only (NO events)

    private var largeCalendarOnlyLayout: some View {
        rightMonthPanel(compact: false)
            .padding(14)
    }

    // MARK: - Left panel (Today list)

    private func leftTodayPanel(maxRows: Int, compact: Bool) -> some View {
        let events = entry.snapshot.todayEvents

        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            headerToday(compact: compact)

            if events.isEmpty {
                Text("No events today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(events.prefix(maxRows)) { ev in
                        eventRow(ev, compact: compact)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerToday(compact: Bool) -> some View {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let title = df.string(from: entry.date)

        return VStack(alignment: .leading, spacing: 2) {
            Text("Today")
                .font(compact ? .subheadline : .headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(title)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func eventRow(_ ev: WidgetDayEvent, compact: Bool) -> some View {
        let timeText = timeLabel(for: ev)

        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(ev.accent.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitleLine(timeText: timeText, location: ev.location))
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func subtitleLine(timeText: String, location: String) -> String {
        location.isEmpty ? timeText : "\(timeText) • \(location)"
    }

    private func timeLabel(for ev: WidgetDayEvent) -> String {
        if ev.isAllDay { return "All day" }
        let df = DateFormatter()
        df.timeStyle = .short
        return "\(df.string(from: ev.startDate)) – \(df.string(from: ev.endDate))"
    }

    // MARK: - Right panel (Month) — fixed 6-row grid (stable in widgets)

    private func rightMonthPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {

            // mini top bar (like your in-app top bar)
            HStack {
                Text(monthTitle(year: month.year, month: month.month))
                    .font(compact ? .subheadline.bold() : .headline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 6 : 8)
            .background(barColor)
            .cornerRadius(12)

            weekdayRow(topPad: 0)

            monthGridFixed(compact: compact)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func weekdayRow(topPad: CGFloat) -> some View {
        let labels: [String] = (family == .systemMedium)
            ? ["M","T","W","T","F","S","S"]
            : ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]

        return HStack {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, topPad)
    }

    private func monthGridFixed(compact: Bool) -> some View {
        // In-app: firstWeekday is 1=Sun..7=Sat; Monday-first grid:
        let leadingBlanks = (month.firstWeekday - 2 + 7) % 7
        let totalCells = leadingBlanks + month.daysInMonth

        // Always 6 rows in widget (Apple Calendar style stability)
        let rows = 6
        let totalGridCells = rows * 7

        let markerByDay: [Int: DayMarker] = Dictionary(
            uniqueKeysWithValues: month.markers.map { ($0.day, $0) }
        )

        let cellH: CGFloat = compact ? 26 : 34
        let dotSize: CGFloat = 5

        let cols: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return LazyVGrid(columns: cols, spacing: 4) {
            ForEach(0..<totalGridCells, id: \.self) { idx in
                let dayNumber = idx - leadingBlanks + 1

                if dayNumber < 1 || dayNumber > month.daysInMonth {
                    Color.clear
                        .frame(height: cellH)
                } else {
                    let isToday = (month.todayDay == dayNumber)
                    let isSelected = isToday

                    let marker = markerByDay[dayNumber]
                    let dotColors = marker?.dotColors ?? []
                    let isBreakDay = marker?.isBreakDay ?? false

                    VStack(spacing: 3) {
                        Text("\(dayNumber)")
                            .font(.caption)
                            .monospacedDigit() // ✅ fixes 1-digit/2-digit shifting
                            .foregroundColor(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if dotColors.isEmpty {
                            Circle().fill(Color.clear)
                                .frame(width: dotSize, height: dotSize)
                        } else {
                            HStack(spacing: 3) {
                                let colors = Array(dotColors.prefix(3))
                                ForEach(colors.indices, id: \.self) { i in
                                    Circle()
                                        .fill(colors[i].color)
                                        .frame(width: dotSize, height: dotSize)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(5)
                    .background(
                        ZStack {
                            if isSelected {
                                Color.white
                            } else if isBreakDay {
                                Color.orange.opacity(0.22)
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isToday ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.6)
                    )
                    .cornerRadius(7)
                    .frame(height: cellH)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func monthTitle(year: Int, month: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "LLLL"
        let cal = Calendar.current
        let d = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        return "\(df.string(from: d)) \(year)"
    }
}

// MARK: - Appearance helper

@ViewBuilder
private func applyAppearance<V: View>(_ view: V, appearance: RPICentralWidgetAppearance) -> some View {
    switch appearance {
    case .system:
        view
    case .light:
        view.environment(\.colorScheme, .light)
    case .dark:
        view.environment(\.colorScheme, .dark)
    }
}
