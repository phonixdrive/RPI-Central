//
//  SocialFriendsView.swift
//  RPI Central
//

import SwiftUI

struct SocialFriendsView: View {
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.socialActions) private var actions

    var body: some View {
        let friends = socialManager.overview?.friends ?? []
        let requests = socialManager.overview?.incomingRequests ?? []

        List {
            if socialManager.overview == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading friends…")
                        .foregroundStyle(.secondary)
                }
            } else {
                if !requests.isEmpty {
                    Section("Requests") {
                        ForEach(requests) { request in
                            FriendRequestRow(request: request)
                        }
                    }
                }

                if friends.isEmpty {
                    ContentUnavailableView {
                        Label("No Friends Yet", systemImage: "person.2")
                    } description: {
                        Text("Find classmates by name or username.")
                    } actions: {
                        Button("Add Friends", action: actions.addFriends)
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section(friends.count == 1 ? "1 Friend" : "\(friends.count) Friends") {
                        ForEach(friends) { friend in
                            friendRow(friend)
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .refreshable { await socialManager.refreshOverview() }
    }

    private func friendRow(_ friend: SocialFriend) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                SocialAvatar(id: friend.id, name: friend.displayName)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(friend.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        FriendUpdatedText(friend: friend)
                    }
                    FriendActivityLine(friend: friend, showsDetail: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.openProfile(friend.asUser) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.openProfile(friend.asUser) }

            if friend.canViewSchedule {
                Button {
                    actions.openSchedule(friend)
                } label: {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .foregroundStyle(calendarViewModel.themeColor)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(friend.displayName)’s schedule")
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if let chat = socialManager.directMessageReference(with: friend) {
                Button("Message", systemImage: "message.fill") {
                    actions.openChat(chat)
                }
                .tint(calendarViewModel.themeColor)
            }
        }
        .contextMenu {
            if let chat = socialManager.directMessageReference(with: friend) {
                Button("Message", systemImage: "message") {
                    actions.openChat(chat)
                }
            }
            if friend.canViewSchedule {
                Button("View Schedule", systemImage: "calendar") {
                    actions.openSchedule(friend)
                }
            }
            Button("View Profile", systemImage: "person.crop.circle") {
                actions.openProfile(friend.asUser)
            }
        }
    }
}

/// An incoming friend request with accept and decline buttons.
struct FriendRequestRow: View {
    let request: SocialFriendRequest

    @EnvironmentObject private var socialManager: SocialManager
    @Environment(\.socialActions) private var actions
    @State private var isResponding = false

    var body: some View {
        let user = request.fromUser

        HStack(spacing: 12) {
            HStack(spacing: 12) {
                SocialAvatar(id: user?.id ?? request.id, name: user?.displayName ?? "?")
                VStack(alignment: .leading, spacing: 2) {
                    Text(user?.displayName ?? "Unknown")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("@\(user?.username ?? "unknown")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let user { actions.openProfile(user) }
            }

            Button {
                respond("decline")
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.secondary)
            .accessibilityLabel("Decline")

            Button {
                respond("accept")
            } label: {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Accept")
        }
        .disabled(isResponding)
    }

    private func respond(_ action: String) {
        isResponding = true
        Task {
            await socialManager.respondToFriendRequest(request.id, action: action)
            isResponding = false
        }
    }
}
