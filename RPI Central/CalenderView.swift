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

    // Dark app background and slightly lighter bar background
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
            // Swipe left / right to move period, with animation
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) else { return }
                        if dx < 0 {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                shift(by: 1)
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                shift(by: -1)
                            }
                        }
                    }
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    shift(by: -1)
                }
            } label: {
                Image(systemName: "chevron.left")
            }

            monthPicker

            Spacer()

            Menu {
                ForEach(CalendarDisplayMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            displayMode = mode
                        }
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

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    shift(by: 1)
                }
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(barColor)
    }

    /// Month name + year, tap to jump to any month in a small year range.
    private var monthPicker: some View {
        let cal = Calendar.current
        let current = viewModel.selectedDate
        let currentYear = cal.component(.year, from: current)
        let years = (currentYear - 1)...(currentYear + 1)

        return Menu {
            ForEach(Array(years), id: \.self) { year in
                // Prefix "Year" so iOS never formats it as 2,025 etc.
                Section("Year \(year)") {
                    ForEach(1...12, id: \.self) { month in
                        Button {
                            var comps = DateComponents()
                            comps.year = year
                            comps.month = month
                            comps.day = 1
                            if let newDate = cal.date(from: comps) {
                                viewModel.selectedDate = newDate
                                viewModel.displayedMonthStart = newDate.startOfMonth(using: cal)
                            }
                        } label: {
                            Text("\(monthName(month)) \(year)")
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
            TimelineCalendarView(
                days: [viewModel.selectedDate],
                displayMode: displayMode
            )
            .environmentObject(viewModel)

        case .threeDay:
            TimelineCalendarView(
                days: daysFrom(selected: viewModel.selectedDate, count: 3),
                displayMode: displayMode
            )
            .environmentObject(viewModel)

        case .week:
            TimelineCalendarView(
                days: weekdaysOfCurrentWeek(from: viewModel.selectedDate),
                displayMode: displayMode
            )
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

    private func monthName(_ month: Int) -> String {
        var comps = DateComponents()
        comps.month = month
        comps.day = 1
        let cal = Calendar.current
        let date = cal.date(from: comps) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "LLLL"
        return df.string(from: date)
    }

    private func shift(by offset: Int) {
        let cal = Calendar.current
        switch displayMode {
        case .day:
            if let newDate = cal.date(byAdding: .day, value: offset, to: viewModel.selectedDate) {
                viewModel.selectedDate = newDate
            }
        case .threeDay:
            if let newDate = cal.date(byAdding: .day, value: 3 * offset, to: viewModel.selectedDate) {
                viewModel.selectedDate = newDate
            }
        case .week:
            if let newDate = cal.date(byAdding: .weekOfYear, value: offset, to: viewModel.selectedDate) {
                viewModel.selectedDate = newDate
            }
        case .month:
            if let newDate = cal.date(byAdding: .month, value: offset, to: viewModel.selectedDate) {
                viewModel.selectedDate = newDate
            }
        }
    }

    private func daysFrom(selected: Date, count: Int) -> [Date] {
        let cal = Calendar.current
        return (0..<count).compactMap {
            cal.date(byAdding: .day, value: $0, to: selected)
        }
    }

    private func weekdaysOfCurrentWeek(from date: Date) -> [Date] {
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: date) else {
            return []
        }
        let sunday = weekInterval.start
        // 1 = Sunday, so [1...5] => Mon–Fri
        return (1...5).compactMap {
            cal.date(byAdding: .day, value: $0, to: sunday)
        }
    }
}

// MARK: - Timeline (Day / 3-day / Week views)

struct TimelineCalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel

    let days: [Date]
    let displayMode: CalendarDisplayMode

    @State private var selectedEvent: ClassEvent?

    private let calendar = Calendar.current
    private let dayStartHour = 7
    private let dayEndHour = 22
    private let rowHeight: CGFloat = 60

    /// Minutes in the visible range (e.g. 7–22 = 15h = 900 minutes)
    private var totalMinutes: Int {
        (dayEndHour - dayStartHour) * 60
    }

    var body: some View {
        // number of hour *intervals* (7–8, 8–9, ... 21–22)
        let intervalCount = dayEndHour - dayStartHour

        VStack(spacing: 0) {
            // Day labels row
            HStack(alignment: .bottom, spacing: 0) {
                Text("")
                    .frame(width: 56) // time column spacer

                ForEach(days, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text(day.formatted("EEE"))
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                        Text(day.formatted("MM/dd"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                GeometryReader { geo in
                    let totalHeight = CGFloat(intervalCount) * rowHeight
                    let timeColWidth: CGFloat = 56
                    let gridLeftX = timeColWidth
                    let gridRightX = geo.size.width
                    let dayWidth = (gridRightX - gridLeftX) / CGFloat(max(days.count, 1))

                    ZStack(alignment: .topLeading) {

                        // Horizontal grid lines + time labels
                        ForEach(0...intervalCount, id: \.self) { idx in
                            let y = CGFloat(idx) * rowHeight

                            // line at the top of each hour block
                            Path { path in
                                path.move(to: CGPoint(x: gridLeftX, y: y))
                                path.addLine(to: CGPoint(x: gridRightX, y: y))
                            }
                            .stroke(Color.white.opacity(0.7), lineWidth: 1.1)

                            // time label (no label past the last interval)
                            if idx < intervalCount {
                                let hour = dayStartHour + idx
                                Text(hourLabel(hour))
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .position(
                                        x: gridLeftX - 26,
                                        y: y + 8
                                    )
                            }
                        }

                        // Vertical inner grid lines (no outermost ones)
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

                        // Current time horizontal line (only if visible range includes today)
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

                        // Events overlay
                        ForEach(Array(days.enumerated()), id: \.1) { (colIndex, day) in
                            let eventsForDay = viewModel.events(on: day)
                            ForEach(eventsForDay) { event in
                                if let rect = rectForEvent(event,
                                                           totalHeight: totalHeight) {

                                    // Center the box in its column with small left/right margins
                                    let columnLeft = gridLeftX + dayWidth * CGFloat(colIndex)
                                    let eventWidth = max(dayWidth - 8, 0)
                                    let centerX = columnLeft + dayWidth / 2

                                    eventChip(event)
                                        .frame(width: eventWidth, height: rect.height)
                                        .position(
                                            x: centerX,
                                            y: rect.minY + rect.height / 2
                                        )
                                        .onTapGesture {
                                            selectedEvent = event
                                        }
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
        }
    }

    // MARK: - Geometry helpers

    private func rectForEvent(_ event: ClassEvent,
                              totalHeight: CGFloat) -> CGRect? {
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
        let height = max(24, maxY - minY)   // ensure it’s tappable

        return CGRect(x: 0, y: minY, width: 0, height: height)
    }

    private func nowLineY(totalHeight: CGFloat) -> CGFloat? {
        let now = Date()
        guard days.contains(where: { calendar.isDate($0, inSameDayAs: now) }) else {
            return nil
        }

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

    // MARK: - Event chip (box centered, text top-left, multi-line)

    private func eventChip(_ event: ClassEvent) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Dark strip on the left
                Rectangle()
                    .fill(event.accentColor)
                    .frame(width: 4)
                    .cornerRadius(2, corners: [.topLeft, .bottomLeft])

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.caption2.bold())
                        .foregroundColor(.black)
                        // no lineLimit -> wrap instead of truncating

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

    var body: some View {
        VStack(spacing: 0) {
            MonthGridView()
                .environmentObject(viewModel)

            Divider()
                .padding(.top, 4)

            // Schedule for the currently selected day (from viewModel.selectedDate)
            let selected = viewModel.selectedDate
            let events = viewModel.events(on: selected)

            VStack(alignment: .leading, spacing: 4) {
                Text(selected.formatted("EEEE, MMM d"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if events.isEmpty {
                    Text("No classes for this day.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                } else {
                    List {
                        ForEach(events.sorted(by: { $0.startDate < $1.startDate })) { event in
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
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private func timeRangeString(for event: ClassEvent) -> String {
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
        let leadingBlanks = (firstWeekday + 6) % 7  // make Monday=0

        let totalCells = leadingBlanks + range.count
        let rows = Int(ceil(Double(totalCells) / 7.0))

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
                                .frame(height: 36)
                                .frame(maxWidth: .infinity)
                        } else {
                            let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: start) ?? start
                            let hasEvents = !viewModel.events(on: date).isEmpty
                            let isSelected = calendar.isDate(date, inSameDayAs: viewModel.selectedDate)

                            VStack(spacing: 2) {
                                Text("\(dayNumber)")
                                    .font(.caption)
                                    .foregroundColor(isSelected ? .black : .white)
                                    .frame(maxWidth: .infinity)

                                if hasEvents {
                                    Circle()
                                        .fill(isSelected ? Color.black : Color.green)
                                        .frame(width: 4, height: 4)
                                } else {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 4, height: 4)
                                }
                            }
                            .padding(4)
                            .background(
                                isSelected ? Color.white : Color.clear
                            )
                            .cornerRadius(6)
                            .frame(height: 36)
                            .frame(maxWidth: .infinity)
                            .onTapGesture {
                                viewModel.selectedDate = date
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Detail sheet when you tap a class block

struct ClassEventDetailView: View {
    let event: ClassEvent

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

                Text(dfDate.string(from: event.startDate))
                    .font(.subheadline)

                Text("\(dfTime.string(from: event.startDate)) – \(dfTime.string(from: event.endDate))")
                    .font(.subheadline)

                if !event.location.isEmpty {
                    Text(event.location)
                        .font(.subheadline)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Class Details")
            .navigationBarTitleDisplayMode(.inline)
        }
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
