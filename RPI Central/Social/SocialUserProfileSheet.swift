//
//  SocialUserProfileSheet.swift
//  RPI Central
//

import SwiftUI

struct SocialUserProfileSheet: View {
    let user: SocialUser

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var moderationState = SocialModerationState(isBanned: false, mutedUntil: nil)
    @State private var moderationLoaded = false
    @State private var isModerating = false
    @State private var isUpdatingRelationship = false
    @State private var showRemoveFriendConfirmation = false
    @State private var selectedFriendSchedule: FriendSchedulePresentation?
    @State private var selectedDirectMessage: SocialGroupChatReference?

    private var isCurrentUser: Bool {
        socialManager.currentUser?.id == user.id
    }

    private var isFriend: Bool {
        socialManager.overview?.friends.contains(where: { $0.id == user.id }) == true
    }

    private var friend: SocialFriend? {
        socialManager.overview?.friends.first(where: { $0.id == user.id })
    }

    private var incomingRequest: SocialFriendRequest? {
        socialManager.overview?.incomingRequests.first(where: { $0.fromUser?.id == user.id })
    }

    private var hasOutgoingRequest: Bool {
        socialManager.overview?.outgoingRequests.contains(where: { $0.toUser?.id == user.id }) == true
    }

    private var canModerateUser: Bool {
        socialManager.canModerateSocialContent && !isCurrentUser
    }

    private var moderationStatusText: String {
        if moderationState.isBanned {
            return "This account is banned from social."
        }
        if let mutedUntil = moderationState.mutedUntil, mutedUntil > Date() {
            return "Muted until \(DateFormatter.localizedString(from: mutedUntil, dateStyle: .medium, timeStyle: .short))."
        }
        return "No moderation actions active."
    }

    private var relationshipLabel: String {
        if isCurrentUser { return "Your profile" }
        if isFriend { return "Friend" }
        if incomingRequest != nil { return "Request received" }
        if hasOutgoingRequest { return "Request sent" }
        return user.isGuest ? "Guest account" : "RPI Central member"
    }

    private var relationshipIcon: String {
        if isCurrentUser { return "person.crop.circle.fill" }
        if isFriend { return "checkmark.circle.fill" }
        if incomingRequest != nil { return "person.crop.circle.badge.plus" }
        if hasOutgoingRequest { return "clock.fill" }
        return "person.crop.circle"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        SocialAvatar(id: user.id, name: user.displayName, size: 88)

                        Text(user.displayName)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("@\(user.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !isFriend {
                            Label(relationshipLabel, systemImage: relationshipIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(calendarViewModel.themeColor)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    if let friend {
                        HStack(alignment: .top) {
                            FriendActivityLine(friend: friend, showsDetail: true)
                            Spacer(minLength: 8)
                            FriendUpdatedText(friend: friend)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if let request = incomingRequest {
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    isUpdatingRelationship = true
                                    await socialManager.respondToFriendRequest(request.id, action: "accept")
                                    isUpdatingRelationship = false
                                    dismiss()
                                }
                            } label: {
                                Label("Accept", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                Task {
                                    isUpdatingRelationship = true
                                    await socialManager.respondToFriendRequest(request.id, action: "decline")
                                    isUpdatingRelationship = false
                                    dismiss()
                                }
                            } label: {
                                Text("Decline")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(isUpdatingRelationship)
                    } else if let friend {
                        HStack(spacing: 10) {
                            if let directMessage = socialManager.directMessageReference(with: friend) {
                                Button {
                                    selectedDirectMessage = directMessage
                                } label: {
                                    Label("Message", systemImage: "message.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if friend.canViewSchedule {
                                Button {
                                    selectedFriendSchedule = FriendSchedulePresentation(
                                        friend: friend,
                                        cachedResponse: socialManager.cachedFriendSchedule(for: friend)
                                    )
                                } label: {
                                    Label("Schedule", systemImage: "calendar")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Label("Schedule private", systemImage: "calendar.badge.minus")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }

                            Menu {
                                Button(role: .destructive) {
                                    showRemoveFriendConfirmation = true
                                } label: {
                                    Label("Remove friend", systemImage: "person.crop.circle.badge.minus")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 42, height: 34)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if !isCurrentUser && !hasOutgoingRequest {
                        Button {
                            Task {
                                isUpdatingRelationship = true
                                await socialManager.sendFriendRequest(toUserID: user.id)
                                isUpdatingRelationship = false
                            }
                        } label: {
                            Label(
                                isUpdatingRelationship ? "Sending…" : "Add friend",
                                systemImage: "person.badge.plus"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdatingRelationship)
                    }

                    if canModerateUser {
                        SocialCard {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(moderationLoaded ? moderationStatusText : "Loading status…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        Button("Mute 24h") {
                                            Task { await applyMute(days: 1) }
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Mute 7d") {
                                            Task { await applyMute(days: 7) }
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Unmute") {
                                            Task { await applyMute(days: nil) }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!moderationState.isMuted())
                                    }

                                    Button(moderationState.isBanned ? "Unban account" : "Ban account") {
                                        Task { await applyBan(!moderationState.isBanned) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(moderationState.isBanned ? calendarViewModel.themeColor : .red)
                                }
                                .padding(.top, 10)
                                .disabled(isModerating)
                            } label: {
                                Label("Moderator tools", systemImage: "shield.lefthalf.filled")
                                    .font(.headline)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: user.id) {
                guard canModerateUser else { return }
                moderationLoaded = false
                moderationState = await socialManager.moderationState(for: user.id)
                moderationLoaded = true
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Remove \(user.displayName) from your friends?",
                isPresented: $showRemoveFriendConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Friend", role: .destructive) {
                    Task {
                        isUpdatingRelationship = true
                        await socialManager.unfriend(user.id)
                        isUpdatingRelationship = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $selectedFriendSchedule) { presentation in
                FriendScheduleLoadingView(presentation: presentation)
            }
            .sheet(item: $selectedDirectMessage) { reference in
                GroupChatSheet(reference: reference)
            }
        }
    }

    private func applyMute(days: Int?) async {
        guard canModerateUser else { return }
        isModerating = true
        let until = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date()) ?? Date() }
        let success = await socialManager.setUserMuted(until: until, userID: user.id)
        if success {
            moderationState = await socialManager.moderationState(for: user.id)
            moderationLoaded = true
        }
        isModerating = false
    }

    private func applyBan(_ banned: Bool) async {
        guard canModerateUser else { return }
        isModerating = true
        let success = await socialManager.setUserBanned(banned, userID: user.id)
        if success {
            moderationState = await socialManager.moderationState(for: user.id)
            moderationLoaded = true
        }
        isModerating = false
    }
}
