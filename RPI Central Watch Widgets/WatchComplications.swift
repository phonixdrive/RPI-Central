//
//  WatchComplications.swift
//  RPI Central Watch Widgets
//
//  Watch face complications: next class, and what's due next.
//

import SwiftUI
import WidgetKit

struct WatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: Date(), snapshot: .sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: Date(), snapshot: load() ?? (context.isPreview ? .sample(now: Date()) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let now = Date()
        let snapshot = load()
        var dates: Set<Date> = [now]
        for event in snapshot?.upcomingEvents ?? [] where !event.isAllDay {
            for date in [event.startDate, event.endDate] where date > now && date < now.addingTimeInterval(24 * 3600) {
                dates.insert(date)
            }
        }
        let entries = dates.sorted().prefix(30).map { WatchEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: Array(entries), policy: .after(now.addingTimeInterval(4 * 3600))))
    }

    private func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: RPICentralWidgetShared.appGroup)?.data(forKey: RPICentralWidgetShared.snapshotKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

@main
struct RPICentralWatchWidgets: WidgetBundle {
    var body: some Widget {
        NextClassComplication()
        DueSoonComplication()
    }
}

struct NextClassComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RPICentralWatchNextClass", provider: WatchProvider()) { entry in
            NextClassComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Next Class")
        .description("Your current or next class.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct DueSoonComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RPICentralWatchDueSoon", provider: WatchProvider()) { entry in
            DueSoonComplicationView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Due Soon")
        .description("What’s due next.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

private func number(from event: WidgetDayEvent) -> String {
    event.courseCode?.split(separator: " ").last.map(String.init) ?? String(event.title.prefix(4))
}

struct NextClassComplicationView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let upcoming = entry.snapshot?.upcomingTimed(after: entry.date) ?? []
        let current = upcoming.first { $0.startDate <= entry.date }
        let event = current ?? upcoming.first

        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                if let event {
                    Text(current != nil ? "NOW" : "NEXT")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(current != nil ? .green : .accentColor)
                        .widgetAccentable()
                    Text(event.courseCode ?? event.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(current != nil
                         ? "until \(event.endDate.formatted(date: .omitted, time: .shortened))"
                         : "\(event.startDate.formatted(date: .omitted, time: .shortened)) · \(WidgetText.shortLocation(event.location))")
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("No classes").font(.headline)
                    Text("Nothing left today").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            if let event {
                Text("\(event.courseCode ?? event.title) \(event.startDate.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("No more classes")
            }
        case .accessoryCorner:
            Image(systemName: "graduationcap.fill")
                .font(.title3)
                .widgetLabel {
                    if let event {
                        Text("\(event.courseCode ?? event.title) \(event.startDate.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Free")
                    }
                }
        default:
            if let event {
                if let current {
                    ProgressView(timerInterval: current.startDate...current.endDate, countsDown: false) {
                        Text(number(from: event))
                    } currentValueLabel: {
                        Text(number(from: event)).font(.system(size: 12, weight: .bold))
                    }
                    .progressViewStyle(.circular)
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: -1) {
                            Text(number(from: event)).font(.system(size: 11, weight: .bold))
                            Text(event.startDate.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                    }
                }
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "checkmark").font(.title3.weight(.bold))
                }
            }
        }
    }
}

struct DueSoonComplicationView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let deadlines = entry.snapshot?.upcomingDeadlines(after: entry.date) ?? []
        let weekCount = deadlines.filter { $0.dueDate < entry.date.addingTimeInterval(7 * 86_400) }.count

        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("DUE SOON")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .widgetAccentable()
                if let first = deadlines.first {
                    Text(first.title).font(.headline).lineLimit(1)
                    Text("\(first.courseCode.isEmpty ? "" : first.courseCode + " · ")\(first.dueDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("All caught up").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            if let first = deadlines.first {
                Text("\(first.title) · \(first.dueDate.formatted(.dateTime.weekday(.abbreviated)))")
            } else {
                Text("Nothing due")
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text("\(weekCount)").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("DUE").font(.system(size: 9, weight: .heavy))
                }
            }
        }
    }
}
