//
//  AddFriendsSheet.swift
//  RPI Central
//
//  Search, friend requests, and classmate suggestions.
//

import SwiftUI

struct AddFriendsSheet: View {
    @EnvironmentObject private var socialManager: SocialManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchedQuery: String?
    @State private var profileUser: SocialUser?

    var body: some View {
        let incoming = socialManager.overview?.incomingRequests ?? []
        let outgoing = socialManager.overview?.outgoingRequests ?? []
        let outgoingIDs = Set(outgoing.compactMap { $0.toUser?.id })
        // Someone you've already asked moves from Suggested to Sent.
        let suggestions = socialManager.quickAddSuggestions.filter {
            !$0.hasPendingOutgoing && !outgoingIDs.contains($0.id)
        }
        let showsResults = searchedQuery != nil && searchedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)

        NavigationStack {
            List {
                if let searchedQuery, showsResults {
                    Section("Results") {
                        if socialManager.searchResults.isEmpty {
                            Text("No one found for “\(searchedQuery)”.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(socialManager.searchResults) { result in
                            personRow(
                                id: result.id,
                                name: result.displayName,
                                detail: "@\(result.username)",
                                state: state(for: result)
                            )
                        }
                    }
                }

                if !showsResults && !incoming.isEmpty {
                    Section("Requests") {
                        ForEach(incoming) { request in
                            FriendRequestRow(request: request)
                        }
                    }
                }

                if !showsResults && !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { result in
                            personRow(
                                id: result.id,
                                name: result.displayName,
                                detail: result.reason ?? "@\(result.username)",
                                state: result.hasPendingOutgoing ? .pending : .addable
                            )
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Suggested")
                            InfoButton("People in your class chats, starting with your sections.")
                        }
                    }
                }

                if !showsResults && !outgoing.isEmpty {
                    Section("Sent") {
                        ForEach(outgoing) { request in
                            if let user = request.toUser {
                                personRow(id: user.id, name: user.displayName, detail: "@\(user.username)", state: .pending)
                            }
                        }
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Name or username"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task {
                    await socialManager.searchUsers(query: trimmed)
                    searchedQuery = trimmed
                }
            }
            .navigationTitle("Add Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await socialManager.loadQuickAddSuggestions() }
            .sheet(item: $profileUser) { user in
                SocialUserProfileSheet(user: user)
            }
        }
    }

    private enum RelationshipState {
        case addable, pending, requestedYou, friends
    }

    private func state(for result: SocialSearchResult) -> RelationshipState {
        if result.areFriends { return .friends }
        if result.hasPendingIncoming { return .requestedYou }
        if result.hasPendingOutgoing { return .pending }
        return .addable
    }

    private func personRow(id: String, name: String, detail: String, state: RelationshipState) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                SocialAvatar(id: id, name: name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    if let user = await socialManager.loadUserProfile(id: id) {
                        profileUser = user
                    }
                }
            }

            switch state {
            case .addable:
                Button("Add") {
                    Task { await socialManager.sendFriendRequest(toUserID: id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(socialManager.isLoading)
            case .pending:
                Text("Pending")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .requestedYou:
                Text("Wants to add you")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            case .friends:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Friends")
            }
        }
    }
}
