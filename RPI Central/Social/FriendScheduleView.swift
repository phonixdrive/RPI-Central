//
//  FriendScheduleView.swift
//  RPI Central
//

import SwiftUI

struct FriendSchedulePresentation: Identifiable {
    let friend: SocialFriend
    let cachedResponse: FriendScheduleResponse?

    var id: String {
        "\(friend.id)|\(friend.lastScheduleAt ?? "none")"
    }
}

struct FriendScheduleLoadingView: View {
    let presentation: FriendSchedulePresentation

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var response: FriendScheduleResponse?
    @State private var didFinishLoading = false

    init(presentation: FriendSchedulePresentation) {
        self.presentation = presentation
        _response = State(initialValue: presentation.cachedResponse)
    }

    var body: some View {
        Group {
            if let response {
                FriendScheduleView(response: response)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if didFinishLoading {
                            Image(systemName: "exclamationmark.calendar")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(calendarViewModel.themeColor)

                            Text("Couldn’t load this schedule")
                                .font(.headline)

                            Text(socialManager.errorMessage ?? "Please check your connection and try again.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button("Try Again") {
                                Task { await loadSchedule() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView()
                                .controlSize(.large)

                            Text("Loading \(presentation.friend.displayName)’s calendar")
                                .font(.headline)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle(presentation.friend.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task(id: presentation.id) {
            guard response == nil else { return }
            await loadSchedule()
        }
    }

    private func loadSchedule() async {
        didFinishLoading = false
        let loaded = await socialManager.loadFriendSchedule(friendID: presentation.friend.id)
        guard !Task.isCancelled else { return }
        response = loaded
        didFinishLoading = true
    }
}

private struct FriendScheduleView: View {
    let response: FriendScheduleResponse
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var preparedData: FriendSchedulePreparedData?
    @State private var isPreparing = false
    @State private var selectedDate: Date = Date()
    @State private var displayedMonth: Date = FriendScheduleCalendar.startOfMonth(for: Date())

    private var selectedDateItems: [ParsedScheduleItem] {
        preparedData?.cache.items(on: selectedDate) ?? []
    }

    private var monthTitle: String {
        FriendScheduleFormatters.month.string(from: displayedMonth)
    }

    private var isCoverageExpired: Bool {
        response.schedule.coverageEndDate.map { $0 < Date() } ?? false
    }

    /// "Through Dec 17 · updated 1 hr. ago"
    private var coverageText: String? {
        let through = response.schedule.coverageEndDate.map {
            "Through \($0.formatted(.dateTime.month(.abbreviated).day()))"
        }
        let updated = response.schedule.generatedAt
            .flatMap { FriendScheduleFormatters.iso.date(from: $0) }
            .map { "updated \(RelativeTimeText.since($0).lowercased())" }
        let parts = [through, updated].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        SocialAvatar(id: response.owner.id, name: response.owner.displayName)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(response.owner.username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let coverageText {
                                Text(coverageText)
                                    .font(.caption)
                                    .foregroundStyle(isCoverageExpired ? Color.orange : Color.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    if let preparedData {
                        SocialCard(
                            background: Color.black.opacity(0.88),
                            stroke: calendarViewModel.themeColor.opacity(0.22)
                        ) {
                            VStack(spacing: 14) {
                                HStack {
                                    Button {
                                        shiftMonth(by: -1)
                                    } label: {
                                        Image(systemName: "chevron.left")
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Text(monthTitle)
                                        .font(.headline)
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Button {
                                        shiftMonth(by: 1)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                FriendScheduleMonthGrid(
                                    displayedMonth: displayedMonth,
                                    selectedDate: selectedDate,
                                    cache: preparedData.cache,
                                    accent: calendarViewModel.themeColor
                                ) { day in
                                    selectedDate = day
                                }
                            }
                        }

                        SocialCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(FriendScheduleFormatters.selectedDayHeader.string(from: selectedDate))
                                    .font(.headline)

                                if selectedDateItems.isEmpty {
                                    Text(emptyDayMessage)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    LazyVStack(spacing: 10) {
                                        ForEach(selectedDateItems) { item in
                                            FriendScheduleEventRow(item: item, accent: calendarViewModel.themeColor)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        SocialCard {
                            HStack(spacing: 12) {
                                ProgressView()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Loading shared schedule")
                                        .font(.headline)
                                    Text("Optimizing the calendar for this device.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(response.owner.displayName)
            .task(id: response.owner.id) {
                await prepareScheduleIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Distinguishes a free day from a day the friend's app never published.
    private var emptyDayMessage: String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selectedDate)
        if let coverageEnd = response.schedule.coverageEndDate,
           day > calendar.startOfDay(for: coverageEnd) {
            return "\(response.owner.displayName)'s shared schedule ends \(coverageEnd.formatted(date: .abbreviated, time: .omitted)). It extends automatically the next time their app syncs."
        }
        if let coverageStart = response.schedule.coverageStart.flatMap(SharedScheduleDates.parse),
           day < calendar.startOfDay(for: coverageStart) {
            return "Older days aren't shared."
        }
        return "Nothing scheduled this day."
    }

    private func shiftMonth(by value: Int) {
        let nextMonth = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
        displayedMonth = FriendScheduleCalendar.startOfMonth(for: nextMonth)
    }

    private func prepareScheduleIfNeeded() async {
        guard preparedData == nil, !isPreparing else { return }
        isPreparing = true

        let schedule = response.schedule
        let prepared = await withCheckedContinuation { (continuation: CheckedContinuation<FriendSchedulePreparedData, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FriendSchedulePreparedData(schedule: schedule))
            }
        }

        preparedData = prepared
        selectedDate = prepared.anchorDate
        displayedMonth = FriendScheduleCalendar.startOfMonth(for: prepared.anchorDate)
        isPreparing = false
    }
}

private struct FriendSchedulePreparedData {
    let cache: FriendScheduleCache
    let anchorDate: Date

    init(schedule: SharedScheduleSnapshot) {
        let items = schedule.items
            .compactMap { ParsedScheduleItem(item: $0) }
            .sorted { $0.startDate < $1.startDate }
        self.cache = FriendScheduleCache(items: items)
        self.anchorDate = Date()
    }
}

private struct ParsedScheduleItem: Identifiable {
    let id: String
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let kind: String
    let badge: String?
    let markerStyle: FriendScheduleMarkerStyle

    var isExam: Bool {
        badge?.lowercased() == "exam"
    }

    var formattedTime: String {
        if isAllDay {
            return "All day"
        }
        let start = FriendScheduleFormatters.time.string(from: startDate)
        let end = FriendScheduleFormatters.time.string(from: endDate)
        return "\(start) - \(end)"
    }

    init?(item: SharedScheduleItem) {
        guard let startDate = FriendScheduleFormatters.iso.date(from: item.startDate),
              let endDate = FriendScheduleFormatters.iso.date(from: item.endDate) else {
            return nil
        }

        self.id = item.id
        self.title = item.title
        self.location = item.location
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = item.isAllDay
        self.kind = item.kind
        self.badge = item.badge
        self.markerStyle = FriendScheduleMarkerStyle(kind: item.kind)
    }
}

private struct FriendScheduleMonthGrid: View {
    let displayedMonth: Date
    let selectedDate: Date
    let cache: FriendScheduleCache
    let accent: Color
    let onSelectDay: (Date) -> Void

    var body: some View {
        let calendar = FriendScheduleCalendar.calendar
        let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) ?? DateInterval()
        let start = monthInterval.start
        let range: Range<Int> = calendar.range(of: .day, in: .month, for: start) ?? (1..<32)
        let leadingBlanks = FriendScheduleCalendar.leadingBlankCount(for: start)
        let totalCells = leadingBlanks + range.count
        let rows = Int(ceil(Double(totalCells) / 7.0))
        let today = Date()

        VStack(spacing: 4) {
            HStack {
                ForEach(FriendScheduleCalendar.shortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        let dayNumber = index - leadingBlanks + 1

                        if dayNumber < 1 || dayNumber > range.count {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                        } else {
                            let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: start) ?? start
                            let summary = cache.summary(on: date)
                            FriendScheduleDayCell(
                                date: date,
                                monthStart: displayedMonth,
                                isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                                isToday: calendar.isDate(date, inSameDayAs: today),
                                summary: summary,
                                accent: accent
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectDay(date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct FriendScheduleDayCell: View {
    let date: Date
    let monthStart: Date
    let isSelected: Bool
    let isToday: Bool
    let summary: FriendScheduleDaySummary
    let accent: Color

    var body: some View {
        let calendar = Calendar.current
        let inMonth = calendar.isDate(date, equalTo: monthStart, toGranularity: .month)
        let hasBreakDay = summary.markerStyles.contains(.breakDay)

        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.black
                            : (inMonth ? Color.white : Color.white.opacity(0.38))
                    )

                if summary.hasExam {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isSelected ? Color.black : Color.yellow)
                }
            }
            .frame(maxWidth: .infinity)

            if summary.markerStyles.isEmpty {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 5, height: 5)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(summary.markerStyles.prefix(3).enumerated()), id: \.offset) { pair in
                        Circle()
                            .fill(pair.element.color(accent: accent))
                            .frame(width: 5, height: 5)
                    }

                    if summary.itemCount > summary.markerStyles.count {
                        Text("+")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(isSelected ? Color.black : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(5)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(
            Group {
                if isSelected {
                    Color.white
                } else if hasBreakDay {
                    Color.orange.opacity(0.22)
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.clear
                        : (isToday ? Color.white.opacity(0.9) : Color.clear),
                    lineWidth: 1.6
                )
        )
        .cornerRadius(7)
    }
}

private enum FriendScheduleMarkerStyle: Hashable {
    case classMeeting
    case assignment
    case holiday
    case breakDay
    case readingDays
    case finals
    case noClasses
    case followDay
    case academicOther
    case personal

    init(kind: String) {
        switch kind {
        case "classMeeting":
            self = .classMeeting
        case "assignment":
            self = .assignment
        case "holiday":
            self = .holiday
        case "break":
            self = .breakDay
        case "readingDays":
            self = .readingDays
        case "finals":
            self = .finals
        case "noClasses":
            self = .noClasses
        case "followDay":
            self = .followDay
        case "academicOther", "academic":
            self = .academicOther
        default:
            self = .personal
        }
    }

    func color(accent: Color) -> Color {
        switch self {
        case .classMeeting:
            return accent
        case .assignment:
            return .blue
        case .holiday:
            return .red
        case .breakDay:
            return .orange
        case .readingDays:
            return .blue
        case .finals:
            return .purple
        case .noClasses:
            return .gray
        case .followDay:
            return .teal
        case .academicOther:
            return .yellow
        case .personal:
            return accent.opacity(0.7)
        }
    }

    func labelText(isExam: Bool) -> String {
        switch self {
        case .classMeeting:
            return isExam ? "Class + Exam" : "Class"
        case .assignment:
            return "Assignment"
        case .holiday:
            return "Holiday"
        case .breakDay:
            return "Break"
        case .readingDays:
            return "Reading Days"
        case .finals:
            return "Finals"
        case .noClasses:
            return "No Classes"
        case .followDay:
            return "Follow Day"
        case .academicOther:
            return "Academic"
        case .personal:
            return "Personal"
        }
    }
}

private struct FriendScheduleEventRow: View {
    let item: ParsedScheduleItem
    let accent: Color

    private var indicatorColor: Color {
        item.markerStyle.color(accent: accent)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(indicatorColor.opacity(0.18))
                .frame(width: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(indicatorColor)
                        .frame(width: 4)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title)
                        .font(.headline)

                    if item.isExam {
                        Label("Exam", systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(item.formattedTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.markerStyle.labelText(isExam: item.isExam))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(indicatorColor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}

private struct FriendScheduleCache {
    let items: [ParsedScheduleItem]
    private let itemsByDayKey: [String: [ParsedScheduleItem]]
    private let summaryByDayKey: [String: FriendScheduleDaySummary]

    init(items: [ParsedScheduleItem]) {
        self.items = items

        var grouped: [String: [ParsedScheduleItem]] = [:]
        var summaries: [String: FriendScheduleDaySummary] = [:]
        let calendar = FriendScheduleCalendar.calendar

        for item in items {
            // Multi-day all-day items (breaks, finals) belong on every day
            // they cover, not just the first.
            var day = calendar.startOfDay(for: item.startDate)
            let lastDay = item.isAllDay
                ? calendar.startOfDay(for: max(item.startDate, item.endDate))
                : day
            var coveredDays = 0

            while day <= lastDay && coveredDays < 60 {
                let key = FriendScheduleFormatters.dayKey.string(from: day)
                grouped[key, default: []].append(item)

                var summary = summaries[key] ?? FriendScheduleDaySummary(itemCount: 0, hasExam: false, markerStyles: [])
                summary.itemCount += 1
                summary.hasExam = summary.hasExam || item.isExam
                if !summary.markerStyles.contains(item.markerStyle) {
                    summary.markerStyles.append(item.markerStyle)
                }
                summaries[key] = summary

                coveredDays += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        self.itemsByDayKey = grouped
        self.summaryByDayKey = summaries
    }

    func items(on date: Date) -> [ParsedScheduleItem] {
        itemsByDayKey[dayKey(for: date)] ?? []
    }

    func summary(on date: Date) -> FriendScheduleDaySummary {
        summaryByDayKey[dayKey(for: date)] ?? FriendScheduleDaySummary(itemCount: 0, hasExam: false, markerStyles: [])
    }

    private func dayKey(for date: Date) -> String {
        FriendScheduleFormatters.dayKey.string(from: FriendScheduleCalendar.calendar.startOfDay(for: date))
    }
}

private struct FriendScheduleDaySummary {
    var itemCount: Int
    var hasExam: Bool
    var markerStyles: [FriendScheduleMarkerStyle]
}

private enum FriendScheduleCalendar {
    static let calendar = Calendar.current

    static var shortWeekdaySymbols: [String] {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }

    static func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func leadingBlankCount(for monthStart: Date) -> Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - 2 + 7) % 7
    }
}

private enum FriendScheduleFormatters {
    static let iso = ISO8601DateFormatter()

    static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let selectedDayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}
