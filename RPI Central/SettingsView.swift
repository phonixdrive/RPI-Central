//
//  SettingsView.swift
//  RPI Central
//

import SwiftUI

struct SettingsView: View {
    private static let testFlightURL = URL(string: "https://testflight.apple.com/join/chA8WKUu")!
    private static let privacyURL = URL(string: "https://phonixdrive.github.io/RPI-Central/privacy.html")!
    private static let supportURL = URL(string: "https://phonixdrive.github.io/RPI-Central/support.html")!

    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @EnvironmentObject var externalCalendarSyncManager: ExternalCalendarSyncManager
    @EnvironmentObject var appStateSyncManager: AppStateSyncManager
    @EnvironmentObject var locationSharingManager: LocationSharingManager

    @AppStorage("shuttle_tracker_refresh_interval_seconds") private var shuttleTrackerRefreshIntervalSeconds = 5
    @AppStorage("social_show_campus_wide_group") private var showCampusWideGroup = true
    @AppStorage("courses_auto_collapse_prerequisites_v1") private var autoCollapseCoursePrerequisites = true
    @State private var selectedTheme: AppThemeColor = .blue
    @State private var selectedAppearance: AppAppearanceMode = .dark
    @State private var isSyncingLMSCalendar = false
    @State private var showingRecoveryBackups = false
    @State private var showingLocationSettings = false

    var body: some View {
        NavigationStack {
            settingsForm {
                appearanceSection

                Section("Academics") {
                    NavigationLink {
                        settingsForm {
                            currentTermSection
                            visibleTermsSection
                            academicHistorySection
                            coursesSection
                        }
                        .navigationTitle("Terms & Courses")
                    } label: {
                        settingsRow(
                            "Terms & Courses",
                            systemImage: "graduationcap.fill",
                            value: calendarViewModel.currentSemester.displayName
                                .replacingOccurrences(of: " (current term)", with: "")
                        )
                    }

                    NavigationLink {
                        settingsForm {
                            homeDashboardSection
                        }
                        .navigationTitle("Home Dashboard")
                    } label: {
                        settingsRow("Home Dashboard", systemImage: "square.grid.2x2.fill")
                    }
                }

                Section("Calendars & Sync") {
                    NavigationLink {
                        settingsForm {
                            phoneWebSyncSection
                        }
                        .navigationTitle("Phone & Web Sync")
                        .task {
                            await appStateSyncManager.refresh()
                        }
                    } label: {
                        settingsRow(
                            "Phone & Web Sync",
                            systemImage: "arrow.triangle.2.circlepath.icloud.fill",
                            value: appStateSyncManager.lastWeeklyBackupAt == nil ? nil : "Backed up"
                        )
                    }

                    NavigationLink {
                        settingsForm {
                            lmsCalendarSection
                        }
                        .navigationTitle("Blackboard Calendar")
                    } label: {
                        settingsRow(
                            "Blackboard Calendar",
                            systemImage: "calendar.badge.clock",
                            value: calendarViewModel.lmsCalendarFeedURL.isEmpty ? "Off" : "On"
                        )
                    }

                    NavigationLink {
                        settingsForm {
                            externalCalendarsSection
                        }
                        .navigationTitle("Google & Outlook")
                    } label: {
                        settingsRow(
                            "Google & Outlook",
                            systemImage: "calendar",
                            value: externalCalendarSyncManager.selectedCalendarIDs.isEmpty
                                ? "Off"
                                : "\(externalCalendarSyncManager.selectedCalendarIDs.count) selected"
                        )
                    }
                }

                socialSection
                notificationsSection
                shuttleSection
                aboutSection
            }
            .navigationTitle("Settings")
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
        .onChange(of: calendarViewModel.academicHistoryStartSemester) {
            calendarViewModel.enforceAcademicHistoryBounds()
        }
        .onChange(of: calendarViewModel.socialFeedNotificationsEnabled) {
            Task {
                await socialManager.syncPushNotificationPreferences()
            }
        }
        .onChange(of: calendarViewModel.socialGroupNotificationsEnabled) {
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
        case "Weekly Automatic Backup":
            return "Weekly Automatic Backup"
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
        if source == "ios-weekly" {
            return "Saved automatically from your iPhone"
        }
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
