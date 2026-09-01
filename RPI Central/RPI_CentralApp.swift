//  RPI_CentralApp.swift
//  RPI Central

import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct RPI_CentralApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(FirebaseAppDelegate.self) private var firebaseAppDelegate
    @StateObject private var calendarViewModel = CalendarViewModel()
    @StateObject private var socialManager = SocialManager()
    @StateObject private var externalCalendarSyncManager = ExternalCalendarSyncManager()
    @StateObject private var appStateSyncManager = AppStateSyncManager()

    init() {
#if canImport(FirebaseCore)
        if FirebaseApp.app() == nil,
           let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: filePath) {
            FirebaseApp.configure(options: options)
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarViewModel)
                .environmentObject(socialManager)
                .environmentObject(externalCalendarSyncManager)
                .environmentObject(appStateSyncManager)
                // ✅ persisted theme tint
                .tint(calendarViewModel.themeColor)
                // ✅ persisted system/light/dark (default dark)
                .preferredColorScheme(calendarViewModel.appearanceMode.colorScheme)
                .task {
                    await externalCalendarSyncManager.autoSyncIfNeeded(into: calendarViewModel)
                    await appStateSyncManager.createWeeklyBackupIfNeeded(calendarViewModel: calendarViewModel)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .inactive || phase == .background {
                        calendarViewModel.persistHomeDashboardPreferences()
                        return
                    }
                    guard phase == .active else { return }
                    Task {
                        externalCalendarSyncManager.reloadAvailableCalendars()
                        await externalCalendarSyncManager.autoSyncIfNeeded(into: calendarViewModel)
                        await appStateSyncManager.createWeeklyBackupIfNeeded(calendarViewModel: calendarViewModel)
                    }
                }
        }
    }
}
