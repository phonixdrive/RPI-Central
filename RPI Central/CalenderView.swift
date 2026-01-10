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

struct CalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    @State private var displayMode: CalendarDisplayMode = .week

    // ✅ Add-event sheet
    @State private var showingAddEvent: Bool = false

    // ✅ Fullscreen boot overlay (local to view)
    @State private var showBootOverlay: Bool = false
    @State private var bootCanSkip: Bool = false
    @State private var bootSubtitle: String = "Loading calendar…"
    @State private var bootTimerStarted: Bool = false

    // ✅ NEW: when user presses Continue, suppress ALL loading overlays for this session
    @State private var suppressLoadingOverlays: Bool = false

    private let backgroundColor = Color(red: 0x20/255.0, green: 0x22/255.0, blue: 0x24/255.0)
    private let barColor        = Color(red: 0x2B/255.0, green: 0x2D/255.0, blue: 0x30/255.0)

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider()
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
                // ✅ Start fullscreen boot overlay (Simulator-safe)
                beginBootOverlayIfNeeded()

                // ✅ Your existing loading work
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
            .onChange(of: isCalendarLoading) { _, loading in
                if !loading {
                    withAnimation(.easeOut(duration: 0.18)) {
                        showBootOverlay = false
                    }
                } else {
                    beginBootOverlayIfNeeded()
                }
            }
            .sheet(isPresented: $showingAddEvent) {
                AddEventView(date: viewModel.selectedDate, isPresented: $showingAddEvent)
                    .environmentObject(viewModel)
            }

            // ✅ Fullscreen boot overlay (shown only if NOT suppressed)
            if showBootOverlay && isCalendarLoading && !suppressLoadingOverlays {
                BootLoadingOverlay(
                    title: "RPI Central",
                    subtitle: bootSubtitle,
                    showSkip: bootCanSkip,
                    onSkip: {
                        // ✅ This is the key fix: once user continues, kill BOTH layers.
                        suppressLoadingOverlays = true
                        withAnimation(.easeOut(duration: 0.18)) {
                            showBootOverlay = false
                        }
                    },
                    onRetry: {
                        bootSubtitle = "Retrying…"
                        viewModel.ensureAcademicEventsLoaded(for: viewModel.currentSemester)
                        viewModel.ensureTermBoundsForAllEnrollments()
                        viewModel.ensureTermBoundsLoaded(for: viewModel.currentSemester)
                    }
                )
                .transition(.opacity)
                .zIndex(1000)
            }

            // ✅ Optional small overlay (non-blocking) ONLY if NOT suppressed
            if isCalendarLoading && !showBootOverlay && !suppressLoadingOverlays {
                ZStack {
                    Color.black.opacity(0.20).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading calendar…")
                            .foregroundColor(.white)
                            .font(.callout)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                }
                .zIndex(999)
            }
        }
    }

    private var isCalendarLoading: Bool {
        // Academic: treat “attempted” as non-blocking (prevents simulator perma-load)
        let academicReady = viewModel.academicEventsLoaded
            || viewModel.didAttemptAcademicEvents(for: viewModel.currentSemester)

        // Term bounds: only block on bounds that are missing AND unattempted
        let codes = Set(viewModel.enrolledCourses.map { $0.semesterCode })
        let missingUnattemptedBounds = codes.contains { code in
            (viewModel.termBoundsBySemesterCode[code] == nil) && !viewModel.didAttemptTermBounds(for: code)
        }

        return (!academicReady) || missingUnattemptedBounds
    }

    // MARK: - Boot overlay helpers

    private func beginBootOverlayIfNeeded() {
        // ✅ If user pressed Continue, never show loading overlays again this session
        if suppressLoadingOverlays { return }

        guard !bootTimerStarted else {
            if isCalendarLoading && !showBootOverlay {
                showBootOverlay = true
            }
            return
        }

        bootTimerStarted = true
        showBootOverlay = true
        bootCanSkip = false
        bootSubtitle = "Loading calendar…"

        // Enable skip quickly (Simulator can hang)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s
            if isCalendarLoading && !suppressLoadingOverlays {
                bootCanSkip = true
                bootSubtitle = "Still loading… (You can continue if the Simulator hangs)"
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

            // ✅ TODAY button
            

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    let today = Date()
                    viewModel.selectedDate = today
                    viewModel.displayedMonthStart = today.startOfMonth()
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
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(barColor)
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
            Text(monthTitle(for: current))
                .font(.title2.bold())
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

    private func monthTitle(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "LLLL yyyy"
        return df.string(from: date)
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

    let days: [Date]
    let displayMode: CalendarDisplayMode

    @State private var selectedEvent: ClassEvent?

    // ✅ overlap swipe state: groupKey -> topEventKey
    @State private var topEventKeyByGroup: [String: String] = [:]

    // ✅ all-day “show all” sheet
    @State private var showAllDaySheet: Bool = false
    @State private var allDaySheetTitle: String = ""
    @State private var allDaySheetEvents: [ClassEvent] = []

    private let calendar = Calendar.current
    private let dayStartHour = 7
    private let dayEndHour = 22
    private let rowHeight: CGFloat = 60
    private let timeColWidth: CGFloat = 56

    private var totalMinutes: Int { (dayEndHour - dayStartHour) * 60 }

    var body: some View {
        let intervalCount = dayEndHour - dayStartHour
        let today = Date()

        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                Text("").frame(width: timeColWidth)

                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDate(day, inSameDayAs: today)

                    VStack(spacing: 2) {
                        let isToday = calendar.isDateInToday(day)

                        Text(day.formatted("EEE"))
                            .font(.subheadline.bold())
                            .foregroundColor(isToday ? viewModel.themeColor : .white)

                        Text(day.formatted("MM/dd"))
                            .font(.caption)
                            .foregroundColor(isToday ? .black.opacity(0.85) : .secondary)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(isToday ? Color.white : Color.clear)
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
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.10))
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
                GeometryReader { geo in
                    let totalHeight = CGFloat(intervalCount) * rowHeight
                    let gridLeftX = timeColWidth
                    let gridRightX = geo.size.width
                    let dayWidth = (gridRightX - gridLeftX) / CGFloat(max(days.count, 1))

                    ZStack(alignment: .topLeading) {
                        ForEach(0...intervalCount, id: \.self) { idx in
                            let y = CGFloat(idx) * rowHeight

                            Path { path in
                                path.move(to: CGPoint(x: gridLeftX, y: y))
                                path.addLine(to: CGPoint(x: gridRightX, y: y))
                            }
                            .stroke(Color.white.opacity(0.7), lineWidth: 1.1)

                            if idx < intervalCount {
                                let hour = dayStartHour + idx
                                Text(hourLabel(hour))
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .position(x: gridLeftX - 26, y: y + 8)
                            }
                        }

                        if days.count > 1 {
                            ForEach(1..<days.count, id: \.self) { col in
                                let x = gridLeftX + dayWidth * CGFloat(col)
                                Path { path in
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: totalHeight))
                                }
                                .stroke(Color.white.opacity(0.7), lineWidth: 1.1)
                            }
                        }

                        if displayMode == .day || displayMode == .threeDay || displayMode == .week {
                            if let nowY = nowLineY(totalHeight: totalHeight) {
                                Path { path in
                                    path.move(to: CGPoint(x: gridLeftX, y: nowY))
                                    path.addLine(to: CGPoint(x: gridRightX, y: nowY))
                                }
                                .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                                Text("Now")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .position(x: gridLeftX - 20, y: nowY)
                            }
                        }

                        // ✅ render timed events per overlap group
                        ForEach(Array(days.enumerated()), id: \.1) { (colIndex, day) in
                            let timed = viewModel.events(on: day).filter { !$0.isAllDay }
                            let groups = overlapGroups(timed)

                            ForEach(groups.indices, id: \.self) { gi in
                                let group = groups[gi]
                                let columnLeft = gridLeftX + dayWidth * CGFloat(colIndex)
                                let eventWidth = max(dayWidth - 8, 0)
                                let centerX = columnLeft + dayWidth / 2
                                let groupKey = makeGroupKey(day: day, group: group)

                                if group.count == 1, let ev = group.first,
                                   let r = rectForEvent(ev, totalHeight: totalHeight) {

                                    eventChip(ev)
                                        .frame(width: eventWidth, height: r.height)
                                        .position(x: centerX, y: r.minY + r.height / 2)
                                        .onTapGesture { selectedEvent = ev }
                                        .contextMenu { chipMenu(for: ev) }

                                } else {
                                    overlapStack(
                                        groupKey: groupKey,
                                        group: group,
                                        width: eventWidth,
                                        centerX: centerX,
                                        totalHeight: totalHeight
                                    )
                                }
                            }
                        }
                    }
                    .frame(height: totalHeight)
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            ClassEventDetailView(event: event)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAllDaySheet) {
            AllDayEventsListView(title: allDaySheetTitle, events: allDaySheetEvents)
                .environmentObject(viewModel)
        }
    }

    // MARK: - Context menu actions

    @ViewBuilder
    private func chipMenu(for event: ClassEvent) -> some View {
        if event.isAllDay {
            Button(role: .destructive) {
                viewModel.hideAllDayEvent(event)
            } label: {
                Label("Hide all-day event", systemImage: "eye.slash")
            }
        }

        if event.kind == .personal {
            Button(role: .destructive) {
                viewModel.removePersonalEvent(event)
            } label: {
                Label("Remove event", systemImage: "trash")
            }

            if let sid = event.seriesID {
                Button(role: .destructive) {
                    viewModel.removePersonalSeries(seriesID: sid)
                } label: {
                    Label("Remove recurrence", systemImage: "trash.slash")
                }
            }
        }

        if event.kind == .classMeeting {
            Button(role: .destructive) {
                viewModel.hideClassOccurrence(event)
            } label: {
                Label("Hide this occurrence", systemImage: "eye.slash")
            }

            if let id = event.enrollmentID,
               let enrollment = viewModel.enrolledCourses.first(where: { $0.id == id }) {
                Button(role: .destructive) {
                    viewModel.removeEnrollment(enrollment)
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

    @ViewBuilder
    private func overlapStack(
        groupKey: String,
        group: [ClassEvent],
        width: CGFloat,
        centerX: CGFloat,
        totalHeight: CGFloat
    ) -> some View {

        // default order: shortest duration first
        let base = group.sorted {
            let d0 = $0.endDate.timeIntervalSince($0.startDate)
            let d1 = $1.endDate.timeIntervalSince($1.startDate)
            if d0 != d1 { return d0 < d1 }
            return $0.startDate < $1.startDate
        }

        let defaultTop = base.first?.interactionKey ?? group[0].interactionKey
        let topKey = topEventKeyByGroup[groupKey] ?? defaultTop

        let baseKeys = base.map(\.interactionKey)
        let rotatedKeys = rotate(baseKeys, startingAt: topKey)

        let ordered: [ClassEvent] = rotatedKeys.compactMap { k in
            base.first(where: { $0.interactionKey == k })
        }

        ZStack {
            ForEach(Array(ordered.prefix(3).enumerated()), id: \.element.interactionKey) { (i, ev) in
                if let r = rectForEvent(ev, totalHeight: totalHeight) {
                    let xOff: CGFloat = CGFloat(i) * 6
                    let yOff: CGFloat = CGFloat(i) * 6

                    eventChip(ev)
                        .frame(width: width, height: r.height)
                        .position(x: centerX + xOff, y: r.minY + r.height / 2 + yOff)
                        .zIndex(Double(100 - i))
                        .onTapGesture { selectedEvent = ev }
                        .contextMenu { chipMenu(for: ev) }
                }
            }
        }
        // ✅ Only overlap stacks steal swipe → week swipe doesn't break
        .highPriorityGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy), abs(dx) > 20 else { return }
                    guard rotatedKeys.count > 1 else { return }

                    let newTop = (dx < 0) ? rotatedKeys[1] : (rotatedKeys.last ?? topKey)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        topEventKeyByGroup[groupKey] = newTop
                    }
                }
        )
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

    private func nowLineY(totalHeight: CGFloat) -> CGFloat? {
        let now = Date()
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

    private func eventChip(_ event: ClassEvent) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(event.accentColor)
                    .frame(width: 4)
                    .cornerRadius(2, corners: [.topLeft, .bottomLeft])

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.caption2.bold())
                        .foregroundColor(.black)

                    Text("\(timeString(event.startDate)) – \(timeString(event.endDate))")
                        .font(.caption2)
                        .foregroundColor(.black)

                    if !event.location.isEmpty {
                        Text(event.location)
                            .font(.caption2)
                            .foregroundColor(.black.opacity(0.8))
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
                                    Text(event.title)
                                        .font(.headline)

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
                        .foregroundColor(.white)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $selectedEvent) { event in
            ClassEventDetailView(event: event)
                .environmentObject(viewModel)
        }
    }

    @ViewBuilder
    private func monthSwipeActions(for event: ClassEvent) -> some View {
        if event.isAllDay {
            Button(role: .destructive) {
                viewModel.hideAllDayEvent(event)
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }

        if event.kind == .personal {
            Button(role: .destructive) {
                viewModel.removePersonalEvent(event)
            } label: {
                Label("Remove", systemImage: "trash")
            }

            if let sid = event.seriesID {
                Button(role: .destructive) {
                    viewModel.removePersonalSeries(seriesID: sid)
                } label: {
                    Label("Recurrence", systemImage: "trash.slash")
                }
            }
        }

        if event.kind == .classMeeting {
            Button(role: .destructive) {
                viewModel.hideClassOccurrence(event)
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
}

// MARK: - Month grid (selects viewModel.selectedDate)

struct MonthGridView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
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
                        .foregroundColor(.white)
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
                            let dotColors = dotColorsForDayEvents(dayEvents)

                            VStack(spacing: 3) {
                                Text("\(dayNumber)")
                                    .font(.caption)
                                    .foregroundColor(isSelected ? .black : .white)
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
                                        Color.white
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
                                    .stroke(isToday ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.6)
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

struct ClassEventDetailView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    let event: ClassEvent

    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoveOne: Bool = false
    @State private var confirmRemoveSeries: Bool = false
    @State private var confirmRemoveCourse: Bool = false
    @State private var confirmHideOccurrence: Bool = false
    @State private var confirmHideAllDay: Bool = false

    private let dfDate: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private let dfTime: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(event.title)
                    .font(.title3.bold())

                if event.isAllDay {
                    Text("All-day event")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("\(dfDate.string(from: event.startDate))")
                        .font(.subheadline)

                    if Calendar.current.startOfDay(for: event.startDate) != Calendar.current.startOfDay(for: event.endDate) {
                        Text("Through \(dfDate.string(from: event.endDate))")
                            .font(.subheadline)
                    }
                } else {
                    Text(dfDate.string(from: event.startDate))
                        .font(.subheadline)

                    Text("\(dfTime.string(from: event.startDate)) – \(dfTime.string(from: event.endDate))")
                        .font(.subheadline)
                }

                if !event.location.isEmpty {
                    Text(event.location)
                        .font(.subheadline)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if event.isAllDay {
                            Button(role: .destructive) { confirmHideAllDay = true } label: {
                                Label("Hide all-day event", systemImage: "eye.slash")
                            }
                        }

                        if event.kind == .personal {
                            Button(role: .destructive) { confirmRemoveOne = true } label: {
                                Label("Remove event", systemImage: "trash")
                            }

                            if let sid = event.seriesID {
                                Button(role: .destructive) { confirmRemoveSeries = true } label: {
                                    Label("Remove recurrence", systemImage: "trash.slash")
                                }
                            }
                        }

                        if event.kind == .classMeeting {
                            Button(role: .destructive) { confirmHideOccurrence = true } label: {
                                Label("Hide this occurrence", systemImage: "eye.slash")
                            }

                            if event.enrollmentID != nil {
                                Button(role: .destructive) { confirmRemoveCourse = true } label: {
                                    Label("Remove course from calendar", systemImage: "trash")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Hide all-day event?", isPresented: $confirmHideAllDay, titleVisibility: .visible) {
                Button("Hide", role: .destructive) {
                    viewModel.hideAllDayEvent(event)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove event?", isPresented: $confirmRemoveOne, titleVisibility: .visible) {
                Button("Remove event", role: .destructive) {
                    viewModel.removePersonalEvent(event)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove recurrence?", isPresented: $confirmRemoveSeries, titleVisibility: .visible) {
                Button("Remove recurrence", role: .destructive) {
                    if let sid = event.seriesID {
                        viewModel.removePersonalSeries(seriesID: sid)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove course?", isPresented: $confirmRemoveCourse, titleVisibility: .visible) {
                Button("Remove course", role: .destructive) {
                    if let id = event.enrollmentID,
                       let enrollment = viewModel.enrolledCourses.first(where: { $0.id == id }) {
                        viewModel.removeEnrollment(enrollment)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Hide this class meeting only?", isPresented: $confirmHideOccurrence, titleVisibility: .visible) {
                Button("Hide this occurrence", role: .destructive) {
                    viewModel.hideClassOccurrence(event)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct AllDayEventsListView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
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
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                        }

                        if ev.kind == .personal {
                            Button(role: .destructive) {
                                viewModel.removePersonalEvent(ev)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }

                            if let sid = ev.seriesID {
                                Button(role: .destructive) {
                                    viewModel.removePersonalSeries(seriesID: sid)
                                } label: {
                                    Label("Recurrence", systemImage: "trash.slash")
                                }
                            }
                        }

                        if ev.kind == .classMeeting {
                            Button(role: .destructive) {
                                viewModel.hideClassOccurrence(ev)
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
            }
        }
    }
}

// MARK: - Boot loading overlay

fileprivate struct BootLoadingOverlay: View {
    let title: String
    let subtitle: String
    let showSkip: Bool
    let onSkip: () -> Void
    let onRetry: () -> Void

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.95),
                    Color.black.opacity(0.85),
                    Color.black.opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(pulse ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.1)

                HStack(spacing: 12) {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.14))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)

                    if showSkip {
                        Button {
                            onSkip()
                        } label: {
                            Text("Continue")
                                .font(.callout.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.black)
                    }
                }
                .padding(.top, 4)

                if showSkip {
                    Text("If the Simulator gets stuck, tap Continue — your calendar will still load when it can.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 10)
        }
        .onAppear { pulse = true }
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
