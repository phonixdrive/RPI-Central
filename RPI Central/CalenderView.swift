//
//  CalenderView.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/2/25.
//
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    
    @State private var showAddEventSheet = false
    
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header
                
                dayOfWeekHeader
                
                monthGrid
                
                Divider()
                
                eventsSection
            }
            .padding()
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddEventSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add class")
                }
            }
            .sheet(isPresented: $showAddEventSheet) {
                AddEventView(
                    date: viewModel.selectedDate,
                    isPresented: $showAddEventSheet
                )
                .environmentObject(viewModel)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var header: some View {
        HStack {
            Button(action: viewModel.goToPreviousMonth) {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(viewModel.displayedMonthStart.formatted("LLLL yyyy"))
                .font(.headline)
            Spacer()
            Button(action: viewModel.goToNextMonth) {
                Image(systemName: "chevron.right")
            }
        }
    }
    
    private var dayOfWeekHeader: some View {
        let symbols = calendar.shortWeekdaySymbols   // Sun, Mon, ...
        return HStack {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var monthGrid: some View {
        let days = generateDaysForMonth()
        
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<days.count, id: \.self) { index in
                if let date = days[index] {
                    DayCell(
                        date: date,
                        isSelected: calendar.isDate(date, inSameDayAs: viewModel.selectedDate),
                        hasEvents: !viewModel.events(on: date).isEmpty
                    )
                    .onTapGesture {
                        viewModel.selectedDate = date
                    }
                } else {
                    Rectangle()
                        .foregroundStyle(.clear)
                        .frame(height: 36)
                }
            }
        }
    }
    
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Classes on \(viewModel.selectedDate.formatted("MMM d"))")
                .font(.headline)
            
            let todaysEvents = viewModel.events(on: viewModel.selectedDate)
            
            if todaysEvents.isEmpty {
                Text("No classes yet. Tap + to add one.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                List {
                    ForEach(todaysEvents) { event in
                        HStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(event.color)
                                .frame(width: 6)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title)
                                    .font(.body)
                                Text(event.location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(event.startDate.formatted("h:mm a")) – \(event.endDate.formatted("h:mm a"))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        viewModel.deleteEvents(at: offsets, on: viewModel.selectedDate)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 260) // keeps list from taking over the screen
            }
        }
    }
    
    // MARK: - Calendar logic
    
    /// Returns an array of Date? for the grid. `nil` = empty cell.
    private func generateDaysForMonth() -> [Date?] {
        let start = viewModel.displayedMonthStart
        guard let range = calendar.range(of: .day, in: .month, for: start) else {
            return []
        }
        
        var days: [Date?] = []
        
        let firstWeekdayOfMonth = calendar.component(.weekday, from: start)
        let firstWeekdayIndex = calendar.firstWeekday // usually 1 = Sunday in US
        
        var leadingEmpty = firstWeekdayOfMonth - firstWeekdayIndex
        if leadingEmpty < 0 { leadingEmpty += 7 }
        
        days.append(contentsOf: Array(repeating: nil, count: leadingEmpty))
        
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: start) {
                days.append(date)
            }
        }
        
        return days
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let hasEvents: Bool
    
    var body: some View {
        VStack(spacing: 2) {
            Text(date.formatted("d"))
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
                )
            
            if hasEvents {
                Circle()
                    .frame(width: 5, height: 5)
            } else {
                Circle()
                    .foregroundStyle(.clear)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 36)
    }
}
