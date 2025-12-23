// AddEventView.swift
// RPI Central
//
// Created by Neil Shrestha on 12/2/25.
//

import SwiftUI

private enum RepeatFrequency: String, CaseIterable, Identifiable {
    case none = "Does not repeat"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"

    var id: String { rawValue }
}

struct AddEventView: View {
    @EnvironmentObject var viewModel: CalendarViewModel

    let date: Date
    @Binding var isPresented: Bool

    @State private var title: String = ""
    @State private var location: String = ""

    @State private var startTime: Date
    @State private var endTime: Date

    // ✅ Keyboard control
    private enum Field: Hashable { case title, location }
    @FocusState private var focusedField: Field?

    // Recurrence
    @State private var frequency: RepeatFrequency = .none
    @State private var repeatUntil: Date
    @State private var weeklyDays: Set<Weekday> = []
    @State private var dailyWeekdaysOnly: Bool = false

    init(date: Date, isPresented: Binding<Bool>) {
        self.date = date
        self._isPresented = isPresented

        let cal = Calendar.current
        let defaultStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        let defaultEnd = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date

        _startTime = State(initialValue: defaultStart)
        _endTime = State(initialValue: defaultEnd)

        // default: 12 weeks out
        _repeatUntil = State(initialValue: cal.date(byAdding: .day, value: 7 * 12, to: date) ?? date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Event info")) {
                    TextField("Title (e.g. FOCS)", text: $title)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .location }

                    TextField("Location (e.g. DCC 308)", text: $location)
                        .focused($focusedField, equals: .location)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }

                Section(header: Text("Time")) {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                }

                Section(header: Text("Repeat")) {
                    Picker("Repeats", selection: $frequency) {
                        ForEach(RepeatFrequency.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }

                    if frequency != .none {
                        DatePicker("Repeat until", selection: $repeatUntil, displayedComponents: .date)
                    }

                    if frequency == .daily {
                        Toggle("Weekdays only (Mon–Fri)", isOn: $dailyWeekdaysOnly)
                    }

                    if frequency == .weekly {
                        weekdayPickerRow
                        Text("Pick the days this repeats (like Google/Outlook).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if frequency == .monthly {
                        Text("Repeats monthly on day \(dayOfMonth(date)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // ✅ “Done” button to dismiss keyboard
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear {
                // default weekly day = tapped day
                if weeklyDays.isEmpty {
                    let wk = weekdayEnum(for: date)
                    weeklyDays = wk.map { [$0] } ?? []
                }
            }
            .onChange(of: frequency) { _, newValue in
                // Set nicer defaults per frequency
                let cal = Calendar.current
                switch newValue {
                case .none:
                    break
                case .daily:
                    repeatUntil = cal.date(byAdding: .day, value: 14, to: date) ?? repeatUntil
                case .weekly:
                    repeatUntil = cal.date(byAdding: .day, value: 7 * 12, to: date) ?? repeatUntil
                    if weeklyDays.isEmpty {
                        let wk = weekdayEnum(for: date)
                        weeklyDays = wk.map { [$0] } ?? []
                    }
                case .monthly:
                    repeatUntil = cal.date(byAdding: .month, value: 6, to: date) ?? repeatUntil
                }
            }
        }
    }

    // MARK: - UI pieces

    private var weekdayPickerRow: some View {
        let order: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

        return VStack(alignment: .leading, spacing: 8) {
            Text("Repeats on")
                .font(.subheadline)

            HStack(spacing: 8) {
                ForEach(order, id: \.self) { d in
                    Button(action: {
                        toggleDay(d)
                    }) {
                        Text(d.shortName)
                            .font(.caption.bold())
                            .frame(width: 34, height: 30)
                            .foregroundColor(weeklyDays.contains(d) ? .black : .white)
                            .background(weeklyDays.contains(d) ? Color.white : Color.white.opacity(0.15))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggleDay(_ day: Weekday) {
        if weeklyDays.contains(day) {
            weeklyDays.remove(day)
        } else {
            weeklyDays.insert(day)
        }
        // never allow empty -> default back to tapped weekday
        if weeklyDays.isEmpty {
            let wk = weekdayEnum(for: date)
            if let wk { weeklyDays = [wk] }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Fix invalid duration
        var fixedEndTime = endTime
        if endTime <= startTime {
            fixedEndTime = Calendar.current.date(byAdding: .hour, value: 1, to: startTime) ?? endTime
        }

        // ✅ recurrence id (shared across generated events)
        let seriesID: UUID? = (frequency == .none) ? nil : UUID()

        switch frequency {
        case .none:
            viewModel.addEvent(
                title: trimmedTitle,
                location: location,
                date: date,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: nil
            )
            isPresented = false

        case .daily:
            addDailyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID
            )
            isPresented = false

        case .weekly:
            addWeeklyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID
            )
            isPresented = false

        case .monthly:
            addMonthlyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID
            )
            isPresented = false
        }
    }

    private func addDailyEvents(title: String, location: String, startTime: Date, endTime: Date, seriesID: UUID?) {
        var cal = Calendar.current
        cal.timeZone = .current

        let startDay = cal.startOfDay(for: date)
        let endDay = cal.startOfDay(for: repeatUntil)

        var cur = startDay
        while cur <= endDay {
            let weekday = cal.component(.weekday, from: cur) // 1=Sun ... 7=Sat
            let isWeekend = (weekday == 1 || weekday == 7)

            if !(dailyWeekdaysOnly && isWeekend) {
                viewModel.addEvent(title: title, location: location, date: cur, startTime: startTime, endTime: endTime, seriesID: seriesID)
            }

            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
    }

    private func addWeeklyEvents(title: String, location: String, startTime: Date, endTime: Date, seriesID: UUID?) {
        var cal = Calendar.current
        cal.timeZone = .current

        let startDay = cal.startOfDay(for: date)
        let endDay = cal.startOfDay(for: repeatUntil)

        // If somehow empty, default to weekday of tapped date
        var days = weeklyDays
        if days.isEmpty, let wk = weekdayEnum(for: date) { days = [wk] }

        var cur = startDay
        while cur <= endDay {
            if let wk = weekdayEnum(for: cur), days.contains(wk) {
                viewModel.addEvent(title: title, location: location, date: cur, startTime: startTime, endTime: endTime, seriesID: seriesID)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
    }

    private func addMonthlyEvents(title: String, location: String, startTime: Date, endTime: Date, seriesID: UUID?) {
        let cal = Calendar.current
        let day = dayOfMonth(date)

        var cur = date
        while cur <= repeatUntil {
            viewModel.addEvent(title: title, location: location, date: cur, startTime: startTime, endTime: endTime, seriesID: seriesID)

            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: cur) else { break }
            var comps = cal.dateComponents([.year, .month], from: nextMonth)
            comps.day = day

            // If the month doesn’t have that day (e.g. 31st), skip to last valid day.
            if let exact = cal.date(from: comps) {
                cur = exact
            } else {
                // last day of that month
                if let range = cal.range(of: .day, in: .month, for: nextMonth) {
                    comps.day = range.count
                    cur = cal.date(from: comps) ?? nextMonth
                } else {
                    cur = nextMonth
                }
            }
        }
    }

    // MARK: - Small helpers

    private func dayOfMonth(_ d: Date) -> Int {
        Calendar.current.component(.day, from: d)
    }

    private func weekdayEnum(for d: Date) -> Weekday? {
        // Calendar weekday: 1=Sun ... 7=Sat
        let w = Calendar.current.component(.weekday, from: d)
        switch w {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        case 7: return .sat
        default: return nil
        }
    }
}
