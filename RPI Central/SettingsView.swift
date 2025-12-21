//
//  SettingsView.swift
//  RPI Central
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    @State private var notificationsEnabled: Bool = true
    @State private var minutesBeforeClass: Double = 10
    @State private var selectedTheme: AppThemeColor = .blue

    var body: some View {
        NavigationStack {
            Form {
                // THEME
                Section(header: Text("Appearance")) {
                    Picker("Theme color", selection: $selectedTheme) {
                        ForEach(AppThemeColor.allCases) { theme in
                            HStack {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 16, height: 16)
                                Text(theme.displayName)
                            }
                            .tag(theme)
                        }
                    }
                }

                // PREREQS
                Section(header: Text("Courses")) {
                    Toggle("Enforce prerequisites", isOn: $calendarViewModel.enforcePrerequisites)
                    Text("If enabled, courses with missing prerequisites require a second tap to bypass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // NOTIFICATIONS (UI only – wiring to real notifications can come later)
                Section(header: Text("Notifications")) {
                    Toggle("Enable class reminders", isOn: $notificationsEnabled)

                    if notificationsEnabled {
                        HStack {
                            Text("Remind me")
                            Spacer()
                            Text("\(Int(minutesBeforeClass)) min before")
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $minutesBeforeClass,
                            in: 0...120,
                            step: 5
                        )
                    }
                }

                Section(footer: Text("More settings can go here later (AI integration, academic calendar sync, etc.).")) {
                    EmptyView()
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            selectedTheme = AppThemeColor.from(color: calendarViewModel.themeColor)
        }
        .onChange(of: selectedTheme) { newTheme in
            calendarViewModel.themeColor = newTheme.color
        }
    }
}

// MARK: - AppThemeColor helper enum

enum AppThemeColor: String, CaseIterable, Identifiable {
    case blue, red, green, purple, orange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:   return "Blue"
        case .red:    return "Red"
        case .green:  return "Green"
        case .purple: return "Purple"
        case .orange: return "Orange"
        }
    }

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .purple: return .purple
        case .orange: return .orange
        }
    }

    static func from(color: Color) -> AppThemeColor {
        if color == Color.red { return .red }
        if color == Color.green { return .green }
        if color == Color.purple { return .purple }
        if color == Color.orange { return .orange }
        return .blue
    }
}
