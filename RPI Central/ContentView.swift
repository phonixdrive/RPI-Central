//  ContentView.swift
//  RPI Central

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                CalendarView()
            }
            .tabItem {
                Label("Calendar", systemImage: "calendar")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(calendarViewModel.themeColor.color)
    }
}

#Preview {
    ContentView()
        .environmentObject(CalendarViewModel())
}
