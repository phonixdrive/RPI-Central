//  RPI_CentralApp.swift
//  RPI Central

import SwiftUI

@main
struct RPI_CentralApp: App {
    @StateObject private var calendarViewModel = CalendarViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarViewModel)
                // ✅ persisted theme tint
                .tint(calendarViewModel.themeColor)
                // ✅ persisted system/light/dark (default dark)
                .preferredColorScheme(calendarViewModel.appearanceMode.colorScheme)
        }
    }
}
