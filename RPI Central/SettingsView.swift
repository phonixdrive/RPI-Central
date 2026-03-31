//
//  SettingsView.swift
//  RPI Central
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager

    @AppStorage("shuttle_tracker_refresh_interval_seconds") private var shuttleTrackerRefreshIntervalSeconds = 5
    @AppStorage("social_show_campus_wide_group") private var showCampusWideGroup = true
    @State private var selectedTheme: AppThemeColor = .blue
    @State private var selectedAppearance: AppAppearanceMode = .dark
    @State private var editMode: EditMode = .inactive
    @State private var isSyncingLMSCalendar = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Form {
                    // APPEARANCE
                    Section(header: Text("Appearance")) {
                        Picker("Mode", selection: $selectedAppearance) {
                            ForEach(AppAppearanceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Picker("Theme color", selection: $selectedTheme) {
                            ForEach(AppThemeColor.allCases) { theme in
                                HStack {
                                    Circle()
                                        .fill(theme.color)
                                        .frame(width: 16, height: 16)
                                    Text(theme.displayName)
                                }
                                .tag(theme)
                            }
                        }
                    }

                    Section(
                        header: Text("Home Dashboard"),
                        footer: Text("Tap Edit, then drag with the handle on the right to reorder your Home blocks.")
                    ) {
                        ForEach(calendarViewModel.homeSectionOrder) { section in
                            HStack(spacing: 12) {
                                Toggle(
                                    section.title,
                                    isOn: Binding(
                                        get: { calendarViewModel.isHomeSectionEnabled(section) },
                                        set: { calendarViewModel.setHomeSection(section, enabled: $0) }
                                    )
                                )
                                .toggleStyle(.switch)

                                Image(systemName: "line.3.horizontal")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onMove { source, destination in
                            calendarViewModel.moveHomeSections(from: source, to: destination)
                        }
                    }

                    // PREREQS
                    Section(header: Text("Courses")) {
                        Toggle("Enforce prerequisites", isOn: $calendarViewModel.enforcePrerequisites)
                        Text("If enabled, courses with missing prerequisites require a second tap to bypass.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(
                        header: Text("Visible Term"),
                        footer: Text("Controls which term Home and the main calendar treat as current. Terms up through this one will show on Home.")
                    ) {
                        Picker(
                            "Home and calendar term",
                            selection: Binding(
                                get: { calendarViewModel.currentSemester },
                                set: { calendarViewModel.changeSemester(to: $0) }
                            )
                        ) {
                            ForEach(Semester.allCases.sorted(by: { $0.rawValue > $1.rawValue })) { semester in
                                Text(semester.displayName).tag(semester)
                            }
                        }
                    }

                    Section(header: Text("Academic History")) {
                        Picker("Started college", selection: $calendarViewModel.academicHistoryStartSemester) {
                            ForEach(Semester.allCases.sorted(by: { $0.rawValue > $1.rawValue })) { semester in
                                Text(semester.displayName).tag(semester)
                            }
                        }
                    }

                    Section(
                        header: Text("LMS Calendar"),
                        footer: Text("Paste your Blackboard calendar feed URL here to import LMS events into your calendar. The link is private to your account, so don’t share it.")
                    ) {
                        Toggle("Auto daily sync", isOn: $calendarViewModel.lmsCalendarAutoDailySyncEnabled)

                        TextField("https://lms.rpi.edu/.../learn.ics", text: $calendarViewModel.lmsCalendarFeedURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()

                        Button {
                            Task {
                                guard !isSyncingLMSCalendar else { return }
                                isSyncingLMSCalendar = true
                                _ = await calendarViewModel.syncLMSCalendarFeed(force: true)
                                isSyncingLMSCalendar = false
                            }
                        } label: {
                            HStack {
                                if isSyncingLMSCalendar {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isSyncingLMSCalendar ? "Syncing…" : "Sync Blackboard calendar")
                            }
                        }
                        .disabled(isSyncingLMSCalendar || calendarViewModel.lmsCalendarFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let lastSync = calendarViewModel.lmsCalendarLastSyncAt {
                            HStack {
                                Text("Last synced")
                                Spacer()
                                Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let syncStatus = calendarViewModel.lmsCalendarSyncStatus, !syncStatus.isEmpty {
                            Text(syncStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section(
                        header: Text("Social"),
                        footer: Text("Demo social tools add seeded test users and requests to help you test the Firebase social features.")
                    ) {
                        Toggle("Show All RPI Students group", isOn: $showCampusWideGroup)
                        Toggle("Enable demo social tools", isOn: $calendarViewModel.socialDemoToolsEnabled)

                        Picker("Feed auto-refresh", selection: $calendarViewModel.socialFeedRefreshIntervalSeconds) {
                            ForEach(SocialFeedRefreshOption.allCases) { option in
                                Text(option.title).tag(option.seconds)
                            }
                        }
                    }

                    Section(header: Text("Notifications")) {
                        Toggle("Enable calendar reminders", isOn: $calendarViewModel.notificationsEnabled)
                        Toggle("Enable feed and shared-event alerts", isOn: $calendarViewModel.socialFeedNotificationsEnabled)

                        if calendarViewModel.notificationsEnabled {
                            HStack {
                                Text("Remind me")
                                Spacer()
                                Text("\(calendarViewModel.minutesBeforeClass) min before")
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(calendarViewModel.minutesBeforeClass) },
                                    set: { calendarViewModel.minutesBeforeClass = Int($0) }
                                ),
                                in: 0...120,
                                step: 5
                            )

                            // ✅ temporary debug button
                            Button("Test notification (5 seconds)") {
                                NotificationManager.requestAuthorization()
                                NotificationManager.scheduleTestNotification()
                            }
                        }
                    }

                    Section(
                        header: Text("Shuttle Tracker"),
                        footer: Text("Shorter refresh intervals feel more live, but they use more battery and network.")
                    ) {
                        Picker("Refresh interval", selection: $shuttleTrackerRefreshIntervalSeconds) {
                            Text("1 second").tag(1)
                            Text("2 seconds").tag(2)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .onAppear {
            selectedTheme = AppThemeColor.from(color: calendarViewModel.themeColor)
            selectedAppearance = calendarViewModel.appearanceMode
        }
        .onChange(of: selectedTheme) {
            calendarViewModel.themeColor = selectedTheme.color
        }
        .onChange(of: selectedAppearance) {
            calendarViewModel.appearanceMode = selectedAppearance
        }
        .onChange(of: calendarViewModel.socialFeedNotificationsEnabled) {
            Task {
                await socialManager.syncPushNotificationPreferences()
            }
        }
    }
}

// MARK: - AppThemeColor helper enum

enum AppThemeColor: String, CaseIterable, Identifiable {
    case blue, red, green, purple, orange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:   return "Blue"
        case .red:    return "Red"
        case .green:  return "Green"
        case .purple: return "Purple"
        case .orange: return "Orange"
        }
    }

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .purple: return .purple
        case .orange: return .orange
        }
    }

    static func from(color: Color) -> AppThemeColor {
        if color == Color.red { return .red }
        if color == Color.green { return .green }
        if color == Color.purple { return .purple }
        if color == Color.orange { return .orange }
        return .blue
    }
}
