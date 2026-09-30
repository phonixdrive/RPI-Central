//
//  SocialHubView.swift
//  RPI Central
//
//  The Social tab: Chats, Friends, Map, and Plans under one segmented control.
//  Your profile lives behind the avatar; adding friends behind the person
//  button. This view owns every sheet the sections open.
//

import SwiftUI

struct SocialHubView: View {
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var locationManager: LocationSharingManager

    @SceneStorage("social_section") private var section: SocialSection = .chats
    @State private var chat: SocialGroupChatReference?
    @State private var pendingChat: SocialGroupChatReference?
    @State private var friendSchedule: FriendSchedulePresentation?
    @State private var profileUser: SocialUser?
    @State private var groupMembers: GroupMembersPresentation?
    @State private var classPage: GroupHubPresentation?
    @State private var showProfile = false
    @State private var showAddFriends = false
    @State private var showNewMessage = false
    @State private var showNewGroup = false
    @State private var showNewServer = false
    @State private var showNewPlan = false
    @AppStorage("social_guidelines_accepted_v1") private var acceptedGuidelines = false

    private var isSignedIn: Bool {
        socialManager.isFirebaseAvailable && socialManager.isAuthenticated
    }

    private var incomingRequestCount: Int {
        socialManager.overview?.incomingRequests.count ?? 0
    }

    /// Changes when friends or their shared schedules change.
    private var friendActivityTaskID: String {
        let friends = (socialManager.overview?.friends ?? [])
            .map { "\($0.id):\($0.lastScheduleAt ?? "none"):\($0.canViewSchedule)" }
            .joined(separator: "|")
        return "\(socialManager.currentUser?.id ?? "none")|\(friends)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSignedIn {
                    signedInContent
                } else {
                    SocialSignInView()
                }
            }
            .navigationTitle("Social")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .environment(\.socialActions, actions)
        .socialToast(socialManager)
        .sheet(item: $chat) { GroupChatSheet(reference: $0) }
        .sheet(item: $friendSchedule) { FriendScheduleLoadingView(presentation: $0) }
        .sheet(item: $profileUser) { SocialUserProfileSheet(user: $0) }
        .sheet(item: $groupMembers) { GroupMembersSheet(presentation: $0) }
        .sheet(item: $classPage) { GroupHubSheet(presentation: $0) }
        .sheet(isPresented: $showProfile) { SocialProfileSheet() }
        .sheet(isPresented: $showAddFriends) { AddFriendsSheet() }
        .sheet(isPresented: $showNewMessage, onDismiss: openPendingChat) {
            NewMessageSheet(friends: socialManager.overview?.friends ?? []) { friend in
                pendingChat = socialManager.directMessageReference(with: friend)
            }
        }
        .sheet(isPresented: $showNewGroup, onDismiss: openPendingChat) { newGroupSheet }
        .sheet(isPresented: $showNewServer) {
            ServerSpaceEditor(
                title: "New Server",
                initialName: "",
                initialAddress: "",
                friends: socialManager.overview?.friends ?? [],
                accent: calendarViewModel.themeColor
            ) { name, address, invited in
                Task {
                    await ServerSpacesModel.shared.create(
                        name: name,
                        address: address,
                        ownerName: socialManager.currentUser?.displayName ?? "",
                        invitedIDs: invited
                    )
                }
            }
        }
        .sheet(isPresented: $showNewPlan) { newPlanSheet }
        .sheet(isPresented: Binding(
            get: { isSignedIn && !acceptedGuidelines },
            set: { _ in }
        )) {
            SocialGuidelinesSheet { acceptedGuidelines = true }
        }
        .task {
            if socialManager.isAuthenticated && socialManager.overview == nil {
                await socialManager.refreshOverview()
            }
            openPendingDeepLink()
        }
        .task(id: friendActivityTaskID) {
            await socialManager.preloadFriendSchedulesForActivity()
            openPendingDeepLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: SocialDeepLink.didChangeNotification)) { _ in
            openPendingDeepLink()
        }
        // Friends' live locations feed the activity lines in every section.
        .onAppear { locationManager.beginObservingFriends() }
        .onDisappear { locationManager.endObservingFriends() }
    }

    // MARK: Content

    private var signedInContent: some View {
        Group {
            switch section {
            case .chats:
                SocialChatsView()
            case .friends:
                SocialFriendsView()
            case .map:
                ScrollView {
                    FriendsMapSection(
                        onMessage: { friend in
                            chat = socialManager.directMessageReference(with: friend)
                        },
                        onViewSchedule: { friend in
                            actions.openSchedule(friend)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .refreshable { await socialManager.refreshOverview() }
            case .plans:
                SocialPlansView()
            }
        }
        .socialTopBar {
            Picker("Section", selection: $section) {
                ForEach(SocialSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSignedIn, let user = socialManager.currentUser {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showProfile = true
                } label: {
                    SocialAvatar(id: user.id, name: user.displayName, size: 30)
                }
                .accessibilityLabel("Your profile")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddFriends = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .overlay(alignment: .topTrailing) {
                            if incomingRequestCount > 0 {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 9, height: 9)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .accessibilityLabel(
                    incomingRequestCount > 0
                        ? "Add friends, \(incomingRequestCount) new \(incomingRequestCount == 1 ? "request" : "requests")"
                        : "Add friends"
                )
            }

            if section == .chats {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Message", systemImage: "message") {
                            showNewMessage = true
                        }
                        Button("New Group", systemImage: "person.3") {
                            showNewGroup = true
                        }
                        .disabled((socialManager.overview?.friends ?? []).isEmpty)
                        Button("New Server", systemImage: "server.rack") {
                            showNewServer = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            } else if section == .plans {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewPlan = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New plan")
                }
            }
        }
    }

    // MARK: Actions

    private var actions: SocialActions {
        SocialActions(
            openChat: { chat = $0 },
            openProfile: { profileUser = $0 },
            openSchedule: { friend in
                friendSchedule = FriendSchedulePresentation(
                    friend: friend,
                    cachedResponse: socialManager.cachedFriendSchedule(for: friend)
                )
            },
            openGroupMembers: { groupMembers = membersPresentation(for: $0) },
            openClassPage: { classPage = classPagePresentation(for: $0) },
            addFriends: { showAddFriends = true },
            newGroup: { showNewGroup = true },
            newPlan: { showNewPlan = true }
        )
    }

    private var newGroupSheet: some View {
        FriendGroupEditorView(
            friends: socialManager.overview?.friends ?? [],
            accent: calendarViewModel.themeColor
        ) { name, memberIDs in
            let created = await socialManager.createFriendGroup(name: name, memberIDs: memberIDs)
            if created {
                socialManager.requestScheduleSync()
                // Open the new group's chat once the editor closes.
                let viewerID = socialManager.currentUser?.id
                if let group = socialManager.friendGroups.last(where: { $0.name == name && $0.ownerID == viewerID }) {
                    pendingChat = socialManager.chatReference(for: group)
                }
            }
            return created
        }
    }

    private var newPlanSheet: some View {
        FeedComposerView(
            groups: socialManager.friendGroups,
            accent: calendarViewModel.themeColor
        ) { title, location, details, startsAt, visibility, groupIDs in
            await socialManager.createFeedPost(
                title: title,
                location: location,
                details: details,
                startsAt: startsAt,
                visibility: visibility,
                groupIDs: groupIDs
            )
        }
    }

    private func openPendingChat() {
        guard let pendingChat else { return }
        self.pendingChat = nil
        chat = pendingChat
    }

    /// Opens the chat from a tapped notification once its data has loaded.
    private func openPendingDeepLink() {
        guard socialManager.overview != nil,
              let contextID = SocialDeepLink.pendingContextID,
              let reference = socialManager.chatReference(forThreadID: contextID) else { return }
        _ = SocialDeepLink.consume()
        section = .chats
        chat = reference
    }

    private func membersPresentation(for group: SocialFriendGroup) -> GroupMembersPresentation {
        var namesByID = Dictionary(
            uniqueKeysWithValues: (socialManager.overview?.friends ?? []).map { ($0.id, $0.displayName) }
        )
        if let user = socialManager.currentUser {
            namesByID[user.id] = user.displayName
        }
        var seen: Set<String> = []
        let memberIDs = ([group.ownerID] + group.memberIDs).filter { seen.insert($0).inserted }
        let addableFriends = (socialManager.overview?.friends ?? [])
            .filter { !memberIDs.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return GroupMembersPresentation(
            title: group.name,
            subtitle: "\(memberIDs.count) members",
            memberNames: memberIDs.compactMap { namesByID[$0] },
            group: group,
            addableFriends: addableFriends
        )
    }

    private func classPagePresentation(for community: SocialCourseCommunity) -> GroupHubPresentation {
        let reference = socialManager.chatReference(for: community)
        return GroupHubPresentation(
            id: "course-\(community.id)",
            title: reference.title,
            subtitle: reference.subtitle,
            memberNames: reference.memberDisplayNames.isEmpty ? [reference.subtitle] : reference.memberDisplayNames,
            reference: reference,
            courseCommunity: community
        )
    }
}

enum SocialSection: String, CaseIterable, Identifiable {
    case chats
    case friends
    case map
    case plans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .friends: return "Friends"
        case .map: return "Map"
        case .plans: return "Plans"
        }
    }
}

/// Picks a friend to start a direct message with.
private struct NewMessageSheet: View {
    let friends: [SocialFriend]
    let onSelect: (SocialFriend) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredFriends: [SocialFriend] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return friends }
        return friends.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
                $0.username.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredFriends) { friend in
                Button {
                    onSelect(friend)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        SocialAvatar(id: friend.id, name: friend.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friend.displayName)
                                .foregroundStyle(Color.primary)
                            Text("@\(friend.username)")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .overlay {
                if friends.isEmpty {
                    ContentUnavailableView("No Friends Yet", systemImage: "person.2")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
