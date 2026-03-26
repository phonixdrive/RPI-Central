//  ContentView.swift
//  RPI Central

import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @State private var selectedTab: RootTab = .home
    @State private var homeRefreshToken = UUID()

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .id(homeRefreshToken)
                .tag(RootTab.home)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            CalendarView()
                .tag(RootTab.calendar)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            CoursesView()
                .tag(RootTab.courses)
                .tabItem {
                    Label("Courses", systemImage: "book")
                }

            SocialHubView()
                .tag(RootTab.social)
                .tabItem {
                    Label("Social", systemImage: "person.2.fill")
                }

            SettingsView()
                .tag(RootTab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(calendarViewModel.themeColor)
        .onAppear {
            applyThemeTintToUIKitChrome()
        }
        .onChange(of: calendarViewModel.themeColor) { _, _ in
            applyThemeTintToUIKitChrome()
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if oldValue == .social && newValue == .home {
                applyThemeTintToUIKitChrome()
                homeRefreshToken = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCalendarTab)) { _ in
            selectedTab = .calendar
        }
    }

    private func applyThemeTintToUIKitChrome() {
        let uiColor = UIColor(calendarViewModel.themeColor)
        UITabBar.appearance().tintColor = uiColor
        UINavigationBar.appearance().tintColor = uiColor
        UIBarButtonItem.appearance().tintColor = uiColor
    }
}

private enum RootTab: Hashable {
    case home
    case calendar
    case courses
    case social
    case settings
}

extension Notification.Name {
    static let openCalendarTab = Notification.Name("openCalendarTab")
}

#Preview {
    ContentView()
        .environmentObject(CalendarViewModel())
        .environmentObject(SocialManager())
}
