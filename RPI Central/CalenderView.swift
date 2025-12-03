//  CalendarView.swift
//  RPI Central

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel

    var body: some View {
        WeekGridCalendar()
            .environmentObject(viewModel)
    }
}

// MARK: - Week grid calendar (Mon–Fri, times on left)

struct WeekGridCalendar: View {
    @EnvironmentObject var viewModel: CalendarViewModel

    private let calendar = Calendar.current
    private let hours = Array(7...22)   // 7 AM – 10 PM

    var body: some View {
        let weekDays = weekdaysOfCurrentWeek(from: viewModel.selectedDate)

        VStack(spacing: 0) {
            // Header: week navigation + title
            HStack {
                Button {
                    shiftWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }

                Spacer()

                if let first = weekDays.first, let last = weekDays.last {
                    Text(weekTitle(from: first, to: last))
                        .font(.headline)
                }

                Spacer()

                Button {
                    shiftWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    // Day labels row
                    HStack(alignment: .bottom, spacing: 0) {
                        Text("")
                            .frame(width: 48) // time column spacer

                        ForEach(weekDays, id: \.self) { day in
                            VStack(spacing: 2) {
                                Text(day.formatted("EEE"))
                                    .font(.subheadline.bold())
                                Text(day.formatted("MM/dd"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                    Divider()

                    // Hour rows
                    ForEach(hours, id: \.self) { hour in
                        HStack(alignment: .top, spacing: 0) {
                            // Time label
                            Text(hourLabel(hour))
                                .font(.caption)
                                .frame(width: 48, alignment: .topTrailing)
                                .padding(.top, 4)

                            // Columns for each day
                            ForEach(weekDays, id: \.self) { day in
                                let eventsThisHour = events(on: day, hour: hour)

                                ZStack(alignment: .topLeading) {
                                    Rectangle()
                                        // GRID LINES: now white instead of dark gray
                                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)

                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(eventsThisHour) { event in
                                            eventChip(event)
                                        }
                                    }
                                    .padding(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func weekdaysOfCurrentWeek(from date: Date) -> [Date] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return []
        }
        let sunday = weekInterval.start
        return (1...5).compactMap {
            calendar.date(byAdding: .day, value: $0, to: sunday)
        }
    }

    private func shiftWeek(by offset: Int) {
        if let newDate = calendar.date(byAdding: .weekOfYear, value: offset, to: viewModel.selectedDate) {
            viewModel.selectedDate = newDate
            viewModel.displayedMonthStart = newDate.startOfMonth(using: calendar)
        }
    }

    private func weekTitle(from start: Date, to end: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        let dfYear = DateFormatter()
        dfYear.dateFormat = "yyyy"
        return "\(df.string(from: start)) – \(df.string(from: end)), \(dfYear.string(from: start))"
    }

    private func hourLabel(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        let df = DateFormatter()
        df.dateFormat = "h a"
        return df.string(from: calendar.date(from: comps) ?? Date())
    }

    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }

    private func events(on day: Date, hour: Int) -> [ClassEvent] {
        let all = viewModel.events(on: day)
        return all.filter { event in
            let eventHour = calendar.component(.hour, from: event.startDate)
            return eventHour == hour
        }
    }

    private func eventChip(_ event: ClassEvent) -> some View {
        HStack(spacing: 0) {
            // Dark strip on the left
            Rectangle()
                .fill(event.accentColor)
                .frame(width: 4)
                .cornerRadius(2, corners: [.topLeft, .bottomLeft])

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption2.bold())
                    .foregroundColor(.black)              // inside box: black text
                    .lineLimit(1)

                Text("\(timeString(event.startDate)) – \(timeString(event.endDate))")
                    .font(.caption2)
                    .foregroundColor(.black)              // inside box: black text
                    .lineLimit(1)

                if !event.location.isEmpty {
                    Text(event.location)
                        .font(.caption2)
                        .foregroundColor(.black.opacity(0.8)) // inside box: black-ish
                        .lineLimit(1)
                }
            }
            .padding(4)
        }
        .background(event.backgroundColor)
        .cornerRadius(4)
    }
}

// Corner-radius helper for the strip
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
