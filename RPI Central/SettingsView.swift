//
//  SettingsView.swift
//  RPI Central
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel

    @State private var selectedTheme: AppThemeColor = .blue
    @State private var selectedAppearance: AppAppearanceMode = .dark
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Form {
                // APPEARANCE
                Section(header: Text("Appearance")) {
                    Picker("Mode", selection: $selectedAppearance) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

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

                Section(header: Text("Academic History")) {
                    Picker("Started college", selection: $calendarViewModel.academicHistoryStartSemester) {
                        ForEach(Semester.allCases.sorted(by: { $0.rawValue > $1.rawValue })) { semester in
                            Text(semester.displayName).tag(semester)
                        }
                    }
                }

                // NOTIFICATIONS (UI only – wiring to real notifications can come later)
                Section(header: Text("Notifications")) {
                    Toggle("Enable class reminders", isOn: $calendarViewModel.notificationsEnabled)

                    if calendarViewModel.notificationsEnabled {
                        HStack {
                            Text("Remind me")
                            Spacer()
                            Text("\(calendarViewModel.minutesBeforeClass) min before")
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(calendarViewModel.minutesBeforeClass) },
                                set: { calendarViewModel.minutesBeforeClass = Int($0) }
                            ),
                            in: 0...120,
                            step: 5
                        )

                        // ✅ temporary debug button
                        Button("Test notification (5 seconds)") {
                            NotificationManager.requestAuthorization()
                            NotificationManager.scheduleTestNotification()
                        }
                    }
                }

                Section(
                    header: Text("Home Dashboard"),
                    footer: Text("Toggle sections on or off, then use Edit to rearrange them.")
                ) {
                    ForEach(calendarViewModel.homeSectionOrder) { section in
                        HStack {
                            Toggle(
                                section.title,
                                isOn: Binding(
                                    get: { calendarViewModel.isHomeSectionEnabled(section) },
                                    set: { calendarViewModel.setHomeSection(section, enabled: $0) }
                                )
                            )
                            .toggleStyle(.switch)

                            if editMode == .active {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        calendarViewModel.moveHomeSections(from: source, to: destination)
                    }
                }

                Section(footer: Text("More settings can go here later (AI integration, academic calendar sync, etc.).")) {
                    EmptyView()
                }
            }
            .navigationTitle("Settings")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .onAppear {
            selectedTheme = AppThemeColor.from(color: calendarViewModel.themeColor)
            selectedAppearance = calendarViewModel.appearanceMode
        }
        .onChange(of: selectedTheme) {
            calendarViewModel.themeColor = selectedTheme.color
        }
        .onChange(of: selectedAppearance) {
            calendarViewModel.appearanceMode = selectedAppearance
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
