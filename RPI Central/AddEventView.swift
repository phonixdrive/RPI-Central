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
                        Text("Repeats monthly on day \(dayOfMonth(selectedDate)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Share event")) {
                    if socialManager.isAuthenticated {
                        Picker("Send to", selection: $shareMode) {
                            ForEach(PersonalEventShareMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        Text("Recipients only see this event if your schedule sharing is enabled in Social.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

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
                                title: "Friend groups",
                                isEmpty: availableGroups.isEmpty,
                                emptyMessage: "Create a friend group in Social first.",
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
                        Text("Sign in through Social to share personal events with friends or friend groups.")
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

        // ✅ recurrence id (shared across generated events)
        let seriesID: UUID? = (frequency == .none) ? nil : UUID()
        let friendIDs = Array(selectedFriendIDs).sorted()
        let groupIDs = Array(selectedGroupIDs).sorted()

        switch frequency {
        case .none:
            addSingleEvent(
                title: trimmedTitle,
                location: location,
                eventDate: selectedDate,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: nil,
                friendIDs: friendIDs,
                groupIDs: groupIDs
            )
            isPresented = false

        case .daily:
            addDailyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID,
                friendIDs: friendIDs,
                groupIDs: groupIDs
            )
            isPresented = false

        case .weekly:
            addWeeklyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID,
                friendIDs: friendIDs,
                groupIDs: groupIDs
            )
            isPresented = false

        case .monthly:
            addMonthlyEvents(
                title: trimmedTitle,
                location: location,
                startTime: startTime,
                endTime: fixedEndTime,
                seriesID: seriesID,
                friendIDs: friendIDs,
                groupIDs: groupIDs
            )
            isPresented = false
        }

        if socialManager.currentUser?.shareSchedule == true {
            Task {
                await socialManager.syncSchedule(from: viewModel)
            }
        }
    }

    private func addSingleEvent(
        title: String,
        location: String,
        eventDate: Date,
        startTime: Date,
        endTime: Date,
        seriesID: UUID?,
        friendIDs: [String],
        groupIDs: [String]
    ) {
        viewModel.addEvent(
            title: title,
            location: location,
            date: eventDate,
            startTime: startTime,
            endTime: endTime,
            seriesID: seriesID,
            shareMode: shareMode,
            sharedFriendIDs: friendIDs,
            sharedGroupIDs: groupIDs
        )
    }

    private func addDailyEvents(
        title: String,
        location: String,
        startTime: Date,
        endTime: Date,
        seriesID: UUID?,
        friendIDs: [String],
        groupIDs: [String]
    ) {
        var cal = Calendar.current
        cal.timeZone = .current

        let startDay = cal.startOfDay(for: selectedDate)
        let endDay = cal.startOfDay(for: repeatUntil)

        var cur = startDay
        while cur <= endDay {
            let weekday = cal.component(.weekday, from: cur) // 1=Sun ... 7=Sat
            let isWeekend = (weekday == 1 || weekday == 7)

            if !(dailyWeekdaysOnly && isWeekend) {
                addSingleEvent(
                    title: title,
                    location: location,
                    eventDate: cur,
                    startTime: startTime,
                    endTime: endTime,
                    seriesID: seriesID,
                    friendIDs: friendIDs,
                    groupIDs: groupIDs
                )
            }

            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
    }

    private func addWeeklyEvents(
        title: String,
        location: String,
        startTime: Date,
        endTime: Date,
        seriesID: UUID?,
        friendIDs: [String],
        groupIDs: [String]
    ) {
        var cal = Calendar.current
        cal.timeZone = .current

        let startDay = cal.startOfDay(for: selectedDate)
        let endDay = cal.startOfDay(for: repeatUntil)

        // If somehow empty, default to weekday of tapped date
        var days = weeklyDays
        if days.isEmpty, let wk = weekdayEnum(for: selectedDate) { days = [wk] }

        var cur = startDay
        while cur <= endDay {
            if let wk = weekdayEnum(for: cur), days.contains(wk) {
                addSingleEvent(
                    title: title,
                    location: location,
                    eventDate: cur,
                    startTime: startTime,
                    endTime: endTime,
                    seriesID: seriesID,
                    friendIDs: friendIDs,
                    groupIDs: groupIDs
                )
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
    }

    private func addMonthlyEvents(
        title: String,
        location: String,
        startTime: Date,
        endTime: Date,
        seriesID: UUID?,
        friendIDs: [String],
        groupIDs: [String]
    ) {
        let cal = Calendar.current
        let day = dayOfMonth(selectedDate)

        var cur = selectedDate
        while cur <= repeatUntil {
            addSingleEvent(
                title: title,
                location: location,
                eventDate: cur,
                startTime: startTime,
                endTime: endTime,
                seriesID: seriesID,
                friendIDs: friendIDs,
                groupIDs: groupIDs
            )

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

private struct SharingSelectionRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isSelected: Bool
}
