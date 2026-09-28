//
//  SocialProfileSheet.swift
//  RPI Central
//
//  Your own profile: name, what you share, and account actions.
//

import SwiftUI

struct SocialProfileSheet: View {
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @EnvironmentObject private var locationManager: LocationSharingManager
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var showLocationSettings = false
    @State private var showDeleteConfirmation = false

    private var user: SocialUser? { socialManager.currentUser }
    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { !trimmedName.isEmpty && trimmedName != user?.displayName }

    var body: some View {
        NavigationStack {
            Form {
                if let user {
                    Section {
                        HStack(spacing: 14) {
                            SocialAvatar(id: user.id, name: user.displayName, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName)
                                    .font(.title3.weight(.semibold))
                                Text("@\(user.username)")
                                    .foregroundStyle(.secondary)
                                if user.isGuest {
                                    Text("Guest")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Display Name") {
                        HStack {
                            TextField("Display name", text: $displayName)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit(saveName)
                            if nameChanged {
                                Button("Save", action: saveName)
                                    .buttonStyle(.borderless)
                                    .disabled(socialManager.isLoading)
                            }
                        }
                    }

                    sharingSection(for: user)

                    Section {
                        Button("Sign Out") {
                            socialManager.logout()
                            dismiss()
                        }
                        Button("Delete Account", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }

                    #if DEBUG
                    if calendarViewModel.socialDemoToolsEnabled {
                        Section("Developer") {
                            Button("Seed Demo Social Data") {
                                Task { await socialManager.seedDemoData(for: calendarViewModel) }
                            }
                            .disabled(socialManager.isLoading)
                        }
                    }
                    #endif
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { displayName = user?.displayName ?? "" }
            .sheet(isPresented: $showLocationSettings) {
                LocationSharingSettingsView()
            }
            .confirmationDialog(
                "Delete your RPI Central account?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task {
                        if await socialManager.requestAccountDeletion() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This deletes your friends, chats, and shared data. Your calendar stays on this phone.")
            }
        }
    }

    private func sharingSection(for user: SocialUser) -> some View {
        Section("Sharing") {
            Toggle(isOn: Binding(
                get: { user.shareSchedule },
                set: { newValue in
                    Task {
                        await socialManager.updateShareSettings(
                            shareSchedule: newValue,
                            shareLocation: user.shareLocation
                        )
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Text("Share Schedule")
                    InfoButton("Friends see your classes and events for the whole term, so their view stays right even if you don’t open the app for a while.")
                }
            }

            if user.shareSchedule {
                HStack {
                    if let publish = socialManager.lastSchedulePublish {
                        Text("Through \(publish.coverageEnd.formatted(.dateTime.month(.abbreviated).day()))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") {
                        Task { await socialManager.syncSchedule(from: calendarViewModel) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(socialManager.isLoading)
                }
                .font(.subheadline)
            }

            Button {
                showLocationSettings = true
            } label: {
                HStack {
                    Text("Location")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(locationManager.isSharingActive ? "Sharing" : "Ghost Mode")
                        .foregroundStyle(Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
        }
    }

    private func saveName() {
        guard nameChanged else { return }
        Task { await socialManager.updateDisplayName(trimmedName) }
    }
}
