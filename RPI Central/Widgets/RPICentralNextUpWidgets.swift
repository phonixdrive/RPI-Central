//
//  RPICentralNextUpWidgets.swift
//  WidgetsExtension
//
//  Home Screen and Lock Screen widgets. The app writes a WidgetSnapshot to
//  the shared app group; these views only read it.
//

import SwiftUI
import WidgetKit

// MARK: - Family override

/// Lets the app's debug widget gallery render each size; widgets on the
/// Home Screen use WidgetKit's family.
private struct WidgetFamilyOverrideKey: EnvironmentKey {
    static let defaultValue: WidgetFamily? = nil
}

extension EnvironmentValues {
    var widgetFamilyOverride: WidgetFamily? {
        get { self[WidgetFamilyOverrideKey.self] }
        set { self[WidgetFamilyOverrideKey.self] = newValue }
    }
}

// MARK: - Provider

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: Date(), snapshot: WidgetSnapshotStore.sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        let now = Date()
        let snapshot = context.isPreview && WidgetSnapshotStore.load() == nil
            ? WidgetSnapshotStore.sample(now: now)
            : (WidgetSnapshotStore.load() ?? WidgetSnapshotStore.empty(now: now))
        completion(ScheduleEntry(date: now, snapshot: snapshot))
    }

    /// One entry now and one at every class start and end in the next day,
    /// so "Now" and "Up Next" flip over on time without the app running.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.load() ?? WidgetSnapshotStore.empty(now: now)
        let horizon = now.addingTimeInterval(24 * 3600)
        let calendar = Calendar.current

        var dates: Set<Date> = [now]
        for event in snapshot.upcomingEvents ?? snapshot.todayEvents where !event.isAllDay {
            for date in [event.startDate, event.endDate] where date > now && date < horizon {
                dates.insert(date)
            }
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.insert(midnight)
        }
        // On days without classes, Today switches to tomorrow at 5 PM.
        if let evening = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now), evening > now {
            dates.insert(evening)
        }
        let entries = dates.sorted().prefix(40).map { ScheduleEntry(date: $0, snapshot: snapshot) }
        let refresh = min(entries.last?.date ?? horizon, now.addingTimeInterval(6 * 3600))
        completion(Timeline(entries: Array(entries), policy: .after(max(refresh, now.addingTimeInterval(15 * 60)))))
    }
}

enum WidgetSnapshotStore {
    static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: RPICentralWidgetShared.appGroup),
              let data = defaults.data(forKey: RPICentralWidgetShared.snapshotKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func empty(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, theme: .blue, appearance: .system, todayEvents: [], month: month(for: now))
    }

    static func sample(now: Date) -> WidgetSnapshot { WidgetSnapshot.sample(now: now) }

    static func month(for date: Date, calendar: Calendar = .current) -> MonthSnapshot {
        WidgetSnapshot.month(for: date, calendar: calendar)
    }
}

// MARK: - Widgets

struct RPICentralUpNextWidget: Widget {
    let kind = "RPICentralUpNextWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your current or next class, with a countdown and room.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct RPICentralTodayWidget: Widget {
    let kind = "RPICentralTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            TodayAgendaWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today’s classes and events at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RPICentralDeadlinesWidget: Widget {
    let kind = "RPICentralDeadlinesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            DeadlinesWidgetView(entry: entry)
        }
        .configurationDisplayName("Due Soon")
        .description("Assignments, quizzes, and exams coming up.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

/// Kept as "RPICentralMonthWidget" so widgets people already placed keep working.
struct RPICentralMonthWidget: Widget {
    let kind = "RPICentralMonthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            MonthWidgetView(entry: entry)
        }
        .configurationDisplayName("Month")
        .description("This month with class and exam days marked.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RPICentralMonthAndTodayWidget: Widget {
    let kind = "RPICentralMonthAndTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            MonthAndTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today + Month")
        .description("Today’s events beside the month.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Shared design

private struct WidgetChrome<Content: View>: View {
    let snapshot: WidgetSnapshot
    var url: URL? = WidgetLinks.calendar
    @ViewBuilder let content: Content

    var body: some View {
        applyAppearance(
            content
                .widgetURL(url)
                .containerBackground(for: .widget) { WidgetBackground(accent: snapshot.accentColor) },
            appearance: snapshot.appearance
        )
    }
}

private struct WidgetBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground)
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.22 : 0.10), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }
}

enum WidgetLinks {
    static let calendar = URL(string: "rpicentral://calendar")
    static let tasks = URL(string: "rpicentral://tasks")

    static func day(_ date: Date) -> URL? {
        URL(string: "rpicentral://calendar?date=\(Int(date.timeIntervalSince1970))")
    }
}

private enum WidgetFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "10:00" when the period is obvious; used in tight rows.
    static func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
            .replacingOccurrences(of: ":00", with: "")
    }

    static func dueLabel(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let hours = date.timeIntervalSince(now) / 3600
        if hours < 1 { return "\(max(1, Int(hours * 60)))m" }
        if calendar.isDateInToday(date) { return "\(Int(hours))h" }
        if calendar.isDateInTomorrow(date) { return "Tmrw" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct EventLabel: View {
    let event: WidgetDayEvent
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        HStack(spacing: 4) {
            Text(event.courseCode ?? event.title)
                .font(font)
                .lineLimit(1)
            if event.badge == "exam" {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct AgendaRow: View {
    let event: WidgetDayEvent
    let now: Date
    var showsLocation = true

    var body: some View {
        let isNow = !event.isAllDay && event.startDate <= now && now < event.endDate
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.accent.color)
                .frame(width: 4)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(event.courseCode.map { "\($0) · \(event.title)" } ?? event.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if event.badge == "exam" {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isNow {
                Text("NOW")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.green))
            }
        }
        .frame(height: 30)
        .opacity(!event.isAllDay && event.endDate <= now ? 0.45 : 1)
    }

    private var subtitle: String {
        let time = event.isAllDay ? "All day" : "\(WidgetFormat.time(event.startDate)) – \(WidgetFormat.time(event.endDate))"
        guard showsLocation, !event.location.isEmpty else { return time }
        return "\(time) · \(WidgetText.shortLocation(event.location))"
    }
}

private struct DeadlineRow: View {
    let deadline: WidgetDeadline
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deadline.systemImage)
                .font(.caption)
                .foregroundStyle(deadline.kind == "exam" ? Color.orange : deadline.color.color)
                .frame(width: 16)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(deadline.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !deadline.courseCode.isEmpty {
                    Text(deadline.courseCode)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(WidgetFormat.dueLabel(deadline.dueDate, now: now))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(deadline.dueDate.timeIntervalSince(now) < 86_400 ? Color.red : Color.secondary)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let accent: Color
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .widgetAccentable()
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Up Next

struct UpNextWidgetView: View {
    let entry: ScheduleEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride
    private var family: WidgetFamily { familyOverride ?? systemFamily }

    private var upcoming: [WidgetDayEvent] { entry.snapshot.upcomingTimed(after: entry.date) }
    private var current: WidgetDayEvent? { upcoming.first { $0.startDate <= entry.date } }
    private var next: WidgetDayEvent? { current ?? upcoming.first }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .accessoryInline: inline
        case .systemMedium: WidgetChrome(snapshot: entry.snapshot, url: next.flatMap { WidgetLinks.day($0.startDate) }) { medium }
        default: WidgetChrome(snapshot: entry.snapshot, url: next.flatMap { WidgetLinks.day($0.startDate) }) { small }
        }
    }

    private var accent: Color { entry.snapshot.accentColor }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: current != nil ? "Now" : dayLabel(next), accent: current != nil ? .green : accent)
            if let event = next {
                Spacer(minLength: 0)
                EventLabel(event: event, font: .title3.weight(.bold))
                Text(event.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                countdown(for: event)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                if !event.location.isEmpty {
                    Label(WidgetText.shortLocation(event.location), systemImage: "mappin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            small
                .frame(maxWidth: .infinity)
            if let event = next {
                let later = upcoming.filter { $0.id != event.id }.prefix(3)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Later", accent: .secondary)
                    if later.isEmpty {
                        Text("Nothing else coming up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(later)) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 5) {
                                Circle().fill(item.accent.color).frame(width: 6, height: 6)
                                Text(item.courseCode ?? item.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Text(laterTimeLabel(item))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 11)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let event = next {
                HStack(spacing: 4) {
                    Image(systemName: current != nil ? "circle.fill" : "clock")
                        .font(.caption2)
                    Text(event.courseCode ?? event.title)
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                }
                Text(event.location.isEmpty ? event.title : WidgetText.shortLocation(event.location))
                    .font(.caption)
                    .lineLimit(1)
                countdown(for: event)
                    .font(.caption)
            } else {
                Text("No classes")
                    .font(.headline)
                Text("Nothing left today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetLinks.calendar)
        .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private var circular: some View {
        Group {
            if let event = next {
                if let current {
                    ProgressView(timerInterval: current.startDate...current.endDate, countsDown: false) {
                        Text(shortCode(event))
                    } currentValueLabel: {
                        Text(shortCode(event)).font(.system(size: 11, weight: .bold))
                    }
                    .progressViewStyle(.circular)
                } else {
                    let windowStart = max(entry.date, event.startDate.addingTimeInterval(-3600))
                    ProgressView(timerInterval: windowStart...event.startDate, countsDown: true) {
                        Text(shortCode(event))
                    } currentValueLabel: {
                        VStack(spacing: -1) {
                            Text(shortCode(event)).font(.system(size: 9, weight: .bold))
                            Text(WidgetFormat.shortTime(event.startDate)).font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .progressViewStyle(.circular)
                }
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "checkmark").font(.title3.weight(.bold))
                }
            }
        }
        .widgetURL(WidgetLinks.calendar)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var inline: some View {
        Group {
            if let event = next {
                if current != nil {
                    Text("\(event.courseCode ?? event.title) until \(WidgetFormat.time(event.endDate))")
                } else {
                    Text("\(event.courseCode ?? event.title) \(WidgetFormat.time(event.startDate))\(event.location.isEmpty ? "" : " · \(WidgetText.shortLocation(event.location))")")
                }
            } else {
                Text("No more classes today")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private func countdown(for event: WidgetDayEvent) -> some View {
        if event.startDate <= entry.date {
            Text("Ends \(WidgetFormat.time(event.endDate))")
        } else if event.startDate.timeIntervalSince(entry.date) < 3 * 3600 {
            Text("in \(Text(event.startDate, style: .relative))")
        } else {
            Text(Calendar.current.isDate(event.startDate, inSameDayAs: entry.date)
                 ? WidgetFormat.time(event.startDate)
                 : event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(accent)
            Text("You’re free")
                .font(.headline)
            Text("No more classes this week")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func dayLabel(_ event: WidgetDayEvent?) -> String {
        guard let event else { return "Up Next" }
        let calendar = Calendar.current
        if calendar.isDate(event.startDate, inSameDayAs: entry.date) { return "Up Next" }
        if calendar.isDateInTomorrow(event.startDate) { return "Tomorrow" }
        return event.startDate.formatted(.dateTime.weekday(.wide))
    }

    private func laterTimeLabel(_ event: WidgetDayEvent) -> String {
        if Calendar.current.isDate(event.startDate, inSameDayAs: entry.date) {
            return WidgetFormat.time(event.startDate)
        }
        return event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func shortCode(_ event: WidgetDayEvent) -> String {
        if let code = event.courseCode, let number = code.split(separator: " ").last {
            return String(number)
        }
        return String(event.title.prefix(4))
    }
}

// MARK: - Today

struct TodayAgendaWidgetView: View {
    let entry: ScheduleEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride
    private var family: WidgetFamily { familyOverride ?? systemFamily }

    private var calendar: Calendar { .current }

    private func remainingToday() -> Int {
        entry.snapshot.events(on: entry.date).filter { !$0.isAllDay && $0.endDate > entry.date }.count
    }

    /// Once today's classes are over, the widget looks ahead to tomorrow
    /// instead of showing a list of finished classes.
    private var showsTomorrow: Bool {
        let today = entry.snapshot.events(on: entry.date)
        return (today.isEmpty && calendar.component(.hour, from: entry.date) >= 17) ||
            (!today.isEmpty && remainingToday() == 0)
    }

    private var day: Date {
        showsTomorrow
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.date)) ?? entry.date
            : entry.date
    }

    var body: some View {
        WidgetChrome(snapshot: entry.snapshot, url: WidgetLinks.day(day)) {
            VStack(alignment: .leading, spacing: 6) {
                header
                let events = entry.snapshot.events(on: day)
                let visible = visibleEvents(events)
                if events.isEmpty {
                    Spacer(minLength: 0)
                    Label(showsTomorrow ? "No classes tomorrow" : "Nothing on the calendar today", systemImage: showsTomorrow ? "moon.stars" : "sun.max")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(visible) { event in
                        Link(destination: WidgetLinks.day(event.startDate) ?? URL(string: "rpicentral://calendar")!) {
                            AgendaRow(event: event, now: entry.date)
                        }
                    }
                    if events.count > visible.count {
                        Text("+\(events.count - visible.count) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if family == .systemLarge {
                    dueSoonFooter
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(showsTomorrow ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide)))
                .font(.headline)
            Text(day.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            let timed = entry.snapshot.events(on: day).filter { !$0.isAllDay }.count
            if showsTomorrow {
                if timed > 0 {
                    Text(timed == 1 ? "1 class" : "\(timed) classes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                let remaining = remainingToday()
                Text(remaining == 0 ? "Free today" : "\(remaining) left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.snapshot.accentColor)
                    .widgetAccentable()
            }
        }
    }

    /// Hides classes that already ended when space is tight.
    private func visibleEvents(_ events: [WidgetDayEvent]) -> [WidgetDayEvent] {
        let limit = family == .systemLarge ? 7 : 3
        guard events.count > limit else { return events }
        let firstRelevant = events.firstIndex { $0.isAllDay || $0.endDate > entry.date } ?? 0
        return Array(events[firstRelevant...].prefix(limit))
    }

    @ViewBuilder
    private var dueSoonFooter: some View {
        let deadlines = entry.snapshot.upcomingDeadlines(after: entry.date).prefix(2)
        if !deadlines.isEmpty {
            Divider()
            SectionHeader(title: "Due Soon", accent: entry.snapshot.accentColor)
            ForEach(Array(deadlines)) { deadline in
                DeadlineRow(deadline: deadline, now: entry.date)
            }
        }
    }
}

// MARK: - Due Soon

struct DeadlinesWidgetView: View {
    let entry: ScheduleEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride
    private var family: WidgetFamily { familyOverride ?? systemFamily }

    private var deadlines: [WidgetDeadline] { entry.snapshot.upcomingDeadlines(after: entry.date) }

    var body: some View {
        if family == .accessoryRectangular {
            rectangular
        } else {
            WidgetChrome(snapshot: entry.snapshot, url: WidgetLinks.tasks) {
                switch family {
                case .systemSmall: small
                default: list
                }
            }
        }
    }

    private var weekCount: Int {
        let weekEnd = entry.date.addingTimeInterval(7 * 86_400)
        return deadlines.filter { $0.dueDate <= weekEnd }.count
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Due Soon", accent: entry.snapshot.accentColor)
            if let first = deadlines.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(weekCount)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.snapshot.accentColor)
                        .widgetAccentable()
                    Text("this week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(first.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text("\(first.courseCode.isEmpty ? "" : first.courseCode + " · ")\(WidgetFormat.dueLabel(first.dueDate, now: entry.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                allClear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        let limit = family == .systemLarge ? 9 : 3
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 7) {
            SectionHeader(title: "Due Soon", accent: entry.snapshot.accentColor, trailing: weekCount > 0 ? "\(weekCount) this week" : nil)
            if deadlines.isEmpty {
                allClear
            } else {
                ForEach(deadlines.prefix(limit)) { deadline in
                    DeadlineRow(deadline: deadline, now: entry.date)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let first = deadlines.first {
                Text(first.title)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Text("\(first.courseCode.isEmpty ? "Due" : first.courseCode) · \(WidgetFormat.dueLabel(first.dueDate, now: entry.date))")
                    .font(.caption)
                    .lineLimit(1)
                if deadlines.count > 1 {
                    Text("+\(deadlines.count - 1) more due")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("All caught up")
                    .font(.headline)
                Text("Nothing due soon")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetLinks.tasks)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var allClear: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.headline)
            Text("Nothing due in the next three weeks")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let month: MonthSnapshot
    let accent: Color
    var cellHeight: CGFloat
    var fontSize: CGFloat
    var dotSize: CGFloat = 4
    var showsWeekdays = true

    var body: some View {
        let leadingBlanks = (month.firstWeekday - 2 + 7) % 7
        let rows = Int(ceil(Double(leadingBlanks + month.daysInMonth) / 7.0))
        let markers = Dictionary(month.markers.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })

        VStack(spacing: 2) {
            if showsWeekdays {
                HStack(spacing: 0) {
                    ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: fontSize - 1, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let day = row * 7 + column - leadingBlanks + 1
                        if day >= 1 && day <= month.daysInMonth {
                            dayCell(day, marker: markers[day])
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Int, marker: DayMarker?) -> some View {
        let isToday = month.todayDay == day
        let dots = Array((marker?.dotColors ?? []).prefix(3))
        return VStack(spacing: 1) {
            Text("\(day)")
                .font(.system(size: fontSize, weight: isToday ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : (marker?.isBreakDay == true ? Color.orange : Color.primary))
                .frame(width: fontSize * 1.9, height: fontSize * 1.9)
                .background {
                    if isToday {
                        Circle().fill(accent).widgetAccentable()
                    }
                }
            HStack(spacing: 1.5) {
                if marker?.hasExam == true {
                    Image(systemName: "star.fill")
                        .font(.system(size: dotSize + 1))
                        .foregroundStyle(.orange)
                } else {
                    ForEach(dots.indices, id: \.self) { index in
                        Circle().fill(dots[index].color).frame(width: dotSize, height: dotSize)
                    }
                }
            }
            .frame(height: dotSize + 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
    }
}

private func monthTitle(_ month: MonthSnapshot) -> String {
    let date = Calendar.current.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
    return date.formatted(.dateTime.month(.wide))
}

struct MonthWidgetView: View {
    let entry: ScheduleEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetFamilyOverride) private var familyOverride
    private var family: WidgetFamily { familyOverride ?? systemFamily }

    private var month: MonthSnapshot { entry.snapshot.month }
    private var accent: Color { entry.snapshot.accentColor }

    var body: some View {
        WidgetChrome(snapshot: entry.snapshot) {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 2) {
                    Text(monthTitle(month).uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .widgetAccentable()
                    MonthGrid(month: month, accent: accent, cellHeight: 17, fontSize: 9, dotSize: 3)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(monthTitle(month))
                            .font(.title3.bold())
                        Text(String(month.year))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    MonthGrid(month: month, accent: accent, cellHeight: 30, fontSize: 13, dotSize: 4)
                    Divider()
                    let today = entry.snapshot.events(on: entry.date).filter { $0.isAllDay || $0.endDate > entry.date }.prefix(3)
                    if today.isEmpty {
                        Text("Nothing else today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(today)) { event in
                        AgendaRow(event: event, now: entry.date)
                    }
                    Spacer(minLength: 0)
                }
            default:
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monthTitle(month).uppercased())
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(accent)
                            .widgetAccentable()
                        Text(entry.date.formatted(.dateTime.day()))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                        Text(entry.date.formatted(.dateTime.weekday(.wide)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        let count = entry.snapshot.events(on: entry.date).filter { !$0.isAllDay }.count
                        Text(count == 0 ? "No classes" : "\(count) \(count == 1 ? "class" : "classes")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 92, alignment: .leading)
                    MonthGrid(month: month, accent: accent, cellHeight: 20, fontSize: 10, dotSize: 3)
                }
            }
        }
    }
}

struct MonthAndTodayWidgetView: View {
    let entry: ScheduleEntry

    var body: some View {
        let accent = entry.snapshot.accentColor
        WidgetChrome(snapshot: entry.snapshot, url: WidgetLinks.day(entry.date)) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .widgetAccentable()
                    let events = entry.snapshot.events(on: entry.date).filter { $0.isAllDay || $0.endDate > entry.date }
                    if events.isEmpty {
                        Spacer(minLength: 0)
                        Text("Nothing else today")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    } else {
                        ForEach(Array(events.prefix(3))) { event in
                            AgendaRow(event: event, now: entry.date, showsLocation: false)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(monthTitle(entry.snapshot.month).uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                    MonthGrid(month: entry.snapshot.month, accent: accent, cellHeight: 17, fontSize: 9, dotSize: 3)
                }
                .frame(width: 148)
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

// MARK: - Previews

#Preview("Up Next", as: .systemSmall) {
    RPICentralUpNextWidget()
} timeline: {
    ScheduleEntry(date: Date(), snapshot: WidgetSnapshotStore.sample(now: Date()))
}

#Preview("Today", as: .systemLarge) {
    RPICentralTodayWidget()
} timeline: {
    ScheduleEntry(date: Date(), snapshot: WidgetSnapshotStore.sample(now: Date()))
}
