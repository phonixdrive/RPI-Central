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

// MARK: - Widgets

/// 1x1 (small): month-only
/// 1x2 (medium): month-only
/// 2x2 (large): month + today-events strip at bottom
struct RPICentralMonthWidget: Widget {
    let kind = "RPICentralMonthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonthProvider()) { entry in
            RPICentralMonthOnlyWidgetView(entry: entry)
        }
        .configurationDisplayName("RPI Central — Month")
        .description("Month view. Large shows a small today-events preview.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Separate 1x2 (medium): left today events + right mini month (Apple Calendar-style)
struct RPICentralMonthAndTodayWidget: Widget {
    let kind = "RPICentralMonthAndTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonthProvider()) { entry in
            RPICentralMonthAndTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("RPI Central — Today + Month")
        .description("Today’s events on the left, month on the right.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Shared styling + helpers

private let widgetBackgroundColor = Color(red: 0x20/255.0, green: 0x22/255.0, blue: 0x24/255.0)
private let widgetBarColor        = Color(red: 0x2B/255.0, green: 0x2D/255.0, blue: 0x30/255.0)

private struct MonthGridMetrics {
    var cellH: CGFloat
    var dotSize: CGFloat
    var cellPad: CGFloat
    var corner: CGFloat
    var gridSpacing: CGFloat
    var colsSpacing: CGFloat

    // ✅ tighten ONLY the 1x1 grid so double-digits fit cleanly
    static let small  = MonthGridMetrics(cellH: 18, dotSize: 4, cellPad: 1.2, corner: 6, gridSpacing: 1.2, colsSpacing: 0.8)

    static let medium = MonthGridMetrics(cellH: 22, dotSize: 5, cellPad: 4.5, corner: 7, gridSpacing: 4, colsSpacing: 4)
    static let large  = MonthGridMetrics(cellH: 32, dotSize: 5, cellPad: 5.0, corner: 8, gridSpacing: 4, colsSpacing: 4)
}

private func monthTitle(year: Int, month: Int) -> String {
    let df = DateFormatter()
    df.dateFormat = "LLLL"
    let cal = Calendar.current
    let d = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    return "\(df.string(from: d)) \(year)"
}

private func timeLabel(for ev: WidgetDayEvent) -> String {
    if ev.isAllDay { return "All day" }
    let df = DateFormatter()
    df.timeStyle = .short
    return "\(df.string(from: ev.startDate))–\(df.string(from: ev.endDate))"
}

private func subtitleLine(timeText: String, location: String) -> String {
    location.isEmpty ? timeText : "\(timeText) • \(location)"
}

/// ✅ "Today’s events" (not "upcoming after now")
private func todaysEvents(from all: [WidgetDayEvent], now: Date, max: Int) -> [WidgetDayEvent] {
    let cal = Calendar.current

    let allDay = all
        .filter { $0.isAllDay }
        .filter { cal.isDate($0.startDate, inSameDayAs: now) || cal.isDate($0.endDate, inSameDayAs: now) }

    let timed = all
        .filter { !$0.isAllDay }
        .filter { cal.isDate($0.startDate, inSameDayAs: now) }
        .sorted { $0.startDate < $1.startDate }

    return Array((allDay + timed).prefix(max))
}

// MARK: - Month-only widget view

struct RPICentralMonthOnlyWidgetView: View {
    let entry: MonthEntry
    @Environment(\.widgetFamily) private var family

    private var month: MonthSnapshot { entry.snapshot.month }

    var body: some View {
        applyAppearance(
            content
                .containerBackground(for: .widget) { widgetBackgroundColor },
            appearance: entry.snapshot.appearance
        )
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            smallLayout
        case .systemMedium:
            mediumLayoutMonthOnly
        case .systemLarge:
            largeLayoutMonthOnly
        default:
            mediumLayoutMonthOnly
        }
    }

    // MARK: - Small (1x1): month-only

    private var smallLayout: some View {
        VStack(spacing: 2) {
            monthHeader(font: .caption.bold(), verticalPad: 4, horizontalPad: 6)

            weekdayRow(style: .tiny)
                .padding(.horizontal, 0)

            monthGridFixed(metrics: .small, compactDigits: true)
                .padding(.horizontal, 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .padding(.horizontal, 0)
    }

    // MARK: - Medium (1x2): month-only

    private var mediumLayoutMonthOnly: some View {
        VStack(spacing: 5) {
            monthHeader(font: .subheadline.bold(), verticalPad: 6, horizontalPad: 10)
                .layoutPriority(1)

            weekdayRow(style: .short)
                .padding(.horizontal, 2)

            monthGridFixed(metrics: .medium, compactDigits: false)
                .padding(.horizontal, 2)
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Large (2x2): month + bottom today-events strip

    private var largeLayoutMonthOnly: some View {
        VStack(spacing: 1) {
            monthHeader(font: .headline.bold(), verticalPad: 8, horizontalPad: 12)
                .layoutPriority(1)

            weekdayRow(style: .full)
                .padding(.horizontal, 4)

            monthGridFixed(metrics: .large, compactDigits: false)
                .padding(.horizontal, 4)

            todayEventsStrip(maxRows: 3)
               // .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.top, 20)  // or 20
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Components

    private func monthHeader(font: Font, verticalPad: CGFloat, horizontalPad: CGFloat) -> some View {
        HStack {
            Text(monthTitle(year: month.year, month: month.month))
                .font(font)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPad)
        .padding(.vertical, verticalPad)
        .background(widgetBarColor)
        .cornerRadius(12)
    }

    private enum WeekdayStyle { case tiny, short, full }

    private func weekdayRow(style: WeekdayStyle) -> some View {
        let labels: [String] = {
            switch style {
            case .tiny:  return ["M","T","W","T","F","S","S"]
            case .short: return ["M","T","W","T","F","S","S"]
            case .full:  return ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            }
        }()

        return HStack {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(style == .full ? .caption : .caption2)
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func monthGridFixed(metrics: MonthGridMetrics, compactDigits: Bool) -> some View {
        // firstWeekday is 1=Sun..7=Sat; we want Monday-first grid:
        let leadingBlanks = (month.firstWeekday - 2 + 7) % 7

        let rows = 6
        let totalGridCells = rows * 7

        let markerByDay: [Int: DayMarker] = Dictionary(
            uniqueKeysWithValues: month.markers.map { ($0.day, $0) }
        )

        let cols: [GridItem] = Array(
            repeating: GridItem(.flexible(), spacing: metrics.colsSpacing),
            count: 7
        )

        return LazyVGrid(columns: cols, spacing: metrics.gridSpacing) {
            // ✅ IMPORTANT: force Int here so Swift doesn't try to pick the Binding ForEach initializer
            ForEach(0..<totalGridCells, id: \.self) { (idx: Int) in
                let dayNumber = idx - leadingBlanks + 1

                if dayNumber < 1 || dayNumber > month.daysInMonth {
                    Color.clear
                        .frame(height: metrics.cellH)
                } else {
                    let isToday = (month.todayDay == dayNumber)
                    let marker = markerByDay[dayNumber]
                    let dotColors = marker?.dotColors ?? []
                    let isBreakDay = marker?.isBreakDay ?? false

                    VStack(spacing: 2.5) {
                        if compactDigits {
                            // ✅ 1x1 only: make sure 10–31 never clips/ellipsis
                            Text("\(dayNumber)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.25)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                                .foregroundColor(isToday ? .black : .white)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("\(dayNumber)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundColor(isToday ? .black : .white)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if dotColors.isEmpty {
                            Circle().fill(Color.clear)
                                .frame(width: metrics.dotSize, height: metrics.dotSize)
                        } else {
                            HStack(spacing: 2.5) {
                                let colors = Array(dotColors.prefix(3))
                                ForEach(colors.indices, id: \.self) { i in
                                    Circle()
                                        .fill(colors[i].color)
                                        .frame(width: metrics.dotSize, height: metrics.dotSize)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(metrics.cellPad)
                    .background(
                        ZStack {
                            if isToday {
                                Color.white
                            } else if isBreakDay {
                                Color.orange.opacity(0.22)
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.corner)
                            .stroke(isToday ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.4)
                    )
                    .cornerRadius(metrics.corner)
                    .frame(height: metrics.cellH)
                }
            }
        }
    }

    // ✅ detailed strip for 2x2 (title + time/location)
    private func todayEventsStrip(maxRows: Int) -> some View {
        let events = todaysEvents(from: entry.snapshot.todayEvents, now: entry.date, max: maxRows)

        return VStack(alignment: .leading, spacing: 4) {
            if events.isEmpty {
                Text("No events today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ForEach(events.prefix(maxRows)) { ev in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ev.accent.color)
                            .frame(width: 4)

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(ev.title)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(subtitleLine(timeText: timeLabel(for: ev), location: ev.location))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(widgetBarColor.opacity(0.7))
        .cornerRadius(10)
    }
}

// MARK: - Month + Today widget view (medium only)

struct RPICentralMonthAndTodayWidgetView: View {
    let entry: MonthEntry
    @Environment(\.widgetFamily) private var family

    private var month: MonthSnapshot { entry.snapshot.month }

    var body: some View {
        applyAppearance(
            content
                .containerBackground(for: .widget) { widgetBackgroundColor },
            appearance: entry.snapshot.appearance
        )
    }

    private var content: some View {
        HStack(spacing: 12) {
            todayPanel(maxRows: 2)
                .layoutPriority(2)

            miniMonthPanel()
                .frame(width: 175)
                .layoutPriority(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 30)
        .padding(.bottom, 25)
        .padding(.horizontal, 16)
    }

    private func todayPanel(maxRows: Int) -> some View {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let title = df.string(from: entry.date)

        let events = todaysEvents(from: entry.snapshot.todayEvents, now: entry.date, max: maxRows)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if events.isEmpty {
                Text("No events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events.prefix(maxRows)) { ev in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ev.accent.color)
                                .frame(width: 4)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.title)
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(subtitleLine(timeText: timeLabel(for: ev), location: ev.location))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniMonthPanel() -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(monthTitle(year: month.year, month: month.month))
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(widgetBarColor)
            .cornerRadius(12)

            HStack {
                ForEach(["M","T","W","T","F","S","S"], id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 2)

            MonthGridReuse(month: month, metrics: .small, compactDigits: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Reuse grid (for mini month in 1x2)

private struct MonthGridReuse: View {
    let month: MonthSnapshot
    let metrics: MonthGridMetrics
    let compactDigits: Bool

    var body: some View {
        let leadingBlanks = (month.firstWeekday - 2 + 7) % 7
        let rows = 6
        let totalGridCells = rows * 7

        let markerByDay: [Int: DayMarker] = Dictionary(
            uniqueKeysWithValues: month.markers.map { ($0.day, $0) }
        )

        let cols: [GridItem] = Array(
            repeating: GridItem(.flexible(), spacing: metrics.colsSpacing),
            count: 7
        )

        return LazyVGrid(columns: cols, spacing: metrics.gridSpacing) {
            // ✅ IMPORTANT: force Int here as well
            ForEach(0..<totalGridCells, id: \.self) { (idx: Int) in
                let dayNumber = idx - leadingBlanks + 1

                if dayNumber < 1 || dayNumber > month.daysInMonth {
                    Color.clear
                        .frame(height: metrics.cellH)
                } else {
                    let isToday = (month.todayDay == dayNumber)
                    let marker = markerByDay[dayNumber]
                    let dotColors = marker?.dotColors ?? []
                    let isBreakDay = marker?.isBreakDay ?? false

                    VStack(spacing: 2.5) {
                        if compactDigits {
                            Text("\(dayNumber)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.25)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                                .foregroundColor(isToday ? .black : .white)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("\(dayNumber)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundColor(isToday ? .black : .white)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if dotColors.isEmpty {
                            Circle().fill(Color.clear)
                                .frame(width: metrics.dotSize, height: metrics.dotSize)
                        } else {
                            HStack(spacing: 2.5) {
                                let colors = Array(dotColors.prefix(3))
                                ForEach(colors.indices, id: \.self) { i in
                                    Circle()
                                        .fill(colors[i].color)
                                        .frame(width: metrics.dotSize, height: metrics.dotSize)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(metrics.cellPad)
                    .background(
                        ZStack {
                            if isToday {
                                Color.white
                            } else if isBreakDay {
                                Color.orange.opacity(0.22)
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.corner)
                            .stroke(isToday ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.4)
                    )
                    .cornerRadius(metrics.corner)
                    .frame(height: metrics.cellH)
                }
            }
        }
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
