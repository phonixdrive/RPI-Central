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
    @StateObject private var appStateSyncManager = AppStateSyncManager()
    @State private var selectedTheme: AppThemeColor = .blue
    @State private var selectedAppearance: AppAppearanceMode = .dark
    @State private var editMode: EditMode = .inactive
    @State private var isSyncingLMSCalendar = false
    @State private var showingRecoveryBackups = false

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
                        header: Text("Current Term"),
                        footer: Text("This is the term the app treats as happening now. Upcoming assignments, reminders, and Flex Dollars use this term.")
                    ) {
                        Picker(
                            "Current term",
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

                    Section(
                        header: Text("Show Terms Through"),
                        footer: Text("This controls how far ahead Home and the calendar can display terms. Use it to preview future schedules without changing the current term.")
                    ) {
                        Picker(
                            "Latest term shown",
                            selection: Binding(
                                get: { calendarViewModel.visibleSemester },
                                set: { calendarViewModel.changeVisibleSemester(to: $0) }
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
                        header: Text("Phone and Web Sync"),
                        footer: Text("Use Save This Phone after making changes on this iPhone. Use Get Latest Saved Copy after making changes on your laptop or web. Recovery backups are your safety copies if you ever want to roll something back.")
                    ) {
                        HStack {
                            Text("Latest saved copy")
                            Spacer()
                            Text(syncTimestampText(appStateSyncManager.cloudSnapshotUpdatedAt))
                                .foregroundStyle(.secondary)
                        }

                        if let message = appStateSyncManager.cloudSyncMessage, !message.isEmpty {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        if let error = appStateSyncManager.cloudSyncError, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task {
                                _ = await appStateSyncManager.pushPhoneToCloud(
                                    calendarViewModel: calendarViewModel,
                                    socialManager: socialManager
                                )
                            }
                        } label: {
                            Label(
                                appStateSyncManager.cloudSyncBusy ? "Working…" : "Save this phone",
                                systemImage: "arrow.up.circle.fill"
                            )
                        }
                        .disabled(!appStateSyncManager.cloudSyncReady || appStateSyncManager.cloudSyncBusy)

                        Button {
                            Task {
                                _ = await appStateSyncManager.pullCloudToPhone(
                                    calendarViewModel: calendarViewModel,
                                    socialManager: socialManager
                                )
                            }
                        } label: {
                            Label("Get latest saved copy", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(!appStateSyncManager.cloudSyncReady || appStateSyncManager.cloudSyncBusy)

                        Button {
                            showingRecoveryBackups = true
                        } label: {
                            HStack {
                                Label("Recovery backups", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                Spacer()
                                Text("\(appStateSyncManager.cloudBackups.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(!appStateSyncManager.cloudSyncReady)
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
        .task {
            await appStateSyncManager.refresh()
        }
        .sheet(isPresented: $showingRecoveryBackups) {
            recoveryBackupsView
                .presentationDetents([.medium, .large])
        }
    }

    private func syncTimestampText(_ value: String?) -> String {
        guard let value, let date = SyncISO8601.date(from: value) else {
            return "Not saved yet"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func backupTitle(_ backup: PhoneWebCloudBackupSummary) -> String {
        switch backup.label {
        case "Manual backup", "Recovery backup", "Before Recovery Backup (Current iPhone)":
            return "Before Recovery Backup (Current iPhone)"
        case "Before push • local phone state", "This phone before saving", "Phone before save", "Before Save This Phone: this phone", "Before Save (Current iPhone)":
            return "Before Save (Current iPhone)"
        case "Before push • cloud snapshot", "Latest saved copy before saving this phone", "Saved copy before save", "Before Save This Phone: previous saved copy", "Saved Copy Replaced by Save":
            return "Saved Copy Replaced by Save"
        case "Before pull • local phone state", "This phone before updating", "Phone before update", "Before Get Latest Saved Copy: this phone", "Before Update (Current iPhone)":
            return "Before Update (Current iPhone)"
        case "Before restore • local phone state", "This phone before restore", "Phone before restore", "Before Restore: this phone", "Before Restore (Current iPhone)":
            return "Before Restore (Current iPhone)"
        case "Before restore • cloud snapshot", "Latest saved copy before restore", "Saved copy before restore", "Before Restore: previous saved copy", "Saved Copy Replaced by Restore":
            return "Saved Copy Replaced by Restore"
        default:
            return backup.label
        }
    }

    private func backupSourceText(_ source: String) -> String {
        if source == "ios-manual" {
            return "Saved from your current iPhone"
        }
        if source.hasPrefix("ios") {
            return "Saved from your iPhone right before a change"
        }
        if source.hasPrefix("cloud:") {
            return "Saved from the copy that was replaced"
        }
        if source.hasPrefix("restore:") {
            return "Saved while restoring an older backup"
        }
        return "Saved from \(source)"
    }

    private var recoveryBackupsView: some View {
        NavigationStack {
            List {
                Section(
                    footer: Text("Save This Phone makes two safety backups: one of your current iPhone before the save, and one of the saved copy that gets replaced.")
                ) {
                    Button {
                        Task {
                            _ = await appStateSyncManager.createCloudBackup(
                                calendarViewModel: calendarViewModel
                            )
                        }
                    } label: {
                        Label(
                            appStateSyncManager.cloudSyncBusy ? "Working…" : "Create recovery backup",
                            systemImage: "externaldrive.badge.plus"
                        )
                    }
                    .disabled(!appStateSyncManager.cloudSyncReady || appStateSyncManager.cloudSyncBusy)
                }

                if let message = appStateSyncManager.cloudSyncMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if let error = appStateSyncManager.cloudSyncError, !error.isEmpty {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section(header: Text("Saved backups")) {
                    if appStateSyncManager.cloudBackups.isEmpty {
                        Text("No recovery backups yet. Your first save, update, or restore will create them automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appStateSyncManager.cloudBackups) { backup in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(backupTitle(backup))
                                    .font(.subheadline.weight(.semibold))

                                Text("Saved \(syncTimestampText(backup.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(backupSourceText(backup.source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Button("Restore") {
                                        Task {
                                            _ = await appStateSyncManager.restoreCloudBackup(
                                                backup.id,
                                                calendarViewModel: calendarViewModel,
                                                socialManager: socialManager
                                            )
                                        }
                                    }
                                    .disabled(!appStateSyncManager.cloudSyncReady || appStateSyncManager.cloudSyncBusy)

                                    Button("Delete", role: .destructive) {
                                        Task {
                                            _ = await appStateSyncManager.deleteCloudBackup(backup.id)
                                        }
                                    }
                                    .disabled(!appStateSyncManager.cloudSyncReady || appStateSyncManager.cloudSyncBusy)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Recovery Backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showingRecoveryBackups = false
                    }
                }
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
