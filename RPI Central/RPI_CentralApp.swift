//  RPI_CentralApp.swift
//  RPI Central

import SwiftUI

@main
struct RPI_CentralApp: App {
    @UIApplicationDelegateAdaptor(FirebaseAppDelegate.self) private var firebaseAppDelegate
    @StateObject private var calendarViewModel = CalendarViewModel()
    @StateObject private var socialManager = SocialManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarViewModel)
                .environmentObject(socialManager)
                // ✅ persisted theme tint
                .tint(calendarViewModel.themeColor)
                // ✅ persisted system/light/dark (default dark)
                .preferredColorScheme(calendarViewModel.appearanceMode.colorScheme)
        }
    }
}
