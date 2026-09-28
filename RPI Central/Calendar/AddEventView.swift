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
    @EnvironmentObject var socialManager: SocialManager

    let date: Date
    @Binding var isPresented: Bool

    @State private var title: String = ""
    @State private var location: String = ""
    @State private var selectedDate: Date

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
    @State private var shareMode: PersonalEventShareMode = .none
    @State private var selectedFriendIDs: Set<String> = []
    @State private var selectedGroupIDs: Set<String> = []

    init(date: Date, isPresented: Binding<Bool>) {
        self.date = date
        self._isPresented = isPresented

        let cal = Calendar.current
        let defaultStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        let defaultEnd = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date

        _startTime = State(initialValue: defaultStart)
        _endTime = State(initialValue: defaultEnd)
        _selectedDate = State(initialValue: date)

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
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
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
                        Text(
                            dayOfMonth(selectedDate) > 28
                                ? "Repeats monthly on day \(dayOfMonth(selectedDate)), or the last day of shorter months."
                                : "Repeats monthly on day \(dayOfMonth(selectedDate))."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: HStack(spacing: 6) {
                    Text("Share event")
                    if socialManager.isAuthenticated {
                        InfoButton("People you share with see this event only while your schedule sharing is on in Social.")
                    }
                }) {
                    if socialManager.isAuthenticated {
                        Picker("Send to", selection: $shareMode) {
                            ForEach(PersonalEventShareMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        if shareMode == .friends {
                            sharingSelectionList(
                                title: "Friends",
                                isEmpty: availableFriends.isEmpty,
                                emptyMessage: "No friends available yet.",
                                rows: availableFriends.map { friend in
                                    SharingSelectionRow(
                                        id: friend.id,
                                        title: friend.displayName,
                                        subtitle: "@\(friend.username)",
                                        isSelected: selectedFriendIDs.contains(friend.id)
                                    )
                                },
                                toggle: toggleFriendSelection
                            )
                        }

                        if shareMode == .groups {
                            sharingSelectionList(
                                title: "Groups",
                                isEmpty: availableGroups.isEmpty,
                                emptyMessage: "Create a group in Social first.",
                                rows: availableGroups.map { group in
                                    SharingSelectionRow(
                                        id: group.id,
                                        title: group.name,
                                        subtitle: groupMemberSummary(for: group),
                                        isSelected: selectedGroupIDs.contains(group.id)
                                    )
                                },
                                toggle: toggleGroupSelection
                            )
                        }
                    } else {
                        Text("Sign in on the Social tab to share events.")
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
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isMissingRecipients)
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
                    let wk = weekdayEnum(for: selectedDate)
                    weeklyDays = wk.map { [$0] } ?? []
                }
            }
            .task {
                if socialManager.isAuthenticated && socialManager.overview == nil {
                    await socialManager.refreshOverview()
                }
            }
            .onChange(of: frequency) { _, newValue in
                // Set nicer defaults per frequency
                let cal = Calendar.current
                switch newValue {
                case .none:
                    break
                case .daily:
                    repeatUntil = cal.date(byAdding: .day, value: 14, to: selectedDate) ?? repeatUntil
                case .weekly:
                    repeatUntil = cal.date(byAdding: .day, value: 7 * 12, to: selectedDate) ?? repeatUntil
                    if weeklyDays.isEmpty {
                        let wk = weekdayEnum(for: selectedDate)
                        weeklyDays = wk.map { [$0] } ?? []
                    }
                case .monthly:
                    repeatUntil = cal.date(byAdding: .month, value: 6, to: selectedDate) ?? repeatUntil
                }
            }
            .onChange(of: selectedDate) { oldValue, newValue in
                if Calendar.current.isDate(oldValue, inSameDayAs: repeatUntil) {
                    repeatUntil = newValue
                }

                if frequency == .weekly,
                   let weekday = weekdayEnum(for: newValue),
                   weeklyDays.isEmpty {
                    weeklyDays = [weekday]
                }
            }
            .onChange(of: shareMode) { _, newValue in
                if newValue == .none {
                    selectedFriendIDs = []
                    selectedGroupIDs = []
                }
            }
        }
    }

    // MARK: - UI pieces

    private var availableFriends: [SocialFriend] {
        (socialManager.overview?.friends ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var availableGroups: [SocialFriendGroup] {
        socialManager.friendGroups
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isMissingRecipients: Bool {
        switch shareMode {
        case .none:
            return false
        case .friends:
            return selectedFriendIDs.isEmpty
        case .groups:
            return selectedGroupIDs.isEmpty
        }
    }

    private var weekdayPickerRow: some View {
        let order: [(day: Weekday, label: String, name: String)] = [
            (.mon, "M", "Monday"),
            (.tue, "T", "Tuesday"),
            (.wed, "W", "Wednesday"),
            (.thu, "Th", "Thursday"),
            (.fri, "F", "Friday"),
            (.sat, "Sa", "Saturday"),
            (.sun, "Su", "Sunday"),
        ]

        return VStack(alignment: .leading, spacing: 8) {
            Text("Repeats on")
                .font(.subheadline)

            HStack(spacing: 6) {
                ForEach(order, id: \.day) { entry in
                    let isSelected = weeklyDays.contains(entry.day)
                    Button {
                        toggleDay(entry.day)
                    } label: {
                        Text(entry.label)
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? viewModel.themeColor : Color(.tertiarySystemFill))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private func sharingSelectionList(
        title: String,
        isEmpty: Bool,
        emptyMessage: String,
        rows: [SharingSelectionRow],
        toggle: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    Button {
                        toggle(row.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.isSelected ? viewModel.themeColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .foregroundStyle(.primary)
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 6)
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
        // never allow empty -> default back to the currently selected weekday
        if weeklyDays.isEmpty {
            let wk = weekdayEnum(for: selectedDate)
            if let wk { weeklyDays = [wk] }
        }
    }

    private func toggleFriendSelection(_ friendID: String) {
        if selectedFriendIDs.contains(friendID) {
            selectedFriendIDs.remove(friendID)
        } else {
            selectedFriendIDs.insert(friendID)
        }
    }

    private func toggleGroupSelection(_ groupID: String) {
        if selectedGroupIDs.contains(groupID) {
            selectedGroupIDs.remove(groupID)
        } else {
            selectedGroupIDs.insert(groupID)
        }
    }

    private func groupMemberSummary(for group: SocialFriendGroup) -> String {
        let namesByID = Dictionary(uniqueKeysWithValues: availableFriends.map { ($0.id, $0.displayName) })
        let names = group.memberIDs.compactMap { namesByID[$0] }
        if names.isEmpty {
            return "\(group.memberIDs.count) members"
        }
        if names.count <= 2 {
            return names.joined(separator: ", ")
        }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
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

        let dates: [Date]
        switch frequency {
        case .none:
            dates = [selectedDate]
        case .daily:
            dates = EventRecurrence.dailyDates(from: selectedDate, through: repeatUntil, weekdaysOnly: dailyWeekdaysOnly)
        case .weekly:
            var days = weeklyDays
            if days.isEmpty, let weekday = weekdayEnum(for: selectedDate) { days = [weekday] }
            dates = EventRecurrence.weeklyDates(
                from: selectedDate,
                through: repeatUntil,
                on: Set(days.map(\.calendarWeekday))
            )
        case .monthly:
            dates = EventRecurrence.monthlyDates(from: selectedDate, through: repeatUntil)
        }

        // One save for the whole series instead of one per occurrence.
        let createdEvents = viewModel.addEvents(
            title: trimmedTitle,
            location: location,
            dates: dates.isEmpty ? [selectedDate] : dates,
            startTime: startTime,
            endTime: fixedEndTime,
            seriesID: frequency == .none ? nil : UUID(),
            shareMode: shareMode,
            sharedFriendIDs: Array(selectedFriendIDs).sorted(),
            sharedGroupIDs: Array(selectedGroupIDs).sorted()
        )
        isPresented = false

        if shareMode != .none, socialManager.isAuthenticated {
            Task {
                await socialManager.sharePersonalEvents(createdEvents)
            }
        }
        socialManager.requestScheduleSync()
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

private struct SharingSelectionRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isSelected: Bool
}

/// Occurrence dates for repeating personal events.
enum EventRecurrence {
    /// Guards against accidentally creating years of daily copies.
    static let maximumOccurrences = 750

    static func dailyDates(
        from start: Date,
        through end: Date,
        weekdaysOnly: Bool,
        calendar: Calendar = .current
    ) -> [Date] {
        days(from: start, through: end, calendar: calendar).filter { day in
            guard weekdaysOnly else { return true }
            let weekday = calendar.component(.weekday, from: day)
            return weekday != 1 && weekday != 7
        }
    }

    /// `weekdays` uses Calendar numbering (1 = Sunday … 7 = Saturday).
    static func weeklyDates(
        from start: Date,
        through end: Date,
        on weekdays: Set<Int>,
        calendar: Calendar = .current
    ) -> [Date] {
        days(from: start, through: end, calendar: calendar).filter {
            weekdays.contains(calendar.component(.weekday, from: $0))
        }
    }

    /// Same day each month; months without that day (e.g. the 31st) use
    /// their last day instead of spilling into the next month.
    static func monthlyDates(
        from start: Date,
        through end: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        let dayOfMonth = calendar.component(.day, from: firstDay)

        var result: [Date] = []
        var monthOffset = 0
        while result.count < maximumOccurrences {
            guard let monthStart = calendar.date(
                byAdding: .month,
                value: monthOffset,
                to: calendar.date(from: calendar.dateComponents([.year, .month], from: firstDay)) ?? firstDay
            ),
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count,
            let occurrence = calendar.date(byAdding: .day, value: min(dayOfMonth, daysInMonth) - 1, to: monthStart)
            else { break }

            if occurrence > lastDay { break }
            result.append(occurrence)
            monthOffset += 1
        }
        return result
    }

    private static func days(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        while day <= lastDay && result.count < maximumOccurrences {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
