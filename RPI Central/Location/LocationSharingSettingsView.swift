//
//  LocationSharingSettingsView.swift
//  RPI Central
//

import CoreLocation
import SwiftUI

struct LocationSharingSettingsView: View {
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var locationManager: LocationSharingManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var duration: LocationShareDuration = .indefinitely

    private var friends: [SocialFriend] {
        (socialManager.overview?.friends ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                sharingSection

                if locationManager.isSignedIn {
                    audienceSection
                    precisionSection
                    backgroundSection
                }

                permissionSection
            }
            .navigationTitle("Location Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .tint(calendarViewModel.themeColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                duration = inferredDuration
            }
        }
    }

    private var sharingSection: some View {
        Section {
            Toggle(
                "Share my location",
                isOn: Binding(
                    get: { locationManager.isSharingActive },
                    set: { newValue in
                        Task { await locationManager.setSharingEnabled(newValue, duration: duration) }
                    }
                )
            )
            .disabled(!locationManager.isSignedIn)

            Picker("Share", selection: $duration) {
                ForEach(LocationShareDuration.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .onChange(of: duration) { _, newValue in
                guard locationManager.isSharingActive, newValue != inferredDuration else { return }
                locationManager.setDuration(newValue)
            }

            if locationManager.isSharingActive, let expiresAt = locationManager.settings.expiresAt {
                LabeledContent("Stops automatically", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
            }

            if let error = locationManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Sharing")
                InfoButton("Your location is saved only while sharing is on, and only the friends you choose can read it. Ghost Mode deletes it right away.")
            }
        } footer: {
            if !locationManager.isSignedIn {
                Text("Sign in on the Social tab to share.")
            }
        }
    }

    private var audienceSection: some View {
        Section {
            Picker(
                "Who can see you",
                selection: Binding(
                    get: { locationManager.settings.audience },
                    set: { locationManager.setAudience($0) }
                )
            ) {
                ForEach(LocationShareAudience.allCases) { audience in
                    Text(audience.title).tag(audience)
                }
            }

            if locationManager.settings.audience == .selectedFriends {
                if friends.isEmpty {
                    Text("You don't have any friends yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(friends) { friend in
                        let isSelected = locationManager.settings.selectedFriendIDs.contains(friend.id)
                        Button {
                            locationManager.setFriend(friend.id, selected: !isSelected)
                        } label: {
                            HStack(spacing: 12) {
                                SocialAvatar(id: friend.id, name: friend.displayName, size: 32)
                                Text(friend.displayName)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? calendarViewModel.themeColor : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Who can see you")
                InfoButton("Only friends can ever see your location. New friends are added automatically only with All friends.")
            }
        }
    }

    private var precisionSection: some View {
        Section {
            Picker(
                "Precision",
                selection: Binding(
                    get: { locationManager.settings.precision },
                    set: { locationManager.setPrecision($0) }
                )
            ) {
                ForEach(LocationSharePrecision.allCases) { precision in
                    Text(precision.title).tag(precision)
                }
            }
            .pickerStyle(.segmented)

            if locationManager.isAuthorized, !locationManager.hasFullAccuracy {
                Button("Allow precise location for building names") {
                    locationManager.requestPreciseAccuracy()
                }
            }
        } header: {
            Text("Precision")
        } footer: {
            Text(locationManager.settings.precision.detail)
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle(
                "Update when the app is closed",
                isOn: Binding(
                    get: { locationManager.settings.shareInBackground },
                    set: { locationManager.setShareInBackground($0) }
                )
            )

            if locationManager.settings.shareInBackground, locationManager.authorizationStatus != .authorizedAlways {
                Button("Allow “Always” location access") {
                    locationManager.openSystemSettings()
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Background updates")
                InfoButton("Like Find My, your location updates only after you move a good distance or reach another part of campus, so battery use stays low. Needs “Always” location access; otherwise friends see where you were when you last opened the app.")
            }
        }
    }

    private var permissionSection: some View {
        Section("Permission") {
            LabeledContent("Location access", value: permissionText)
            if locationManager.authorizationStatus == .notDetermined {
                Button("Allow location access") {
                    locationManager.requestPermission()
                }
            } else if locationManager.isAuthorizationDenied || locationManager.authorizationStatus == .authorizedWhenInUse {
                Button("Open iPhone Settings") {
                    locationManager.openSystemSettings()
                }
            }
        }
    }

    private var permissionText: String {
        switch locationManager.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var inferredDuration: LocationShareDuration {
        guard let expiresAt = locationManager.settings.expiresAt else { return .indefinitely }
        return expiresAt.timeIntervalSinceNow <= 60 * 60 + 60 ? .oneHour : .untilEndOfDay
    }
}
