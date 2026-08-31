//  ContentView.swift
//  RPI Central

import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var externalCalendarSyncManager: ExternalCalendarSyncManager
    @ObservedObject private var courseCatalog = CourseCatalogService.shared
    @State private var selectedTab: RootTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            tabContent(HomeView())
                .tag(RootTab.home)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            tabContent(CalendarView())
                .tag(RootTab.calendar)
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            tabContent(CoursesView())
                .tag(RootTab.courses)
                .tabItem {
                    Label("Courses", systemImage: "book")
                }

            tabContent(SocialHubView())
                .tag(RootTab.social)
                .tabItem {
                    Label("Social", systemImage: "person.2.fill")
                }

            tabContent(SettingsView())
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
        .onReceive(NotificationCenter.default.publisher(for: .openCalendarTab)) { _ in
            selectedTab = .calendar
        }
    }

    private func tabContent<Content: View>(_ content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let loadingStatusText {
                    AppLoadingStatusBar(
                        statusText: loadingStatusText,
                        tint: calendarViewModel.themeColor
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: loadingStatusText)
    }

    private var loadingStatusText: String? {
        var labels: [String] = []

        if courseCatalog.loadingSemester != nil {
            labels.append("course catalog")
        }
        if !calendarViewModel.refreshingEnrollmentSemesterCodes.isEmpty {
            labels.append("saved classes")
        }
        if !calendarViewModel.loadingAcademicYearStarts.isEmpty {
            labels.append("academic calendar")
        }
        if !calendarViewModel.loadingTermBoundsSemesterCodes.isEmpty {
            labels.append("term dates")
        }
        if externalCalendarSyncManager.isSyncing {
            labels.append("Google/Outlook calendars")
        }

        guard !labels.isEmpty else { return nil }
        return "Loading: \(labels.joined(separator: " • "))\u{2026}"
    }

    private func applyThemeTintToUIKitChrome() {
        let uiColor = UIColor(calendarViewModel.themeColor)
        UITabBar.appearance().tintColor = uiColor
        UINavigationBar.appearance().tintColor = uiColor
        UIBarButtonItem.appearance().tintColor = uiColor
    }
}

private struct AppLoadingStatusBar: View {
    let statusText: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)

                Text(statusText)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 0)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
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
        .environmentObject(ExternalCalendarSyncManager())
        .environmentObject(AppStateSyncManager())
}
