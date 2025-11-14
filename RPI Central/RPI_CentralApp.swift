//
//  RPI_CentralApp.swift
//  RPI Central
//
//  Created by Neil Shrestha on 10/3/25.
//

import SwiftUI

@main
struct RPI_CentralApp: App {
    @StateObject private var calendarViewModel = CalendarViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(calendarViewModel)
        }
    }
}
