import SwiftUI

struct SocialHubView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager

    @State private var authMode: AuthMode = .login
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var profileDisplayName: String = ""
    @State private var searchQuery: String = ""
    @State private var selectedFriendSchedule: FriendScheduleResponse?

    private var friendCount: Int { socialManager.overview?.friends.count ?? 0 }
    private var incomingCount: Int { socialManager.overview?.incomingRequests.count ?? 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        setupCard

                        if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
                            profileCard
                            sharingCard
                            if calendarViewModel.socialDemoToolsEnabled {
                                demoCard
                            }
                            findFriendsCard
                            requestsCard
                            friendsCard
                        } else if socialManager.isFirebaseAvailable {
                            authCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle("Social")
            .toolbar {
                if socialManager.isAuthenticated {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await socialManager.refreshOverview() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable {
                guard socialManager.isAuthenticated else { return }
                await socialManager.refreshOverview()
            }
            .sheet(item: $selectedFriendSchedule) { schedule in
                FriendScheduleView(response: schedule)
            }
            .task {
                if socialManager.isAuthenticated && socialManager.overview == nil {
                    await socialManager.refreshOverview()
                }
                syncProfileDisplayName()
                await syncSharedScheduleIfNeeded()
            }
            .task(id: socialManager.currentUser?.displayName) {
                syncProfileDisplayName()
            }
            .onChange(of: calendarViewModel.currentSemester) {
                Task { await syncSharedScheduleIfNeeded() }
            }
            .onChange(of: calendarViewModel.events.count) {
                Task { await syncSharedScheduleIfNeeded() }
            }
            .onChange(of: calendarViewModel.enrolledCourses.count) {
                Task { await syncSharedScheduleIfNeeded() }
            }
        }
    }

    private var heroCard: some View {
        SocialCard(
            background: Color(red: 0.17, green: 0.19, blue: 0.23),
            stroke: Color.white.opacity(0.08)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(socialManager.isAuthenticated ? "Campus Hub" : "Campus Social")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text(
                            socialManager.isAuthenticated
                                ? "Friend requests, shared schedules, and quick campus coordination."
                                : "Sign in or continue as a guest to unlock schedules, friends, and sharing."
                        )
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Spacer()

                    Image(systemName: "person.3.sequence.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(calendarViewModel.themeColor)
                        .padding(12)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }

                if socialManager.isAuthenticated {
                    HStack(spacing: 10) {
                        statPill(
                            title: "Friends",
                            value: "\(friendCount)",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                        statPill(
                            title: "Requests",
                            value: "\(incomingCount)",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                        statPill(
                            title: "Sharing",
                            value: socialManager.currentUser?.shareSchedule == true ? "On" : "Off",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                    }
                }
            }
        }
    }

    private var setupCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Firebase", systemImage: "bolt.shield")
                    .font(.headline)

                Text(socialManager.setupMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let statusMessage = socialManager.statusMessage {
                    messageBanner(text: statusMessage, color: .green)
                }

                if let errorMessage = socialManager.errorMessage {
                    messageBanner(text: errorMessage, color: .red)
                }
            }
        }
    }

    private var authCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Account", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)

                Picker("Mode", selection: $authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 10) {
                    if authMode.requiresDisplayName {
                        TextField("Display name", text: $displayName)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)
                    }

                    if authMode.requiresEmail {
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textFieldStyle(.roundedBorder)
                    }

                    if authMode.requiresPassword {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Button {
                    Task {
                        switch authMode {
                        case .login:
                            await socialManager.login(email: email, password: password)
                        case .register:
                            await socialManager.register(displayName: displayName, email: email, password: password)
                        case .guest:
                            await socialManager.continueAsGuest(displayName: displayName.isEmpty ? "Guest" : displayName)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(authMode.buttonTitle)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    socialManager.isLoading ||
                    !socialManager.isFirebaseAvailable ||
                    !authMode.isFormValid(displayName: displayName, email: email, password: password)
                )
            }
        }
    }

    private var profileCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(socialManager.currentUser?.displayName ?? "Profile")
                            .font(.headline)
                        Text("@\(socialManager.currentUser?.username ?? "unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(socialManager.currentUser?.isGuest == true ? "Guest" : "Account")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(calendarViewModel.themeColor.opacity(0.15)))
                }

                if let email = socialManager.currentUser?.email, !email.isEmpty {
                    LabeledContent("Email", value: email)
                        .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display name")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        TextField("Display name", text: $profileDisplayName)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            Task {
                                await socialManager.updateDisplayName(profileDisplayName)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            socialManager.isLoading ||
                            profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) == socialManager.currentUser?.displayName
                        )
                    }

                    Text("This is the name your friends will see.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Sign out", role: .destructive) {
                    socialManager.logout()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sharingCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Sharing", systemImage: "calendar.badge.clock")
                    .font(.headline)

                Text("Share your schedule with accepted friends. Location sharing is reserved for a later pass.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Share my schedule with friends",
                    isOn: Binding(
                        get: { socialManager.currentUser?.shareSchedule ?? false },
                        set: { newValue in
                            Task {
                                await socialManager.updateShareSettings(
                                    shareSchedule: newValue,
                                    shareLocation: socialManager.currentUser?.shareLocation ?? false
                                )
                                if newValue {
                                    await socialManager.syncSchedule(from: calendarViewModel)
                                }
                            }
                        }
                    )
                )

                Button("Sync current schedule") {
                    Task {
                        await socialManager.syncSchedule(from: calendarViewModel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(socialManager.isLoading)
            }
        }
    }

    private var demoCard: some View {
        SocialCard(background: Color.orange.opacity(0.1), stroke: Color.orange.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Demo Data", systemImage: "wand.and.stars")
                    .font(.headline)

                Text("Create a searchable test user, an incoming request, and a demo friend with a shared schedule.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Seed demo social data") {
                    Task {
                        await socialManager.seedDemoData(for: calendarViewModel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(socialManager.isLoading)
            }
        }
    }

    private var findFriendsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Find Friends", systemImage: "magnifyingglass")
                    .font(.headline)

                HStack(spacing: 10) {
                    TextField("Search by username or name", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button("Search") {
                        Task {
                            await socialManager.searchUsers(query: searchQuery)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if socialManager.searchResults.isEmpty {
                    Text("Search results will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(socialManager.searchResults) { result in
                            userResultCard(result)
                        }
                    }
                }
            }
        }
    }

    private var requestsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Requests", systemImage: "tray.full")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Incoming")
                        .font(.subheadline.weight(.semibold))

                    if let requests = socialManager.overview?.incomingRequests, !requests.isEmpty {
                        ForEach(requests) { request in
                            requestCard(request, outgoing: false)
                        }
                    } else {
                        Text("No incoming requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Outgoing")
                        .font(.subheadline.weight(.semibold))

                    if let requests = socialManager.overview?.outgoingRequests, !requests.isEmpty {
                        ForEach(requests) { request in
                            requestCard(request, outgoing: true)
                        }
                    } else {
                        Text("No outgoing requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var friendsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Friends", systemImage: "person.2.fill")
                    .font(.headline)

                if let friends = socialManager.overview?.friends, !friends.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(friends) { friend in
                            friendCard(friend)
                        }
                    }
                } else {
                    Text("No friends yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func userResultCard(_ result: SocialSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayName)
                        .font(.headline)
                    Text("@\(result.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if result.areFriends {
                    badgeLabel("Friends", color: .green)
                } else if result.hasPendingOutgoing {
                    badgeLabel("Pending", color: .secondary)
                } else if result.hasPendingIncoming {
                    badgeLabel("Requested you", color: .orange)
                } else {
                    Button("Add") {
                        Task {
                            await socialManager.sendFriendRequest(to: result.username)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !result.email.isEmpty {
                Text(result.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func requestCard(_ request: SocialFriendRequest, outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let user = outgoing ? request.toUser : request.fromUser
            Text(user?.displayName ?? "Unknown User")
                .font(.headline)
            Text("@\(user?.username ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !outgoing {
                HStack {
                    Button("Accept") {
                        Task {
                            await socialManager.respondToFriendRequest(request.id, action: "accept")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Decline", role: .destructive) {
                        Task {
                            await socialManager.respondToFriendRequest(request.id, action: "decline")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func friendCard(_ friend: SocialFriend) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(.headline)
                    Text("@\(friend.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                badgeLabel(friend.shareSchedule ? "Sharing on" : "Sharing off", color: friend.shareSchedule ? .green : .secondary)
            }

            HStack {
                Text("\(friend.schedulePreviewCount) shared items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if friend.canViewSchedule {
                    Button("View schedule") {
                        Task {
                            await socialManager.loadFriendSchedule(friendID: friend.id)
                            if let schedule = socialManager.loadedFriendSchedule {
                                selectedFriendSchedule = schedule
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Remove friend", role: .destructive) {
                Task {
                    await socialManager.unfriend(friend.id)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func statPill(
        title: String,
        value: String,
        background: Color = Color.white.opacity(0.75),
        valueColor: Color = .primary,
        titleColor: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(valueColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(background))
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func messageBanner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }

    private func syncSharedScheduleIfNeeded() async {
        guard socialManager.isAuthenticated,
              socialManager.currentUser?.shareSchedule == true else { return }
        await socialManager.syncSchedule(from: calendarViewModel)
    }

    private func syncProfileDisplayName() {
        profileDisplayName = socialManager.currentUser?.displayName ?? ""
    }
}

