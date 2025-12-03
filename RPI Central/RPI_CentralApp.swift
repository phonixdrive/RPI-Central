//  RPI_CentralApp.swift
//  RPI Central

import SwiftUI

@main
struct RPI_CentralApp: App {
    @StateObject private var calendarViewModel = CalendarViewModel()
    @StateObject private var courseCatalogService = CourseCatalogService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarViewModel)
                .environmentObject(courseCatalogService)
        }
    }
}
