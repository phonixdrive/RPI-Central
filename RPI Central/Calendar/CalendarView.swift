// CalendarView.swift
// RPI Central

import SwiftUI

// MARK: - Display modes

enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case day
    case threeDay
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:      return "Day"
        case .threeDay: return "3 day"
        case .week:     return "Week"
        case .month:    return "Month"
        }
    }
}

fileprivate enum CalendarChrome {
    static func backgroundGradient(theme: Color) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(.systemGroupedBackground),
                theme.opacity(0.14),
                Color(.systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func surface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.secondarySystemBackground).opacity(0.94)
            : Color(.systemBackground).opacity(0.96)
    }

    static func elevatedSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.tertiarySystemBackground).opacity(0.88)
            : Color.white.opacity(0.86)
    }

    static func line(_ colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.10)
    }

    static func primaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .primary
    }

    static func secondaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : .secondary
    }

    static func selectedFill(theme: Color, colorScheme: ColorScheme) -> Color {
        theme.opacity(colorScheme == .dark ? 0.28 : 0.16)
    }

    static func selectedText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .primary
    }
}

struct CalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("calendar_display_mode_v1") private var displayMode: CalendarDisplayMode = .week

    // ✅ Add-event sheet
    @State private var showingAddEvent: Bool = false

    var body: some View {
        ZStack {
            CalendarChrome.backgroundGradient(theme: viewModel.themeColor).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Rectangle()
                    .fill(CalendarChrome.line(colorScheme))
                    .frame(height: 1)
                content
            }
            // ✅ Keep your background swipe navigation (overlap stacks use highPriorityGesture)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) else { return }
                        if dx < 0 {
                            withAnimation(.easeInOut(duration: 0.25)) { shift(by: 1) }
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) { shift(by: -1) }
                        }
                    },
                including: .gesture
            )
            .task {
                // Loading happens in place so the calendar and tab bar remain interactive.
                viewModel.ensureAcademicEventsLoaded(for: viewModel.currentSemester)
                viewModel.ensureTermBoundsForAllEnrollments()
                viewModel.ensureTermBoundsLoaded(for: viewModel.currentSemester)
            }
            .onChange(of: viewModel.currentSemester) { _, newSem in
                viewModel.ensureAcademicEventsLoaded(for: newSem)
                viewModel.ensureTermBoundsLoaded(for: newSem)
            }
            .onChange(of: viewModel.enrolledCourses) { _, _ in
                viewModel.ensureTermBoundsForAllEnrollments()
            }
            .sheet(isPresented: $showingAddEvent) {
                AddEventView(date: viewModel.selectedDate, isPresented: $showingAddEvent)
                    .environmentObject(viewModel)
                    .environmentObject(socialManager)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.25)) { shift(by: -1) } } label: {
                Image(systemName: "chevron.left")
            }

            monthPicker

            Spacer()
            
            //Add event button(restored)
            Button(action: { showingAddEvent = true }) {
                      Image(systemName: "plus.circle.fill")
                          .font(.title3)
                  }
                  .accessibilityLabel("Add event")

            // ✅ TODAY button
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.goToToday()
                }
            } label: {
                Image(systemName: "scope")
                    .font(.title3)
            }
            .accessibilityLabel("Today")

            Menu {
                ForEach(CalendarDisplayMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { displayMode = mode }
                    } label: {
                        if mode == displayMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(displayMode.title)
                    Image(systemName: "chevron.down")
                }
            }

            Button { withAnimation(.easeInOut(duration: 0.25)) { shift(by: 1) } } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundColor(CalendarChrome.primaryText(colorScheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            CalendarChrome.surface(colorScheme)
                .overlay(
                    LinearGradient(
                        colors: [
                            viewModel.themeColor.opacity(colorScheme == .dark ? 0.22 : 0.10),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var monthPicker: some View {
        let cal = Calendar.current
        let current = viewModel.selectedDate

        // ✅ Use semester-window month starts when available
        let monthStarts = viewModel.monthPickerMonthStarts()

        return Menu {
            // Group by year for readability
            let grouped = Dictionary(grouping: monthStarts, by: { cal.component(.year, from: $0) })
            let years = grouped.keys.sorted()

            ForEach(years, id: \.self) { year in
                Section("Year \(year)") {
                    let months = (grouped[year] ?? []).sorted()
                    ForEach(months, id: \.self) { monthStart in
                        Button {
                            viewModel.setSelectedDate(monthStart)
                        } label: {
                            Text(monthTitle(for: monthStart))
                        }
                    }
                }
            }

        } label: {
            // "September 2026", or "Sep 2026" when the header is tight.
            ViewThatFits(in: .horizontal) {
                Text(monthTitle(for: current))
                Text(monthTitle(for: current, abbreviated: true))
            }
            .font(.title2.bold())
            .lineLimit(1)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .day:
            TimelineCalendarView(days: [viewModel.selectedDate], displayMode: displayMode)
                .environmentObject(viewModel)

        case .threeDay:
            TimelineCalendarView(days: daysFrom(selected: viewModel.selectedDate, count: 3), displayMode: displayMode)
                .environmentObject(viewModel)

        case .week:
            TimelineCalendarView(days: weekdaysOfCurrentWeek(from: viewModel.selectedDate), displayMode: displayMode)
                .environmentObject(viewModel)

        case .month:
            MonthWithScheduleView()
                .environmentObject(viewModel)
        }
    }

    // MARK: - Date helpers

    private func monthTitle(for date: Date, abbreviated: Bool = false) -> String {
        date.formatted(.dateTime.month(abbreviated ? .abbreviated : .wide).year())
    }

    private func shift(by offset: Int) {
        let cal = Calendar.current
        switch displayMode {
        case .day:
            if let newDate = cal.date(byAdding: .day, value: offset, to: viewModel.selectedDate) {
                viewModel.setSelectedDate(newDate)
            }
        case .threeDay:
            if let newDate = cal.date(byAdding: .day, value: 3 * offset, to: viewModel.selectedDate) {
                viewModel.setSelectedDate(newDate)
            }
        case .week:
            if let newDate = cal.date(byAdding: .weekOfYear, value: offset, to: viewModel.selectedDate) {
                viewModel.setSelectedDate(newDate)
            }
        case .month:
            if let newDate = cal.date(byAdding: .month, value: offset, to: viewModel.selectedDate) {
                viewModel.setSelectedDate(newDate)
            }
        }
    }

    private func daysFrom(selected: Date, count: Int) -> [Date] {
        let cal = Calendar.current
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: selected) }
    }

    private func weekdaysOfCurrentWeek(from date: Date) -> [Date] {
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let sunday = weekInterval.start
        return (1...5).compactMap { cal.date(byAdding: .day, value: $0, to: sunday) }
    }
}

// MARK: - Timeline (Day / 3-day / Week views)

struct TimelineCalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @Environment(\.colorScheme) private var colorScheme

    let days: [Date]
    let displayMode: CalendarDisplayMode

    @State private var selection: EventDetailSelection?

    // Overlap stacks: groupKey -> interactionKey of the card on top.
    @State private var topEventKeyByGroup: [String: String] = [:]

    // ✅ all-day “show all” sheet
    @State private var showAllDaySheet: Bool = false
    @State private var allDaySheetTitle: String = ""
    @State private var allDaySheetEvents: [ClassEvent] = []

    // ✅ LIVE now time (forces re-render)
    @State private var now: Date = Date()
    private let nowTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let calendar = Calendar.current
    private let dayStartHour = 7
    private let dayEndHour = 24
    private let rowHeight: CGFloat = 60
    private let timeColWidth: CGFloat = 56

    private var totalMinutes: Int { (dayEndHour - dayStartHour) * 60 }

    var body: some View {
        let intervalCount = dayEndHour - dayStartHour
        let today = now   // ✅ use live clock, not frozen Date()

        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                Text("").frame(width: timeColWidth)

                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDate(day, inSameDayAs: today)

                    VStack(spacing: 2) {
                        Text(day.formatted("EEE"))
                            .font(.subheadline.bold())
                            .foregroundColor(isToday ? viewModel.themeColor : CalendarChrome.primaryText(colorScheme))

                        Text(day.formatted("MM/dd"))
                            .font(.caption)
                            .foregroundColor(
                                isToday
                                    ? CalendarChrome.selectedText(colorScheme)
                                    : CalendarChrome.secondaryText(colorScheme)
                            )
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isToday ? CalendarChrome.selectedFill(theme: viewModel.themeColor, colorScheme: colorScheme) : Color.clear)
                    )
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

            Divider()

            // All-day strip
            let anyAllDay = days.contains { !viewModel.events(on: $0).filter(\.isAllDay).isEmpty }
            if anyAllDay {
                HStack(alignment: .top, spacing: 0) {
                    Text("All day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: timeColWidth, alignment: .leading)
                        .padding(.leading, 6)

                    ForEach(days, id: \.self) { day in
                        let allDayEvents = viewModel.events(on: day).filter(\.isAllDay)

                        VStack(alignment: .leading, spacing: 4) {
                            if allDayEvents.isEmpty {
                                Text("").frame(height: 1)
                            } else {
                                ForEach(allDayEvents.prefix(2)) { ev in
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(ev.displayColor)
                                            .frame(width: 6, height: 6)
                                        Text(ev.title)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .foregroundColor(CalendarChrome.primaryText(colorScheme))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(CalendarChrome.elevatedSurface(colorScheme))
                                    .cornerRadius(6)
                                }

                                if allDayEvents.count > 2 {
                                    Text("+\(allDayEvents.count - 2) more")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !allDayEvents.isEmpty else { return }
                            allDaySheetTitle = day.formatted("EEEE, MMM d")
                            allDaySheetEvents = allDayEvents
                            showAllDaySheet = true
                        }
                    }
                }
                Divider()
            }

            ScrollView {
                // ✅ IMPORTANT: compute this OUTSIDE the GeometryReader
                // so we can give the GeometryReader a real content height (otherwise scrolling bounces back)
                let totalHeight = CGFloat(intervalCount) * rowHeight

                GeometryReader { geo in
                    let gridLeftX = timeColWidth
                    let gridRightX = geo.size.width
                    let dayWidth = (gridRightX - gridLeftX) / CGFloat(max(days.count, 1))

                    ZStack(alignment: .topLeading) {

                        // ✅ grid horizontal lines
                        ForEach(0...intervalCount, id: \.self) { idx in
                            let y = CGFloat(idx) * rowHeight

                            Path { path in
                                path.move(to: CGPoint(x: gridLeftX, y: y))
                                path.addLine(to: CGPoint(x: gridRightX, y: y))
                            }
                            .stroke(CalendarChrome.line(colorScheme), lineWidth: 1.1)

                            if idx < intervalCount {
                                let hour = dayStartHour + idx
                                Text(hourLabel(hour))
                                    .font(.caption)
                                    .foregroundColor(CalendarChrome.secondaryText(colorScheme))
                                    .position(x: gridLeftX - 26, y: y + 8)
                            }
                        }

                        // ✅ grid vertical lines (multi-day)
                        if days.count > 1 {
                            ForEach(1..<days.count, id: \.self) { col in
                                let x = gridLeftX + dayWidth * CGFloat(col)
                                Path { path in
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: totalHeight))
                                }
                                .stroke(CalendarChrome.line(colorScheme), lineWidth: 1.1)
                            }
                        }

                        // Timed events, one overlap group at a time.
                        ForEach(Array(days.enumerated()), id: \.1) { (colIndex, day) in
                            let timed = viewModel.events(on: day).filter { !$0.isAllDay }
                            let groups = overlapGroups(timed)

                            ForEach(groups.indices, id: \.self) { gi in
                                let group = groups[gi]
                                let columnLeft = gridLeftX + dayWidth * CGFloat(colIndex)
                                let eventWidth = max(dayWidth - 8, 0)
                                let groupKey = makeGroupKey(day: day, group: group)
                                let lanes = OverlapLayout.lanes(for: group)
                                let laneCount = (lanes.values.max() ?? 0) + 1
                                let laneWidth = eventWidth / CGFloat(max(laneCount, 1))

                                if group.count == 1 || laneWidth >= OverlapLayout.minimumLaneWidth {
                                    // Enough room: overlapping classes sit side by side.
                                    ForEach(group, id: \.interactionKey) { ev in
                                        if let r = rectForEvent(ev, totalHeight: totalHeight) {
                                            let lane = CGFloat(lanes[ev.interactionKey] ?? 0)
                                            let gap: CGFloat = laneCount > 1 ? 2 : 0
                                            eventChip(ev, compact: laneCount > 1)
                                                .frame(width: max(laneWidth - gap, 0), height: r.height)
                                                .position(
                                                    x: columnLeft + 4 + laneWidth * lane + laneWidth / 2,
                                                    y: r.minY + r.height / 2
                                                )
                                                .onTapGesture { openDetail(group: group, startingAt: ev) }
                                                .contextMenu { chipMenu(for: ev) }
                                        }
                                    }
                                } else {
                                    overlapStack(
                                        groupKey: groupKey,
                                        group: group,
                                        width: eventWidth,
                                        columnLeft: columnLeft,
                                        totalHeight: totalHeight
                                    )
                                }
                            }
                        }

                        // ✅ NOW LINE MUST BE LAST so it draws ON TOP
                        if displayMode == .day || displayMode == .threeDay || displayMode == .week {
                            if let nowY = nowLineY(totalHeight: totalHeight, now: now) {
                                Path { path in
                                    path.move(to: CGPoint(x: gridLeftX, y: nowY))
                                    path.addLine(to: CGPoint(x: gridRightX, y: nowY))
                                }
                                .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .zIndex(999)

                                Text("Now")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .position(x: gridLeftX - 20, y: nowY)
                                    .zIndex(999)
                            }
                        }
                    }
                    .frame(height: totalHeight)
                }
                // ✅ THIS is the actual fix: GeometryReader must have the full content height
                .frame(height: totalHeight)
            }
        }
        .onReceive(nowTimer) { t in
            now = t
        }
        .sheet(item: $selection) { selection in
            EventDetailPager(selection: selection)
                .environmentObject(viewModel)
                .environmentObject(socialManager)
        }
        .sheet(isPresented: $showAllDaySheet) {
            AllDayEventsListView(title: allDaySheetTitle, events: allDaySheetEvents)
                .environmentObject(viewModel)
                .environmentObject(socialManager)
        }
    }

    // MARK: - Context menu actions

    @ViewBuilder
    private func chipMenu(for event: ClassEvent) -> some View {
        if event.isAllDay {
            Button(role: .destructive) {
                viewModel.hideAllDayEvent(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Hide all-day event", systemImage: "eye.slash")
            }
        }

        if event.kind == .personal {
            Button(role: .destructive) {
                viewModel.removePersonalEvent(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Remove event", systemImage: "trash")
            }

            if let sid = event.seriesID {
                Button(role: .destructive) {
                    viewModel.removePersonalSeries(seriesID: sid)
                    syncSharedScheduleIfNeeded()
                } label: {
                    Label("Remove recurrence", systemImage: "trash.slash")
                }
            }
        }

        if event.kind == .classMeeting {
            Button(role: .destructive) {
                viewModel.hideClassOccurrence(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Hide this occurrence", systemImage: "eye.slash")
            }

            if let id = event.enrollmentID,
               let enrollment = viewModel.enrolledCourses.first(where: { $0.id == id }) {
                Button(role: .destructive) {
                    viewModel.removeEnrollment(enrollment)
                    syncSharedScheduleIfNeeded()
                } label: {
                    Label("Remove course from calendar", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Overlap grouping (timed events)

    private func overlapGroups(_ events: [ClassEvent]) -> [[ClassEvent]] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var groups: [[ClassEvent]] = []
        var cur: [ClassEvent] = []
        var curEnd: Date?

        for e in sorted {
            if cur.isEmpty {
                cur = [e]
                curEnd = e.endDate
                continue
            }
            if let ce = curEnd, e.startDate < ce {
                cur.append(e)
                if e.endDate > ce { curEnd = e.endDate }
            } else {
                groups.append(cur)
                cur = [e]
                curEnd = e.endDate
            }
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups
    }

    private func makeGroupKey(day: Date, group: [ClassEvent]) -> String {
        let dayKey = day.formatted("yyyy-MM-dd")
        let ids = group.map(\.interactionKey).sorted().joined(separator: "|")
        return "\(dayKey)||\(ids)"
    }

    private func rotate<T: Equatable>(_ arr: [T], startingAt item: T) -> [T] {
        guard let i = arr.firstIndex(of: item) else { return arr }
        return Array(arr[i...]) + Array(arr[..<i])
    }

    /// Opens the detail pager for a tapped event; overlapping events can be
    /// swiped between.
    private func openDetail(group: [ClassEvent], startingAt event: ClassEvent) {
        let ordered = group.sorted { $0.startDate < $1.startDate }
        let index = ordered.firstIndex { $0.interactionKey == event.interactionKey } ?? 0
        selection = EventDetailSelection(events: ordered, index: index)
    }

    /// Too narrow for side-by-side (week and 3-day views): overlapping events
    /// stack like cards. Swipe the stack to bring the next one to the top, or
    /// tap to open all of them in a swipeable pager.
    @ViewBuilder
    private func overlapStack(
        groupKey: String,
        group: [ClassEvent],
        width: CGFloat,
        columnLeft: CGFloat,
        totalHeight: CGFloat
    ) -> some View {
        let base = group.sorted { $0.startDate < $1.startDate }
        let baseKeys = base.map(\.interactionKey)
        let topKey = topEventKeyByGroup[groupKey].flatMap { baseKeys.contains($0) ? $0 : nil } ?? baseKeys[0]
        let rotatedKeys = rotate(baseKeys, startingAt: topKey)
        let ordered: [ClassEvent] = rotatedKeys.compactMap { key in base.first { $0.interactionKey == key } }
        let rects = ordered.map { rectForEvent($0, totalHeight: totalHeight) }
        let union = rects.compactMap { $0 }.reduce(CGRect?.none) { partial, rect in
            partial.map { CGRect(x: 0, y: min($0.minY, rect.minY), width: 0, height: max($0.maxY, rect.maxY) - min($0.minY, rect.minY)) } ?? rect
        }
        let peek: CGFloat = 4

        if let union {
            ZStack(alignment: .topLeading) {
                // Back cards peek out behind the top one; drawn back to front.
                ForEach(Array(ordered.enumerated()).reversed(), id: \.element.interactionKey) { index, ev in
                    if index < 3, let r = rects[index] {
                        eventChip(ev, compact: true)
                            .frame(width: width - peek * CGFloat(min(ordered.count - 1, 2)), height: r.height)
                            .offset(x: peek * CGFloat(index), y: r.minY - union.minY + peek * CGFloat(index))
                            .opacity(index == 0 ? 1 : 0.85)
                            .allowsHitTesting(index == 0)
                    }
                }
            }
            .frame(width: width, height: union.height + peek * 2, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                Label("\(ordered.count)", systemImage: "square.stack.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(2)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .position(x: columnLeft + 4 + width / 2, y: union.minY + (union.height + peek * 2) / 2)
            .onTapGesture { openDetail(group: base, startingAt: ordered[0]) }
            .contextMenu { chipMenu(for: ordered[0]) }
            // Only this stack's frame handles the swipe, so swiping elsewhere
            // still changes days.
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onEnded { value in
                        let dx = value.translation.width
                        guard abs(dx) > abs(value.translation.height), abs(dx) > 20, rotatedKeys.count > 1 else { return }
                        let newTop = dx < 0 ? rotatedKeys[1] : (rotatedKeys.last ?? topKey)
                        withAnimation(.snappy(duration: 0.2)) {
                            topEventKeyByGroup[groupKey] = newTop
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ordered.map(\.title).joined(separator: ", "))
            .accessibilityHint("\(ordered.count) overlapping events. Opens details.")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Geometry helpers

    private func rectForEvent(_ event: ClassEvent, totalHeight: CGFloat) -> CGRect? {
        let comps = calendar.dateComponents([.hour, .minute], from: event.startDate)
        let endComps = calendar.dateComponents([.hour, .minute], from: event.endDate)

        guard let sh = comps.hour, let sm = comps.minute,
              let eh = endComps.hour, let em = endComps.minute else {
            return nil
        }

        let startMinutes = max(0, (sh - dayStartHour) * 60 + sm)
        let endMinutes   = min(totalMinutes, (eh - dayStartHour) * 60 + em)
        if endMinutes <= startMinutes { return nil }

        let startRatio = CGFloat(startMinutes) / CGFloat(totalMinutes)
        let endRatio   = CGFloat(endMinutes)   / CGFloat(totalMinutes)

        let minY = startRatio * totalHeight
        let maxY = endRatio * totalHeight
        let height = max(24, maxY - minY)

        return CGRect(x: 0, y: minY, width: 0, height: height)
    }

    private func nowLineY(totalHeight: CGFloat, now: Date) -> CGFloat? {
        guard days.contains(where: { calendar.isDate($0, inSameDayAs: now) }) else { return nil }

        let comps = calendar.dateComponents([.hour, .minute], from: now)
        guard let h = comps.hour, let m = comps.minute else { return nil }

        let minutes = (h - dayStartHour) * 60 + m
        if minutes < 0 || minutes > totalMinutes { return nil }

        let ratio = CGFloat(minutes) / CGFloat(totalMinutes)
        return ratio * totalHeight
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let df = DateFormatter()
        df.dateFormat = "h a"
        return df.string(from: calendar.date(from: components) ?? Date())
    }

    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }

    private func syncSharedScheduleIfNeeded() {
        socialManager.requestScheduleSync()
    }

    private func eventChip(_ event: ClassEvent, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(event.accentColor)
                    .frame(width: 4)
                    .cornerRadius(2, corners: [.topLeft, .bottomLeft])

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // Exam meetings are titled "★ …"; the icon below shows the star.
                        Text(event.badge == .exam ? event.title.replacingOccurrences(of: "★ ", with: "") : event.title)
                            .font(.caption2.bold())
                            .foregroundColor(.black)
                            .lineLimit(compact ? 2 : nil)

                        if event.badge == .exam {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }

                    Text(compact ? timeString(event.startDate) : "\(timeString(event.startDate)) – \(timeString(event.endDate))")
                        .font(.caption2)
                        .foregroundColor(.black)
                        .lineLimit(1)

                    if !event.location.isEmpty {
                        Text(event.location)
                            .font(.caption2)
                            .foregroundColor(.black.opacity(0.8))
                            .lineLimit(compact ? 1 : nil)
                    }
                }
                .padding(4)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(event.backgroundColor)
        .cornerRadius(4)
    }
}

// MARK: - Month + schedule view

struct MonthWithScheduleView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    @State private var selectedEvent: ClassEvent?

    var body: some View {
        VStack(spacing: 0) {
            MonthGridView()
                .environmentObject(viewModel)

            Divider()
                .padding(.top, 4)

            let selected = viewModel.selectedDate
            let events = viewModel.events(on: selected)

            List {
                Section {
                    if events.isEmpty {
                        Text("No events for this day.")
                            .foregroundStyle(.secondary)
                    } else {
                        let allDay = events.filter(\.isAllDay)
                        let timed  = events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
                        let merged = allDay + timed

                        ForEach(merged) { event in
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(event.displayColor)
                                    .frame(width: 4)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text(event.title)
                                            .font(.headline)

                                        if event.badge == .exam {
                                            Image(systemName: "star.fill")
                                                .font(.caption)
                                                .foregroundStyle(.yellow)
                                        }
                                    }

                                    Text(timeRangeString(for: event))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    if !event.location.isEmpty {
                                        Text(event.location)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedEvent = event }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                monthSwipeActions(for: event)
                            }
                        }
                    }
                } header: {
                    Text(selected.formatted("EEEE, MMM d"))
                        .font(.headline)
                        .foregroundColor(CalendarChrome.primaryText(colorScheme))
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $selectedEvent) { event in
            ClassEventDetailView(event: event)
                .environmentObject(viewModel)
                .environmentObject(socialManager)
        }
    }

    @ViewBuilder
    private func monthSwipeActions(for event: ClassEvent) -> some View {
        if event.isAllDay {
            Button(role: .destructive) {
                viewModel.hideAllDayEvent(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }

        if event.kind == .personal {
            Button(role: .destructive) {
                viewModel.removePersonalEvent(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Remove", systemImage: "trash")
            }

            if let sid = event.seriesID {
                Button(role: .destructive) {
                    viewModel.removePersonalSeries(seriesID: sid)
                    syncSharedScheduleIfNeeded()
                } label: {
                    Label("Recurrence", systemImage: "trash.slash")
                }
            }
        }

        if event.kind == .classMeeting {
            Button(role: .destructive) {
                viewModel.hideClassOccurrence(event)
                syncSharedScheduleIfNeeded()
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
    }

    private func timeRangeString(for event: ClassEvent) -> String {
        if event.isAllDay {
            let startDay = calendar.startOfDay(for: event.startDate)
            let endDay = calendar.startOfDay(for: event.endDate)

            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none

            if startDay != endDay {
                return "\(df.string(from: startDay)) – \(df.string(from: endDay))"
            }
            return "All day"
        }

        let df = DateFormatter()
        df.timeStyle = .short
        return "\(df.string(from: event.startDate)) – \(df.string(from: event.endDate))"
    }

    private func syncSharedScheduleIfNeeded() {
        socialManager.requestScheduleSync()
    }
}

// MARK: - Month grid (selects viewModel.selectedDate)

struct MonthGridView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    var body: some View {
        let selectedDate = viewModel.selectedDate
        let monthInterval = calendar.dateInterval(of: .month, for: selectedDate) ?? DateInterval()
        let start = monthInterval.start
        let range: Range<Int> = calendar.range(of: .day, in: .month, for: selectedDate) ?? (1..<32)

        let firstWeekday = calendar.component(.weekday, from: start) // 1 = Sunday
        let leadingBlanks = (firstWeekday - 2 + 7) % 7   // Monday=0 ... Sunday=6

        let totalCells = leadingBlanks + range.count
        let rows = Int(ceil(Double(totalCells) / 7.0))

        let today = Date()

        VStack(spacing: 4) {
            HStack {
                ForEach(["Mon","Tue","Wed","Thu","Fri","Sat","Sun"], id: \.self) { label in
                    Text(label)
                        .font(.caption)
                        .foregroundColor(CalendarChrome.secondaryText(colorScheme))
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
                            let dayEvents = viewModel.events(on: date)
                            let isSelected = calendar.isDate(date, inSameDayAs: viewModel.selectedDate)
                            let isToday = calendar.isDate(date, inSameDayAs: today)

                            let isBreakDay = dayEvents.contains { $0.isAllDay && $0.kind == .break }
                            let hasExam = dayEvents.contains { $0.badge == .exam || $0.title.hasPrefix("★") }
                            let dotColors = dotColorsForDayEvents(dayEvents)

                            VStack(spacing: 3) {
                                HStack(spacing: 3) {
                                    Text("\(dayNumber)")
                                        .font(.caption)
                                        .foregroundColor(
                                            isSelected
                                                ? CalendarChrome.selectedText(colorScheme)
                                                : CalendarChrome.primaryText(colorScheme)
                                        )

                                    if hasExam {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(isSelected ? CalendarChrome.selectedText(colorScheme) : Color.yellow)
                                    }
                                }
                                .frame(maxWidth: .infinity)

                                if dotColors.isEmpty {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 5, height: 5)
                                } else {
                                    HStack(spacing: 3) {
                                        ForEach(Array(dotColors.prefix(3).enumerated()), id: \.offset) { pair in
                                            Circle()
                                                .fill(pair.element)
                                                .frame(width: 5, height: 5)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(5)
                            .background(
                                ZStack {
                                    if isSelected {
                                        CalendarChrome.selectedFill(theme: viewModel.themeColor, colorScheme: colorScheme)
                                    } else if isBreakDay {
                                        Color.orange.opacity(0.22)
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .overlay(
                                // ✅ Today highlight (outline)
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(isToday ? viewModel.themeColor.opacity(0.9) : Color.clear, lineWidth: 1.6)
                            )
                            .cornerRadius(7)
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                            .onTapGesture {
                                viewModel.setSelectedDate(date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func dotColorsForDayEvents(_ events: [ClassEvent]) -> [Color] {
        var colors: [Color] = []

        let academic = events
            .filter { $0.isAllDay }
            .sorted { priority($0.kind) < priority($1.kind) }

        let classes = events
            .filter { !$0.isAllDay && $0.kind == .classMeeting }

        let personal = events
            .filter { !$0.isAllDay && $0.kind == .personal }

        for e in academic { colors.append(e.displayColor) }
        for e in classes { colors.append(e.displayColor) }
        for e in personal { colors.append(e.displayColor) }

        var unique: [Color] = []
        for c in colors {
            if unique.contains(where: { $0 == c }) { continue }
            unique.append(c)
        }
        return unique
    }

    private func priority(_ kind: CalendarEventKind) -> Int {
        switch kind {
        case .break:       return 0
        case .holiday:     return 1
        case .readingDays: return 2
        case .finals:      return 3
        case .noClasses:   return 4
        case .followDay:   return 5
        case .academicOther: return 6
        default:           return 9
        }
    }
}

// MARK: - Detail sheet + All-day list + corner radius helper

struct AllDayEventsListView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    let title: String
    let events: [ClassEvent]

    @State private var selectedEvent: ClassEvent?

    var body: some View {
        NavigationStack {
            List {
                ForEach(events) { ev in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ev.displayColor)
                            .frame(width: 4)

                        Text(ev.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEvent = ev }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if ev.isAllDay {
                            Button(role: .destructive) {
                                viewModel.hideAllDayEvent(ev)
                                syncSharedScheduleIfNeeded()
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                        }

                        if ev.kind == .personal {
                            Button(role: .destructive) {
                                viewModel.removePersonalEvent(ev)
                                syncSharedScheduleIfNeeded()
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }

                            if let sid = ev.seriesID {
                                Button(role: .destructive) {
                                    viewModel.removePersonalSeries(seriesID: sid)
                                    syncSharedScheduleIfNeeded()
                                } label: {
                                    Label("Recurrence", systemImage: "trash.slash")
                                }
                            }
                        }

                        if ev.kind == .classMeeting {
                            Button(role: .destructive) {
                                viewModel.hideClassOccurrence(ev)
                                syncSharedScheduleIfNeeded()
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedEvent) { ev in
                ClassEventDetailView(event: ev)
                    .environmentObject(viewModel)
                    .environmentObject(socialManager)
            }
        }
    }

    private func syncSharedScheduleIfNeeded() {
        socialManager.requestScheduleSync()
    }
}

// MARK: - Corner-radius helper

fileprivate extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

fileprivate struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}


// MARK: - Overlap layout

enum OverlapLayout {
    /// Narrower than this, overlapping events stack instead of sharing the column.
    static let minimumLaneWidth: CGFloat = 72

    /// Assigns each event the first lane that is free when it starts.
    static func lanes(for events: [ClassEvent]) -> [String: Int] {
        var laneEnds: [Date] = []
        var result: [String: Int] = [:]
        for event in events.sorted(by: { $0.startDate == $1.startDate ? $0.endDate > $1.endDate : $0.startDate < $1.startDate }) {
            if let lane = laneEnds.firstIndex(where: { $0 <= event.startDate }) {
                laneEnds[lane] = event.endDate
                result[event.interactionKey] = lane
            } else {
                laneEnds.append(event.endDate)
                result[event.interactionKey] = laneEnds.count - 1
            }
        }
        return result
    }
}

// MARK: - Detail pager

struct EventDetailSelection: Identifiable {
    let events: [ClassEvent]
    let index: Int
    var id: String { events.map(\.interactionKey).joined(separator: "|") + "#\(index)" }
}

/// Event details; when events overlap, swipe sideways between them.
struct EventDetailPager: View {
    let selection: EventDetailSelection
    @State private var page: Int

    init(selection: EventDetailSelection) {
        self.selection = selection
        _page = State(initialValue: selection.index)
    }

    var body: some View {
        if selection.events.count == 1, let event = selection.events.first {
            ClassEventDetailView(event: event)
        } else {
            TabView(selection: $page) {
                ForEach(Array(selection.events.enumerated()), id: \.offset) { index, event in
                    ClassEventDetailView(event: event, pageLabel: "\(index + 1) of \(selection.events.count)")
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}
