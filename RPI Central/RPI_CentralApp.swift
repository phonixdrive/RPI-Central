//  RPI_CentralApp.swift
//  RPI Central

import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct RPI_CentralApp: App {
    @UIApplicationDelegateAdaptor(FirebaseAppDelegate.self) private var firebaseAppDelegate
    @StateObject private var calendarViewModel = CalendarViewModel()
    @StateObject private var socialManager = SocialManager()

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
                // ✅ persisted theme tint
                .tint(calendarViewModel.themeColor)
                // ✅ persisted system/light/dark (default dark)
                .preferredColorScheme(calendarViewModel.appearanceMode.colorScheme)
        }
    }
}
