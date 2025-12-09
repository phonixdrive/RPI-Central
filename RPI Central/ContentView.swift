//  ContentView.swift
//  RPI Central

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            CoursesView()
                .tabItem {
                    Label("Courses", systemImage: "book")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        // IMPORTANT: use the Color itself, NOT a Binding
        .tint(calendarViewModel.themeColor)
    }
}

#Preview {
    ContentView()
        .environmentObject(CalendarViewModel())
}
