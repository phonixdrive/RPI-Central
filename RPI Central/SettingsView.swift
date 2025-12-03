//  SettingsView.swift
//  RPI Central

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme color", selection: $calendarViewModel.themeColor) {
                        ForEach(AppThemeColor.allCases) { theme in
                            HStack {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 14, height: 14)
                                Text(theme.label)
                            }
                            .tag(theme)
                        }
                    }
                }

                Section("Notifications") {
                    Toggle("Enable class reminders",
                           isOn: $calendarViewModel.notificationsEnabled)
                        .onChange(of: calendarViewModel.notificationsEnabled) { _, _ in
                            calendarViewModel.rescheduleNotificationsIfNeeded()
                        }

                    Stepper(
                        value: $calendarViewModel.notificationLeadMinutes,
                        in: 5...60,          // ✅ ClosedRange<Int>
                        step: 5
                    ) {
                        Text("Remind me \(calendarViewModel.notificationLeadMinutes) min before")
                    }
                    .disabled(!calendarViewModel.notificationsEnabled)
                    .onChange(of: calendarViewModel.notificationLeadMinutes) { _, _ in
                        calendarViewModel.rescheduleNotificationsIfNeeded()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
