//
//  WatchViews.swift
//  RPI Central Watch
//

import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchScheduleStore

    var body: some View {
        if let snapshot = store.snapshot {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                NavigationStack {
                    TabView {
                        UpNextPage(snapshot: snapshot, now: context.date)
                        TodayPage(snapshot: snapshot, now: context.date)
                        DueSoonPage(snapshot: snapshot, now: context.date)
                    }
                    .tabViewStyle(.verticalPage)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Open RPI Central on your iPhone to sync your schedule.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

// MARK: - Up Next

private struct UpNextPage: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let upcoming = snapshot.upcomingTimed(after: now)
        let current = upcoming.first { $0.startDate <= now }
        let event = current ?? upcoming.first

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(current != nil ? "NOW" : label(for: event))
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(current != nil ? .green : snapshot.accentColor)

                if let event {
                    Text(event.courseCode ?? event.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(event.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Group {
                        if current != nil {
                            Text("Ends \(event.endDate.formatted(date: .omitted, time: .shortened))")
                        } else if event.startDate.timeIntervalSince(now) < 3 * 3600 {
                            Text("in \(Text(event.startDate, style: .relative))")
                        } else {
                            Text(event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(event.accent.color)
                    .padding(.top, 2)

                    if !event.location.isEmpty {
                        Label(WidgetText.shortLocation(event.location), systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .lineLimit(2)
                    }
                    if current != nil {
                        ProgressView(timerInterval: event.startDate...event.endDate, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .tint(event.accent.color)
                        .padding(.top, 4)
                    }
                } else {
                    Text("You’re free")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("No more classes this week.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(
            LinearGradient(colors: [(event?.accent.color ?? snapshot.accentColor).opacity(0.45), .clear], startPoint: .top, endPoint: .bottom),
            for: .tabView
        )
        .navigationTitle("Up Next")
    }

    private func label(for event: WidgetDayEvent?) -> String {
        guard let event else { return "UP NEXT" }
        if Calendar.current.isDate(event.startDate, inSameDayAs: now) { return "UP NEXT" }
        if Calendar.current.isDateInTomorrow(event.startDate) { return "TOMORROW" }
        return event.startDate.formatted(.dateTime.weekday(.wide)).uppercased()
    }
}

// MARK: - Today

private struct TodayPage: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let events = snapshot.events(on: now)
        List {
            if events.isEmpty {
                Text("Nothing on the calendar today.")
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                let isNow = !event.isAllDay && event.startDate <= now && now < event.endDate
                HStack(spacing: 8) {
                    Capsule()
                        .fill(event.accent.color)
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.courseCode ?? event.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(isNow ? .green : .secondary)
                        if !event.location.isEmpty {
                            Text(WidgetText.shortLocation(event.location))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .opacity(!event.isAllDay && event.endDate <= now ? 0.5 : 1)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12).fill(isNow ? Color.green.opacity(0.18) : Color.gray.opacity(0.18))
                )
            }
        }
        .navigationTitle(now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
    }
}

// MARK: - Due Soon

private struct DueSoonPage: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let deadlines = snapshot.upcomingDeadlines(after: now)
        List {
            if deadlines.isEmpty {
                Label("All caught up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(deadlines.prefix(10)) { deadline in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: deadline.systemImage)
                        .foregroundStyle(deadline.kind == "exam" ? .orange : deadline.color.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(deadline.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text([deadline.courseCode, relative(deadline.dueDate)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(deadline.dueDate.timeIntervalSince(now) < 86_400 ? .red : .secondary)
                    }
                }
            }
        }
        .navigationTitle("Due Soon")
    }

    private func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
